import Foundation
import XCTest

@testable import AppAudioRecorder

final class RecordingSessionTests: XCTestCase {
    func testConcurrentStopsOnlyStopEngineOnce() async {
        let output = URL(fileURLWithPath: "/tmp/recording.m4a")
        let engine = StubRecordingEngine(
            stopResult: RecordingResult(
                outputURL: output,
                recordedSeconds: 12.5,
                warning: nil
            )
        )
        let session = RecordingSession(engine: engine)

        async let first = session.stop()
        async let second = session.stop()
        let results = await [first, second]
        let stopCount = await engine.stopCount

        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(results.map(\.outputURL), [output, output])
        XCTAssertEqual(results.map(\.recordedSeconds), [12.5, 12.5])
        XCTAssertTrue(results.allSatisfy { $0.warning == nil })
    }

    func testCompletedOutputCanCarryCaptureWarning() async {
        let output = URL(fileURLWithPath: "/tmp/recording.m4a")
        let engine = StubRecordingEngine(
            stopResult: RecordingResult(
                outputURL: output,
                recordedSeconds: 3,
                warning: RecorderError.audioCaptureFailed.localizedDescription
            )
        )
        let session = RecordingSession(engine: engine)

        let result = await session.stop()

        XCTAssertEqual(result.outputURL, output)
        XCTAssertEqual(result.recordedSeconds, 3)
        XCTAssertEqual(
            result.warning,
            RecorderError.audioCaptureFailed.localizedDescription
        )
    }

    func testIncompleteOutputIsNotReportedAsSaved() async {
        let engine = StubRecordingEngine(
            stopResult: RecordingResult(
                outputURL: nil,
                recordedSeconds: 3,
                warning: "写入失败"
            )
        )
        let session = RecordingSession(engine: engine)

        let result = await session.stop()

        XCTAssertNil(result.outputURL)
        XCTAssertEqual(result.warning, "写入失败")
    }
}

private actor StubRecordingEngine: RecordingEngine {
    private(set) var stopCount = 0
    private let stopResult: RecordingResult

    init(stopResult: RecordingResult) {
        self.stopResult = stopResult
    }

    func eventStream() async -> AsyncStream<RecordingEngineEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func stop() async -> RecordingResult {
        stopCount += 1
        await Task.yield()
        return stopResult
    }
}
