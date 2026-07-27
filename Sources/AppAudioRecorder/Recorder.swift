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
    let outputURL: URL?
    let recordedSeconds: Double
    let warning: String?
}

enum RecordingEngineEvent: Sendable {
    case warning(String)
    case failure(RecorderError)
}

struct RecordingEngineStopResult: Sendable {
    let outputCompleted: Bool
    let recordedSeconds: Double
    let warning: String?
}

protocol RecordingEngine: Sendable {
    func eventStream() async -> AsyncStream<RecordingEngineEvent>
    func stop() async -> RecordingEngineStopResult
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

    func eventStream() async -> AsyncStream<RecordingEngineEvent> {
        await engine.eventStream()
    }

    func stop() async -> RecordingResult {
        if let stopTask {
            return await stopTask.value
        }

        let engine = self.engine
        let outputURL = self.outputURL
        let task = Task {
            let result = await engine.stop()
            return RecordingResult(
                outputURL: result.outputCompleted ? outputURL : nil,
                recordedSeconds: result.recordedSeconds,
                warning: result.warning
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
