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
    private(set) var monitoredBundleIdentifiers: Set<String>
    var recordingConfiguration = RecordingConfiguration()
    var outputDirectory: URL
    var errorMessage: String?
    private(set) var callReminderMessage: String?

    private(set) var isRefreshing = false
    private(set) var statusMessage = "正在读取可录音的 app…"
    private(set) var recordingStartedAt: Date?
    private(set) var latestOutputURL: URL?
    private(set) var isCallMonitoring = false

    @ObservationIgnored private var recordingSession: RecordingSession?
    @ObservationIgnored private var callMonitor: CallActivityMonitor?
    @ObservationIgnored private var callMonitorTask: Task<Void, Never>?
    @ObservationIgnored private var failureTask: Task<Void, Never>?
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let notifyCallDetected: @MainActor () -> Void
    @ObservationIgnored private let recordingStarter: RecordingStarter
    private var monitoredApplicationsByBundleIdentifier:
        [String: CapturableApplication] = [:]
    private var activeCallBundleIdentifiers: Set<String> = []
    private var pendingCallBundleIdentifiers: [String] = []
    private var reminderApplication: CapturableApplication?
    private var activity = Activity.idle

    private static let outputDirectoryKey = "outputDirectory"
    private static let selectedBundleIdentifierKey = "selectedBundleIdentifier"
    private static let monitoredBundleIdentifiersKey = "monitoredBundleIdentifiers"

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
        self.notifyCallDetected = notifyCallDetected
        self.recordingStarter = recordingStarter
        selectedBundleIdentifier = defaults.string(forKey: Self.selectedBundleIdentifierKey)
        monitoredBundleIdentifiers = Set(
            defaults.stringArray(forKey: Self.monitoredBundleIdentifiersKey) ?? []
        )

        if let saved = defaults.string(forKey: Self.outputDirectoryKey) {
            outputDirectory = URL(fileURLWithPath: saved, isDirectory: true)
        } else {
            let music =
                FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
            outputDirectory = music.appendingPathComponent("App Audio Recorder", isDirectory: true)
        }
    }

    var selectedApplication: CapturableApplication? {
        applications.first { $0.bundleIdentifier == selectedBundleIdentifier }
    }

    var monitoredApplications: [CapturableApplication] {
        applications.filter {
            monitoredBundleIdentifiers.contains($0.bundleIdentifier)
        }
    }

    var isActive: Bool {
        isRecordingOperationActive || isCallMonitoring
    }

    var isTargetSelectionLocked: Bool {
        isRecordingOperationActive
    }

    var isMonitoringSelectionLocked: Bool {
        isCallMonitoring
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

    func toggleMonitoredApplication(bundleIdentifier: String) {
        guard !isCallMonitoring else { return }
        if monitoredBundleIdentifiers.remove(bundleIdentifier) == nil {
            let rootBundleIdentifier = ApplicationBundleMatcher(
                targetBundleIdentifier: bundleIdentifier
            ).rootBundleIdentifier
            monitoredBundleIdentifiers = Set(
                monitoredBundleIdentifiers.filter {
                    ApplicationBundleMatcher(
                        targetBundleIdentifier: $0
                    ).rootBundleIdentifier != rootBundleIdentifier
                }
            )
            monitoredBundleIdentifiers.insert(bundleIdentifier)
        }
        defaults.set(
            monitoredBundleIdentifiers.sorted(),
            forKey: Self.monitoredBundleIdentifiersKey
        )
    }

    func refreshApplications() async {
        guard !isTargetSelectionLocked else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let loaded = try await Recorder.applications()
            applications = loaded
            reconcileMonitoredApplications(with: loaded)
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
            if isCallMonitoring {
                statusMessage = monitoringStatusMessage
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
        clearCallReminder()
        operationTask = Task { [weak self] in
            await self?.performPrimaryAction()
            self?.operationTask = nil
            self?.presentNextCallReminderIfPossible()
        }
    }

    func setCallMonitoringEnabled(_ enabled: Bool) {
        if enabled {
            startCallMonitoring()
        } else {
            _ = stopCallMonitoring()
        }
    }

    func startRecordingFromReminder() {
        guard operationTask == nil, activity == .idle,
            let application = reminderApplication
        else { return }
        clearCallReminder()
        operationTask = Task { [weak self, application] in
            await self?.startRecording(application: application)
            self?.operationTask = nil
            self?.presentNextCallReminderIfPossible()
        }
    }

    func dismissCallReminder() async {
        clearCallReminder()
        await Task.yield()
        presentNextCallReminderIfPossible()
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
        let monitorTask = stopCallMonitoring()
        await monitorTask?.value
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
                presentNextCallReminderIfPossible()
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
                    case .warning(let message):
                        self?.errorMessage = message
                    case .failure:
                        await self?.finishRecording()
                        return
                    }
                }
            }
        } catch {
            activity = .idle
            recordingStartedAt = nil
            present(error)
            presentNextCallReminderIfPossible()
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
        presentNextCallReminderIfPossible()
    }

    private func startCallMonitoring() {
        let monitoredApplications = monitoredApplications
        guard callMonitor == nil, !monitoredApplications.isEmpty else { return }

        let monitor = CallActivityMonitor(
            targetBundleIdentifiers: Set(
                monitoredApplications.map(\.bundleIdentifier)
            )
        )
        callMonitor = monitor
        monitoredApplicationsByBundleIdentifier = Dictionary(
            uniqueKeysWithValues: monitoredApplications.map {
                ($0.bundleIdentifier, $0)
            }
        )
        activeCallBundleIdentifiers.removeAll()
        pendingCallBundleIdentifiers.removeAll()
        clearCallReminder()
        isCallMonitoring = true
        if activity == .idle {
            statusMessage = monitoringStatusMessage
        }

        monitor.start()
        callMonitorTask = Task { [weak self, monitor] in
            for await event in monitor.activityEvents() {
                guard !Task.isCancelled else { break }
                self?.handleCallActivity(event)
            }
        }
    }

    @discardableResult
    private func stopCallMonitoring() -> Task<Void, Never>? {
        guard let monitor = callMonitor else { return nil }
        callMonitor = nil
        let task = callMonitorTask
        callMonitorTask = nil
        task?.cancel()
        monitor.stop()

        isCallMonitoring = false
        monitoredApplicationsByBundleIdentifier.removeAll()
        activeCallBundleIdentifiers.removeAll()
        pendingCallBundleIdentifiers.removeAll()
        clearCallReminder()
        if activity == .idle {
            statusMessage = "通话提醒已关闭"
        }
        return task
    }

    func handleCallActivity(_ event: CallActivityEvent) {
        guard isCallMonitoring,
            monitoredApplicationsByBundleIdentifier[event.bundleIdentifier] != nil
        else { return }

        if event.isActive {
            guard activeCallBundleIdentifiers.insert(
                event.bundleIdentifier
            ).inserted else { return }
            pendingCallBundleIdentifiers.append(event.bundleIdentifier)
            presentNextCallReminderIfPossible()
            return
        }

        activeCallBundleIdentifiers.remove(event.bundleIdentifier)
        pendingCallBundleIdentifiers.removeAll {
            $0 == event.bundleIdentifier
        }
        if reminderApplication?.bundleIdentifier == event.bundleIdentifier {
            clearCallReminder()
            presentNextCallReminderIfPossible()
        } else if activity == .idle, reminderApplication == nil {
            statusMessage = monitoringStatusMessage
        }
    }

    private func presentNextCallReminderIfPossible() {
        guard isCallMonitoring, !isRecordingOperationActive,
            reminderApplication == nil
        else { return }

        while !pendingCallBundleIdentifiers.isEmpty {
            let bundleIdentifier = pendingCallBundleIdentifiers.removeFirst()
            guard activeCallBundleIdentifiers.contains(bundleIdentifier),
                let application =
                    monitoredApplicationsByBundleIdentifier[bundleIdentifier]
            else { continue }

            reminderApplication = application
            callReminderMessage =
                "检测到 \(application.name) 同时使用音频输入与输出，是否开始录制？"
            statusMessage = "检测到 \(application.name) 疑似通话，等待手动录制"
            notifyCallDetected()
            return
        }

        if activity == .idle {
            statusMessage = monitoringStatusMessage
        }
    }

    private func clearCallReminder() {
        reminderApplication = nil
        callReminderMessage = nil
    }

    private var monitoringStatusMessage: String {
        "正在监听 \(monitoredApplicationsByBundleIdentifier.count) 个 app 的通话活动"
    }

    private func reconcileMonitoredApplications(
        with loadedApplications: [CapturableApplication]
    ) {
        let reconciled = Set(
            monitoredBundleIdentifiers.map { bundleIdentifier in
                let matcher = ApplicationBundleMatcher(
                    targetBundleIdentifier: bundleIdentifier
                )
                return loadedApplications.first {
                    matcher.belongsToSameFamily(as: $0.bundleIdentifier)
                }?.bundleIdentifier ?? bundleIdentifier
            }
        )
        guard reconciled != monitoredBundleIdentifiers else { return }
        monitoredBundleIdentifiers = reconciled
        defaults.set(
            monitoredBundleIdentifiers.sorted(),
            forKey: Self.monitoredBundleIdentifiersKey
        )
    }

    private func apply(_ result: RecordingResult) {
        let monitoringSuffix = isCallMonitoring ? "，继续监听" : ""
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
