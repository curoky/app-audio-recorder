import Foundation

enum CallRecordingEvent: Sendable {
    case started(outputURL: URL)
    case finished(RecordingResult)
    case failed(message: String)
}

/// 监听目标 app 的麦克风活动，并为每段活动自动管理一段录制。
actor CallRecordingWatcher {
    private let application: CapturableApplication
    private let outputDirectory: URL
    private let recordingConfiguration: RecordingConfiguration
    private let endDelay: CallEndDelay

    private var isRunning = false
    private var monitor: CallActivityMonitor?
    private var monitorTask: Task<Void, Never>?
    private var failureTask: Task<Void, Never>?
    private var finishingTask: Task<RecordingResult, Never>?
    private var session: RecordingSession?
    private var lastFinishedResult: RecordingResult?
    private var continuation: AsyncStream<CallRecordingEvent>.Continuation?

    init(
        application: CapturableApplication,
        outputDirectory: URL,
        recordingConfiguration: RecordingConfiguration,
        endDelay: CallEndDelay
    ) {
        self.application = application
        self.outputDirectory = outputDirectory
        var configuration = recordingConfiguration
        configuration.capturesMicrophone = true
        self.recordingConfiguration = configuration
        self.endDelay = endDelay
    }

    /// 开始监听并立即返回事件流；同一实例不可重复并发启动。
    func start() async throws -> AsyncStream<CallRecordingEvent> {
        guard !isRunning, continuation == nil else {
            throw RecorderError.operationAlreadyRunning
        }
        try RecordingFiles.validateOutputDirectory(outputDirectory)
        _ = try await Recorder.runningApplication(
            bundleIdentifier: application.bundleIdentifier
        )
        try await MicrophonePermission.ensureAuthorized()

        let (events, continuation) = AsyncStream<CallRecordingEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        let monitor = CallActivityMonitor(
            targetBundleID: application.bundleIdentifier,
            endDelay: endDelay
        )
        self.continuation = continuation
        self.monitor = monitor
        isRunning = true
        monitor.start()

        monitorTask = Task { [weak self] in
            for await active in monitor.activityEvents() {
                guard !Task.isCancelled else { break }
                await self?.handleActivity(active)
            }
        }
        return events
    }

    /// 停止监听；若正在录制，先完成容器收尾并返回该段结果。
    func stop() async -> RecordingResult? {
        guard isRunning || session != nil || finishingTask != nil else { return nil }
        isRunning = false
        lastFinishedResult = nil
        let activeMonitorTask = monitorTask
        activeMonitorTask?.cancel()
        monitorTask = nil
        monitor?.stop()
        monitor = nil

        // 事件任务可能正在 await 启动或收尾；等它退场，确保不会在 stop() 返回后再创建 writer。
        await activeMonitorTask?.value
        let result = await finishCurrentRecording(emitEvent: false) ?? lastFinishedResult
        continuation?.finish()
        continuation = nil
        return result
    }

    private func handleActivity(_ active: Bool) async {
        guard isRunning else { return }
        if active {
            await startRecording()
        } else {
            _ = await finishCurrentRecording(emitEvent: true)
        }
    }

    private func startRecording() async {
        guard session == nil else { return }
        do {
            let currentApplication = try await Recorder.runningApplication(
                bundleIdentifier: application.bundleIdentifier
            )
            let outputURL = RecordingFiles.uniqueContainerURL(
                applicationName: application.name,
                in: outputDirectory
            )
            let started = try await Recorder.startRecording(
                application: currentApplication,
                outputURL: outputURL,
                configuration: recordingConfiguration
            )

            guard isRunning else {
                _ = await started.stop()
                try? FileManager.default.removeItem(at: outputURL)
                return
            }

            session = started
            continuation?.yield(.started(outputURL: outputURL))
            failureTask = Task { [weak self, started] in
                await started.waitForFailure()
                guard !Task.isCancelled else { return }
                await self?.captureFailed()
            }
        } catch {
            continuation?.yield(.failed(message: error.localizedDescription))
        }
    }

    private func captureFailed() async {
        guard isRunning else { return }
        _ = await finishCurrentRecording(emitEvent: true)
    }

    private func finishCurrentRecording(emitEvent: Bool) async -> RecordingResult? {
        if let finishingTask {
            return await finishingTask.value
        }
        guard let current = session else { return nil }
        session = nil
        failureTask?.cancel()
        failureTask = nil

        let task = Task { await current.stop() }
        finishingTask = task
        let result = await task.value
        finishingTask = nil
        lastFinishedResult = result
        if emitEvent {
            continuation?.yield(.finished(result))
        }
        return result
    }
}
