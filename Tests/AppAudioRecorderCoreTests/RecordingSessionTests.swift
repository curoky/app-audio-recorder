import Foundation
import XCTest
@testable import AppAudioRecorderCore

final class RecordingSessionTests: XCTestCase {
    func testConcurrentStopsOnlyStopEngineOnce() async {
        let engine = StubRecordingEngine(recordedSeconds: 12.5)
        let output = URL(fileURLWithPath: "/tmp/recording.m4a")
        let session = RecordingSession(engine: engine, outputURL: output)

        async let first = session.stop()
        async let second = session.stop()
        let results = await [first, second]
        let stopCount = await engine.stopCount

        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(results.map(\.outputURL), [output, output])
        XCTAssertEqual(results.map(\.recordedSeconds), [12.5, 12.5])
        XCTAssertTrue(results.allSatisfy { $0.warning == nil })
    }

    func testStopReturnsUnderlyingErrorAsWarning() async {
        let engine = StubRecordingEngine(
            recordedSeconds: 3,
            stopError: RecorderError.invalidConfiguration
        )
        let session = RecordingSession(
            engine: engine,
            outputURL: URL(fileURLWithPath: "/tmp/recording.m4a")
        )

        let result = await session.stop()

        XCTAssertEqual(result.recordedSeconds, 3)
        XCTAssertEqual(result.warning, RecorderError.invalidConfiguration.localizedDescription)
    }
}

private actor StubRecordingEngine: RecordingEngine {
    let recordedSeconds: Double
    private(set) var stopCount = 0
    private let stopError: (any Error)?

    init(recordedSeconds: Double, stopError: (any Error)? = nil) {
        self.recordedSeconds = recordedSeconds
        self.stopError = stopError
    }

    func waitForFailure() async {}

    func stop() async throws {
        stopCount += 1
        await Task.yield()
        if let stopError {
            throw stopError
        }
    }
}
