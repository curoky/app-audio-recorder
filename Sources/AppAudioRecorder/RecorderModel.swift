import AppKit
import Foundation
import Observation

enum RecorderMode: String, CaseIterable, Identifiable {
    case manual = "手动录制"
    case automatic = "自动监听"

    var id: Self { self }
}

@MainActor
@Observable
final class RecorderModel {
    var mode = RecorderMode.manual
    var applications: [CapturableApplication] = []
    private(set) var selectedBundleIdentifier: String?
    var recordingConfiguration = RecordingConfiguration()
    var callEndDelay = CallEndDelay.twoSeconds
    var outputDirectory: URL
    var errorMessage: String?

    private(set) var isRefreshing = false
    private(set) var statusMessage = "正在读取可录音的 app…"
    private(set) var recordingStartedAt: Date?
    private(set) var latestOutputURL: URL?

    @ObservationIgnored private var manualSession: RecordingSession?
    @ObservationIgnored private var watcher: CallRecordingWatcher?
    @ObservationIgnored private var failureTask: Task<Void, Never>?
    @ObservationIgnored private var watcherTask: Task<Void, Never>?
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    private var activity = Activity.idle

    private static let outputDirectoryKey = "outputDirectory"
    private static let selectedBundleIdentifierKey = "selectedBundleIdentifier"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedBundleIdentifier = defaults.string(forKey: Self.selectedBundleIdentifierKey)

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

    var isActive: Bool {
        activity != .idle || operationTask != nil
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
            mode == .manual ? "开始录制" : "开始监听"
        case .preparing:
            "正在准备…"
        case .listening:
            "停止监听"
        case .recording:
            mode == .manual ? "停止录制" : "停止监听"
        case .stopping:
            "正在保存…"
        }
    }

    var canPerformPrimaryAction: Bool {
        !isTransitioning && (isActive || selectedApplication != nil)
    }

    func selectApplication(bundleIdentifier: String) {
        selectedBundleIdentifier = bundleIdentifier
        defaults.set(bundleIdentifier, forKey: Self.selectedBundleIdentifierKey)
    }

    func refreshApplications() async {
        guard !isActive else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let loaded = try await Recorder.applications()
            applications = loaded
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
            statusMessage =
                loaded.isEmpty
                ? "没有找到可录音的运行中 app"
                : "选择目标 app 后即可开始"
        } catch {
            applications = []
            selectedBundleIdentifier = nil
            present(error)
        }
    }

    func chooseOutputDirectory() {
        guard !isActive else { return }
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
        operationTask = Task { [weak self] in
            await self?.performPrimaryAction()
            self?.operationTask = nil
        }
    }

    func shutdown() async {
        operationTask?.cancel()
        await operationTask?.value
        operationTask = nil

        if manualSession != nil {
            await finishManualRecording()
        } else if watcher != nil {
            await stopWatching()
        } else {
            await failureTask?.value
        }
    }

    private func performPrimaryAction() async {
        switch activity {
        case .idle:
            if mode == .manual {
                await startManualRecording()
            } else {
                await startWatching()
            }
        case .listening:
            await stopWatching()
        case .recording:
            if mode == .manual {
                await finishManualRecording()
            } else {
                await stopWatching()
            }
        case .preparing, .stopping:
            break
        }
    }

    private func startManualRecording() async {
        guard let application = selectedApplication else { return }
        activity = .preparing
        statusMessage = "正在准备录制…"

        do {
            try prepareOutputDirectory()
            let outputURL = RecordingFiles.uniqueContainerURL(
                applicationName: application.name,
                in: outputDirectory
            )
            let session = try await Recorder.startRecording(
                application: application,
                outputURL: outputURL,
                configuration: recordingConfiguration
            )
            guard !Task.isCancelled else {
                _ = await session.stop()
                try? FileManager.default.removeItem(at: outputURL)
                activity = .idle
                return
            }
            manualSession = session
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
                        await self?.finishManualRecording()
                        return
                    }
                }
            }
        } catch {
            activity = .idle
            recordingStartedAt = nil
            present(error)
        }
    }

    private func finishManualRecording() async {
        guard let session = manualSession else { return }
        manualSession = nil
        failureTask?.cancel()
        activity = .stopping
        statusMessage = "正在保存录音…"

        let result = await session.stop()
        failureTask = nil
        apply(result)
        activity = .idle
        recordingStartedAt = nil
    }

    private func startWatching() async {
        guard let application = selectedApplication else { return }
        activity = .preparing
        statusMessage = "正在启动监听…"

        do {
            try prepareOutputDirectory()
            let watcher = CallRecordingWatcher(
                application: application,
                outputDirectory: outputDirectory,
                recordingConfiguration: recordingConfiguration,
                endDelay: callEndDelay
            )
            let events = try await watcher.start()
            guard !Task.isCancelled else {
                _ = await watcher.stop()
                activity = .idle
                return
            }
            self.watcher = watcher
            activity = .listening
            statusMessage = "正在监听 \(application.name) 的通话"
            watcherTask = Task { [weak self] in
                for await event in events {
                    guard !Task.isCancelled else { break }
                    self?.handle(event)
                }
            }
        } catch {
            activity = .idle
            present(error)
        }
    }

    private func stopWatching() async {
        guard let watcher else { return }
        self.watcher = nil
        watcherTask?.cancel()
        watcherTask = nil
        activity = .stopping
        statusMessage = "正在停止监听…"

        if let result = await watcher.stop() {
            apply(result)
        } else {
            statusMessage = "已停止监听"
        }
        activity = .idle
        recordingStartedAt = nil
    }

    private func handle(_ event: CallRecordingEvent) {
        guard watcher != nil else { return }
        switch event {
        case .started:
            recordingStartedAt = Date()
            activity = .recording
            statusMessage = "检测到通话，正在录制"
        case .finished(let result):
            apply(result)
            recordingStartedAt = nil
            activity = .listening
            if result.outputURL != nil {
                statusMessage = "通话已保存，继续监听"
            }
        case .warning(let message):
            errorMessage = message
        case .failed(let message):
            errorMessage = message
            recordingStartedAt = nil
            activity = .listening
            statusMessage = "录制中断，继续监听"
        }
    }

    private func apply(_ result: RecordingResult) {
        if let outputURL = result.outputURL {
            latestOutputURL = outputURL
            statusMessage = String(
                format: "已保存 %.1f 秒录音",
                result.recordedSeconds
            )
        } else {
            statusMessage = "录音未能保存"
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
        case listening
        case recording
        case stopping
    }
}
