import Foundation

struct CapturableApplication: Identifiable, Hashable, Sendable {
    var id: String { bundleIdentifier }
    var callApplication: CallApplication? {
        CallApplication.matching(bundleIdentifier: bundleIdentifier)
    }

    let name: String
    let bundleIdentifier: String
    let processID: Int32
}

struct RecordingResult: Sendable {
    let outputURL: URL?
    let recordedSeconds: Double
    let warning: String?
}

enum RecordingEngineEvent: Sendable {
    /// 引擎请求正常停止并保存（如到达时长上限）；由模型走既有收尾流程。
    case stopRequested
    case failure(RecorderError)
}

protocol RecordingEngine: Sendable {
    func eventStream() async -> AsyncStream<RecordingEngineEvent>
    func stop() async -> RecordingResult
}

extension AudioCaptureEngine: RecordingEngine {}

/// 一段正在进行的录制。停止操作幂等，便于异常与退出流程并发收尾。
actor RecordingSession {
    private let engine: any RecordingEngine
    private var stopTask: Task<RecordingResult, Never>?

    init(engine: any RecordingEngine) {
        self.engine = engine
    }

    func eventStream() async -> AsyncStream<RecordingEngineEvent> {
        await engine.eventStream()
    }

    func stop() async -> RecordingResult {
        if let stopTask {
            return await stopTask.value
        }
        let engine = self.engine
        let task = Task { await engine.stop() }
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
        return RecordingSession(engine: engine)
    }
}
