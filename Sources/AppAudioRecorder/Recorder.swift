import Foundation

struct CapturableApplication: Identifiable, Hashable, Sendable {
    var id: String { bundleIdentifier }
    var callApplication: CallApplication? {
        CallApplication.matching(bundleIdentifier: bundleIdentifier)
    }

    let name: String
    let bundleIdentifier: String
    let processID: Int32

    init(name: String, bundleIdentifier: String, processID: Int32) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.processID = processID
    }
}

struct RecordingResult: Sendable {
    let outputURL: URL
    let recordedSeconds: Double
    let warning: String?
}

protocol RecordingEngine: Sendable {
    var recordedSeconds: Double { get async }

    func waitForFailure() async
    func stop() async throws
}

extension AudioCaptureEngine: RecordingEngine {}

/// 一段正在进行的录制。停止操作幂等，便于异常与退出流程并发收尾。
actor RecordingSession {
    nonisolated let outputURL: URL

    private let engine: any RecordingEngine
    private var stopTask: Task<RecordingResult, Never>?

    init(engine: any RecordingEngine, outputURL: URL) {
        self.engine = engine
        self.outputURL = outputURL
    }

    func waitForFailure() async {
        await engine.waitForFailure()
    }

    func stop() async -> RecordingResult {
        if let stopTask {
            return await stopTask.value
        }

        let engine = self.engine
        let outputURL = self.outputURL
        let task = Task {
            let warning: String?
            do {
                try await engine.stop()
                warning = nil
            } catch {
                warning = error.localizedDescription
            }
            return RecordingResult(
                outputURL: outputURL,
                recordedSeconds: await engine.recordedSeconds,
                warning: warning
            )
        }
        stopTask = task
        return await task.value
    }
}

enum Recorder {
    static func applications() async throws -> [CapturableApplication] {
        try await ContentResolver.runningApps().map {
            CapturableApplication(
                name: $0.applicationName,
                bundleIdentifier: $0.bundleIdentifier,
                processID: $0.processID
            )
        }
    }

    static func runningApplication(
        bundleIdentifier: String
    ) async throws -> CapturableApplication {
        let app = try await ContentResolver.findApp(
            bundleIdentifier: bundleIdentifier
        )
        return CapturableApplication(
            name: app.applicationName,
            bundleIdentifier: app.bundleIdentifier,
            processID: app.processID
        )
    }

    static func startRecording(
        application: CapturableApplication,
        outputURL: URL,
        configuration: RecordingConfiguration
    ) async throws -> RecordingSession {
        if configuration.capturesMicrophone {
            try await MicrophonePermission.ensureAuthorized()
        }

        let target = try await ContentResolver.findApp(
            bundleIdentifier: application.bundleIdentifier
        )
        let filter = try await ContentResolver.filter(for: target)
        let engine = AudioCaptureEngine(
            outputURL: outputURL,
            configuration: configuration
        )
        try await engine.start(filter: filter)
        return RecordingSession(engine: engine, outputURL: outputURL)
    }
}
