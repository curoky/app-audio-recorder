import Foundation

enum CallRecordingEvent: Sendable {
    case started
    case finished(RecordingResult)
    case warning(message: String)
    case failed(message: String)
}

struct RecordingRetryBudget {
    let maximumAttempts: Int
    let window: TimeInterval
    private(set) var attempts: [Date] = []

    mutating func consumeAttempt(at date: Date) -> Bool {
        attempts.removeAll {
            date.timeIntervalSince($0) > window
        }
        guard attempts.count < maximumAttempts else { return false }
        attempts.append(date)
        return true
    }

    mutating func reset() {
        attempts.removeAll()
    }
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
    private var retryTask: Task<Void, Never>?
    private var retryBudget = RecordingRetryBudget(
        maximumAttempts: 3,
        window: 30
    )
    private var callActive = false

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
        callActive = false
        lastFinishedResult = nil
        let activeRetryTask = retryTask
        activeRetryTask?.cancel()
        retryTask = nil
        let activeMonitorTask = monitorTask
        activeMonitorTask?.cancel()
        monitorTask = nil
        monitor?.stop()
        monitor = nil

        // 事件任务可能正在 await 启动或收尾；等它退场，确保不会在 stop() 返回后再创建 writer。
        await activeMonitorTask?.value
        await activeRetryTask?.value
        let result = await finishCurrentRecording(emitEvent: false) ?? lastFinishedResult
        continuation?.finish()
        continuation = nil
        return result
    }

    private func handleActivity(_ active: Bool) async {
        guard isRunning else { return }
        callActive = active
        if active {
            await startRecording()
        } else {
            retryTask?.cancel()
            retryTask = nil
            retryBudget.reset()
            _ = await finishCurrentRecording(emitEvent: true)
        }
    }

    private func startRecording() async {
        guard isRunning, callActive, session == nil, finishingTask == nil else {
            return
        }
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
            retryTask?.cancel()
            retryTask = nil
            continuation?.yield(.started)
            failureTask = Task { [weak self, started] in
                let events = await started.eventStream()
                for await event in events {
                    guard !Task.isCancelled else { return }
                    await self?.handle(event, from: started)
                }
            }
        } catch {
            let recorderError = error as? RecorderError ?? .audioCaptureFailed
            continuation?.yield(
                .failed(message: scheduleRetryMessage(for: recorderError))
            )
        }
    }

    private func handle(
        _ event: RecordingEngineEvent,
        from source: RecordingSession
    ) async {
        guard session === source else { return }
        switch event {
        case .warning(let message):
            continuation?.yield(.warning(message: message))
        case .failure(let error):
            await captureFailed(error)
        }
    }

    private func captureFailed(_ error: RecorderError) async {
        guard isRunning, session != nil else { return }
        _ = await finishCurrentRecording(emitEvent: true)
        continuation?.yield(
            .failed(message: scheduleRetryMessage(for: error))
        )
    }

    private func scheduleRetryMessage(for error: RecorderError) -> String {
        guard isRunning, callActive, error.isRetryableCaptureFailure else {
            return error.localizedDescription
        }
        guard retryBudget.consumeAttempt(at: Date()) else {
            return "\(error.localizedDescription)\n30 秒内已连续重试 3 次，本次通话不再自动重试。"
        }

        retryTask?.cancel()
        retryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.retryRecording()
        }
        return "\(error.localizedDescription)\n1 秒后自动重试。"
    }

    private func retryRecording() async {
        retryTask = nil
        guard isRunning, callActive else { return }
        await startRecording()
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
