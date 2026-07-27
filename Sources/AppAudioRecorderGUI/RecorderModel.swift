import AppAudioRecorderCore
import AppKit
import Foundation
import Logging
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
    var selectedBundleIdentifier: String?
    var capturesMicrophone = true
    var outputDirectory: URL
    var errorMessage: String?

    private(set) var isRefreshing = false
    private(set) var statusMessage = "正在读取可录音的 app…"
    private(set) var recordingStartedAt: Date?
    private(set) var latestOutputURL: URL?

    @ObservationIgnored private let logger = AppLog.logger("gui")
    @ObservationIgnored private var manualSession: RecordingSession?
    @ObservationIgnored private var watcher: CallRecordingWatcher?
    @ObservationIgnored private var failureTask: Task<Void, Never>?
    @ObservationIgnored private var watcherTask: Task<Void, Never>?
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    private var activity = Activity.idle

    private static let outputDirectoryKey = "outputDirectory"

    init(defaults: UserDefaults = .standard) {
        if let saved = defaults.string(forKey: Self.outputDirectoryKey) {
            outputDirectory = URL(fileURLWithPath: saved, isDirectory: true)
        } else {
            let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
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

    func refreshApplications() async {
        guard !isActive else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let loaded = try await Recorder.applications()
            applications = loaded
            if !loaded.contains(where: { $0.bundleIdentifier == selectedBundleIdentifier }) {
                selectedBundleIdentifier =
                    loaded.first(where: {
                        $0.bundleIdentifier == Recorder.defaultBundleIdentifier
                    })?.bundleIdentifier
                    ?? loaded.first(where: { $0.callApplication != nil })?.bundleIdentifier
                    ?? loaded.first?.bundleIdentifier
            }
            statusMessage = loaded.isEmpty
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
        UserDefaults.standard.set(selected.path, forKey: Self.outputDirectoryKey)
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
                capturesMicrophone: capturesMicrophone,
                overwritesExistingOutput: false,
                logger: logger
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
                await session.waitForFailure()
                guard !Task.isCancelled else { return }
                await self?.finishManualRecording()
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
                logger: logger
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
        case let .started(outputURL):
            recordingStartedAt = Date()
            latestOutputURL = outputURL
            activity = .recording
            statusMessage = "检测到通话，正在录制"
        case let .finished(result):
            apply(result)
            recordingStartedAt = nil
            activity = .listening
            statusMessage = "通话已保存，继续监听"
        case let .failed(message):
            errorMessage = message
            recordingStartedAt = nil
            activity = .listening
            statusMessage = "本次录制启动失败，继续监听"
        }
    }

    private func apply(_ result: RecordingResult) {
        latestOutputURL = result.outputURL
        statusMessage = String(
            format: "已保存 %.1f 秒录音",
            result.recordedSeconds
        )
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
