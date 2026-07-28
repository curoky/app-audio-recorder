import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class RecorderModel {
    typealias RecordingStarter = @MainActor (
        CapturableApplication,
        URL,
        RecordingConfiguration
    ) async throws -> RecordingSession

    var applications: [CapturableApplication] = []
    private(set) var selectedBundleIdentifier: String?
    var recordingConfiguration = RecordingConfiguration()
    /// 可选的麦克风输入设备；首项固定为“跟随系统默认（自动切换）”。
    private(set) var audioInputDevices: [AudioInputDevice] = []
    /// 系统当前默认输入设备名；跟随系统默认时用于在界面上显示实际会录哪个设备。
    private(set) var systemDefaultInputDeviceName: String?
    var outputDirectory: URL
    var errorMessage: String?

    private(set) var isRefreshing = false
    private(set) var statusMessage = "正在读取可录音的 app…"
    private(set) var recordingStartedAt: Date?
    private(set) var latestOutputURL: URL?

    /// 通话检测附加功能的编排器；核心录制不依赖它，只在界面上并列展示。
    @ObservationIgnored private let callMonitor: CallMonitorCoordinator
    @ObservationIgnored private var recordingSession: RecordingSession?
    @ObservationIgnored private var failureTask: Task<Void, Never>?
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let recordingStarter: RecordingStarter
    private var activity = Activity.idle

    private static let outputDirectoryKey = "outputDirectory"
    private static let selectedBundleIdentifierKey = "selectedBundleIdentifier"
    private static let microphoneDeviceIDKey = "microphoneDeviceID"

    init(
        defaults: UserDefaults = .standard,
        notifyCallDetected: @escaping @MainActor () -> Void = {
            NSSound.beep()
            NSApplication.shared.requestUserAttention(.informationalRequest)
        },
        recordingStarter: @escaping RecordingStarter = {
            application,
            outputURL,
            configuration in
            try await Recorder.startRecording(
                application: application,
                outputURL: outputURL,
                configuration: configuration
            )
        }
    ) {
        self.defaults = defaults
        self.recordingStarter = recordingStarter
        callMonitor = CallMonitorCoordinator(
            defaults: defaults,
            notifyCallDetected: notifyCallDetected
        )
        selectedBundleIdentifier = defaults.string(forKey: Self.selectedBundleIdentifierKey)

        if let saved = defaults.string(forKey: Self.outputDirectoryKey) {
            outputDirectory = URL(fileURLWithPath: saved, isDirectory: true)
        } else {
            let music =
                FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
            outputDirectory = music.appendingPathComponent("App Audio Recorder", isDirectory: true)
        }

        recordingConfiguration.microphoneDeviceID = defaults.string(
            forKey: Self.microphoneDeviceIDKey
        )

        callMonitor.isRecordingBusy = { [weak self] in
            self?.isRecordingOperationActive ?? false
        }
        callMonitor.updateStatus = { [weak self] message in
            self?.statusMessage = message
        }
    }

    var selectedApplication: CapturableApplication? {
        applications.first { $0.bundleIdentifier == selectedBundleIdentifier }
    }

    var monitoredBundleIdentifiers: Set<String> {
        callMonitor.monitoredBundleIdentifiers
    }

    var isCallMonitoring: Bool {
        callMonitor.isMonitoring
    }

    var callReminderMessage: String? {
        callMonitor.reminderMessage
    }

    var monitoredApplications: [CapturableApplication] {
        applications.filter {
            callMonitor.monitoredBundleIdentifiers.contains($0.bundleIdentifier)
        }
    }

    var isActive: Bool {
        isRecordingOperationActive || callMonitor.isMonitoring
    }

    var isTargetSelectionLocked: Bool {
        isRecordingOperationActive
    }

    var isMonitoringSelectionLocked: Bool {
        callMonitor.isMonitoring
    }

    var isRecordingConfigurationLocked: Bool {
        isRecordingOperationActive
    }

    var isTransitioning: Bool {
        activity == .preparing || activity == .stopping
    }

    var isRecording: Bool {
        activity == .recording
    }

    var primaryButtonTitle: String {
        switch activity {
        case .idle:
            "开始录制"
        case .preparing:
            "正在准备…"
        case .recording:
            "停止录制"
        case .stopping:
            "正在保存…"
        }
    }

    var canPerformPrimaryAction: Bool {
        operationTask == nil
            && !isTransitioning
            && (activity != .idle || selectedApplication != nil)
    }

    private var isRecordingOperationActive: Bool {
        activity != .idle || operationTask != nil
    }

    func selectApplication(bundleIdentifier: String) {
        selectedBundleIdentifier = bundleIdentifier
        defaults.set(bundleIdentifier, forKey: Self.selectedBundleIdentifierKey)
    }

    /// 重新枚举可用输入设备。若已锁定的设备不再存在，则回落到系统默认（自动切换）。
    func refreshAudioInputDevices() {
        audioInputDevices = AudioInputDevices.available()
        systemDefaultInputDeviceName = AudioInputDevices.systemDefault()?.name
        if let deviceID = recordingConfiguration.microphoneDeviceID,
            !audioInputDevices.contains(where: { $0.id == deviceID })
        {
            selectMicrophoneDevice(id: nil)
        }
    }

    /// 选择麦克风输入设备；`nil` 表示跟随系统默认（自动切换）。录制期间禁止修改。
    func selectMicrophoneDevice(id: String?) {
        guard !isRecordingConfigurationLocked else { return }
        recordingConfiguration.microphoneDeviceID = id
        if let id {
            defaults.set(id, forKey: Self.microphoneDeviceIDKey)
        } else {
            defaults.removeObject(forKey: Self.microphoneDeviceIDKey)
        }
    }

    func toggleMonitoredApplication(bundleIdentifier: String) {
        callMonitor.toggleMonitored(bundleIdentifier: bundleIdentifier)
    }

    func refreshApplications() async {
        guard !isTargetSelectionLocked else { return }
        refreshAudioInputDevices()
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let loaded = try await Recorder.applications()
            applications = loaded
            callMonitor.reconcile(with: loaded)
            let preferredBundleIdentifier = defaults.string(
                forKey: Self.selectedBundleIdentifierKey
            )
            if let preferredBundleIdentifier,
                loaded.contains(where: {
                    $0.bundleIdentifier == preferredBundleIdentifier
                })
            {
                selectedBundleIdentifier = preferredBundleIdentifier
            } else if !loaded.contains(where: {
                $0.bundleIdentifier == selectedBundleIdentifier
            }) {
                selectedBundleIdentifier =
                    loaded.first(where: {
                        $0.bundleIdentifier
                            == CallApplication.weChat.primaryBundleIdentifier
                    })?.bundleIdentifier
                    ?? loaded.first(where: { $0.callApplication != nil })?.bundleIdentifier
                    ?? loaded.first?.bundleIdentifier
            }
            if callMonitor.isMonitoring {
                statusMessage = callMonitor.monitoringStatusText
            } else {
                statusMessage =
                    loaded.isEmpty
                    ? "没有找到可录音的运行中 app"
                    : "选择目标 app 后即可开始"
            }
        } catch {
            applications = []
            selectedBundleIdentifier = nil
            present(error)
        }
    }

    func chooseOutputDirectory() {
        guard !isRecordingOperationActive else { return }
        let panel = NSOpenPanel()
        panel.title = "选择录音保存目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputDirectory

        guard panel.runModal() == .OK, let selected = panel.url else { return }
        outputDirectory = selected
        defaults.set(selected.path, forKey: Self.outputDirectoryKey)
    }

    func triggerPrimaryAction() {
        guard operationTask == nil else { return }
        callMonitor.clearReminder()
        operationTask = Task { [weak self] in
            await self?.performPrimaryAction()
            self?.operationTask = nil
            self?.callMonitor.presentNextReminderIfPossible()
        }
    }

    func setCallMonitoringEnabled(_ enabled: Bool) {
        callMonitor.setEnabled(enabled, monitoredApplications: monitoredApplications)
    }

    func startRecordingFromReminder() {
        guard operationTask == nil, activity == .idle,
            let application = callMonitor.reminderApplication
        else { return }
        callMonitor.clearReminder()
        operationTask = Task { [weak self, application] in
            await self?.startRecording(application: application)
            self?.operationTask = nil
            self?.callMonitor.presentNextReminderIfPossible()
        }
    }

    func dismissCallReminder() async {
        await callMonitor.dismissReminder()
    }

    /// 供测试注入通话活动事件；实际运行时由协调器内部的监视任务驱动。
    func handleCallActivity(_ event: CallActivityEvent) {
        callMonitor.handleActivity(event)
    }

    func shutdown() async {
        operationTask?.cancel()
        await operationTask?.value
        operationTask = nil

        if recordingSession != nil {
            await finishRecording()
        } else {
            await failureTask?.value
        }
        await callMonitor.shutdown()
    }

    private func performPrimaryAction() async {
        switch activity {
        case .idle:
            guard let application = selectedApplication else { return }
            await startRecording(application: application)
        case .recording:
            await finishRecording()
        case .preparing, .stopping:
            break
        }
    }

    private func startRecording(application: CapturableApplication) async {
        activity = .preparing
        statusMessage = "正在准备录制…"

        do {
            try prepareOutputDirectory()
            let outputURL = RecordingFiles.uniqueContainerURL(
                applicationName: application.name,
                in: outputDirectory
            )
            let session = try await recordingStarter(
                application,
                outputURL,
                recordingConfiguration
            )
            guard !Task.isCancelled else {
                _ = await session.stop()
                try? FileManager.default.removeItem(at: outputURL)
                activity = .idle
                callMonitor.presentNextReminderIfPossible()
                return
            }
            recordingSession = session
            recordingStartedAt = Date()
            activity = .recording
            statusMessage = "正在录制 \(application.name)"
            failureTask = Task { [weak self, session] in
                let events = await session.eventStream()
                for await event in events {
                    guard !Task.isCancelled else { return }
                    switch event {
                    case .stopRequested, .failure:
                        await self?.finishRecording()
                        return
                    }
                }
            }
        } catch {
            activity = .idle
            recordingStartedAt = nil
            present(error)
            callMonitor.presentNextReminderIfPossible()
        }
    }

    private func finishRecording() async {
        guard let session = recordingSession else { return }
        recordingSession = nil
        failureTask?.cancel()
        activity = .stopping
        statusMessage = "正在保存录音…"

        let result = await session.stop()
        failureTask = nil
        apply(result)
        activity = .idle
        recordingStartedAt = nil
        callMonitor.presentNextReminderIfPossible()
    }

    private func apply(_ result: RecordingResult) {
        let monitoringSuffix = callMonitor.isMonitoring ? "，继续监听" : ""
        if let outputURL = result.outputURL {
            latestOutputURL = outputURL
            statusMessage = String(
                format: "已保存 %.1f 秒录音%@",
                result.recordedSeconds,
                monitoringSuffix
            )
        } else {
            statusMessage = "录音未能保存\(monitoringSuffix)"
        }
        if let warning = result.warning {
            errorMessage = warning
        }
    }

    private func prepareOutputDirectory() throws {
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        try RecordingFiles.validateOutputDirectory(outputDirectory)
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        statusMessage = "操作失败"
    }

    private enum Activity {
        case idle
        case preparing
        case recording
        case stopping
    }
}
