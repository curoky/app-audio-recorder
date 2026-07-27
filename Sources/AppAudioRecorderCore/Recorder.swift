import Foundation
import Logging

public struct CapturableApplication: Identifiable, Hashable, Sendable {
    public var id: String { bundleIdentifier }
    public var callApplication: CallApplication? {
        CallApplication.matching(bundleIdentifier: bundleIdentifier)
    }

    public let name: String
    public let bundleIdentifier: String
    public let processID: Int32

    init(name: String, bundleIdentifier: String, processID: Int32) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.processID = processID
    }
}

public struct RecordingResult: Sendable {
    public let outputURL: URL
    public let recordedSeconds: Double
    public let warning: String?
}

protocol RecordingEngine: Sendable {
    var recordedSeconds: Double { get async }

    func waitForFailure() async
    func stop() async throws
}

extension AudioCaptureEngine: RecordingEngine {}

/// 一段正在进行的录制。停止操作幂等，CLI 与 GUI 可安全共享同一生命周期语义。
public actor RecordingSession {
    public nonisolated let outputURL: URL

    private let engine: any RecordingEngine
    private var stopTask: Task<RecordingResult, Never>?

    init(engine: any RecordingEngine, outputURL: URL) {
        self.engine = engine
        self.outputURL = outputURL
    }

    public func waitForFailure() async {
        await engine.waitForFailure()
    }

    public func stop() async -> RecordingResult {
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

/// 面向入口层的共享录制 API。CLI 与 GUI 都只通过这里枚举 app 和启动录制。
public enum Recorder {
    public static let defaultBundleIdentifier = CallApplication.weChat.primaryBundleIdentifier

    public static func applications() async throws -> [CapturableApplication] {
        try await ContentResolver.runningApps().map {
            CapturableApplication(
                name: $0.applicationName,
                bundleIdentifier: $0.bundleIdentifier,
                processID: $0.processID
            )
        }
    }

    public static func application(matching query: String) async throws -> CapturableApplication {
        let app = try await ContentResolver.findApp(matching: query)
        return CapturableApplication(
            name: app.applicationName,
            bundleIdentifier: app.bundleIdentifier,
            processID: app.processID
        )
    }

    public static func startRecording(
        application: CapturableApplication,
        outputURL: URL,
        capturesMicrophone: Bool,
        sampleRate: Int = 48_000,
        channelCount: Int = 2,
        overwritesExistingOutput: Bool = false,
        logger: Logger = AppLog.logger("capture")
    ) async throws -> RecordingSession {
        guard AudioFormatConstraints.sampleRates.contains(sampleRate),
              AudioFormatConstraints.channelCounts.contains(channelCount)
        else {
            throw RecorderError.invalidConfiguration
        }
        if capturesMicrophone {
            try await MicrophonePermission.ensureAuthorized()
        }

        let target = try await ContentResolver.findApp(matching: application.bundleIdentifier)
        let filter = try await ContentResolver.filter(for: target)
        let engine = AudioCaptureEngine(
            outputURL: outputURL,
            capturesMicrophone: capturesMicrophone,
            sampleRate: sampleRate,
            channelCount: channelCount,
            overwritesExistingOutput: overwritesExistingOutput,
            logger: logger
        )
        try await engine.start(filter: filter)
        return RecordingSession(engine: engine, outputURL: outputURL)
    }
}
