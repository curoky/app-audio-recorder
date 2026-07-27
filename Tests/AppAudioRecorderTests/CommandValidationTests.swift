import XCTest
@testable import AppAudioRecorder

final class CommandValidationTests: XCTestCase {
    func testRecordRejectsInvalidAudioConfiguration() {
        XCTAssertThrowsError(try RecordCommand.parse(["--sample-rate", "7999"]))
        XCTAssertThrowsError(try RecordCommand.parse(["--sample-rate", "48001"]))
        XCTAssertThrowsError(try RecordCommand.parse(["--channels", "3"]))
        XCTAssertThrowsError(try RecordCommand.parse(["--duration=-1"]))
    }

    func testRecordAcceptsSupportedAudioBoundaries() throws {
        let minimum = try RecordCommand.parse(["--sample-rate", "8000", "--channels", "1"])
        XCTAssertEqual(minimum.sampleRate, 8_000)
        XCTAssertEqual(minimum.channels, 1)

        let maximum = try RecordCommand.parse(["--sample-rate", "48000", "--channels", "2"])
        XCTAssertEqual(maximum.sampleRate, 48_000)
        XCTAssertEqual(maximum.channels, 2)
    }

    func testRecordRejectsBlankAppQuery() {
        XCTAssertThrowsError(try RecordCommand.parse(["--app", " \n "]))
    }

    func testWatchRejectsInvalidConfiguration() {
        XCTAssertThrowsError(try WatchCommand.parse(["--sample-rate", "7999"]))
        XCTAssertThrowsError(try WatchCommand.parse(["--sample-rate", "48001"]))
        XCTAssertThrowsError(try WatchCommand.parse(["--channels", "3"]))
        XCTAssertThrowsError(try WatchCommand.parse(["--silence=-1"]))
        XCTAssertThrowsError(try WatchCommand.parse(["--silence", "inf"]))
        XCTAssertThrowsError(try WatchCommand.parse(["--silence", "nan"]))
    }

    func testWatchAcceptsSupportedBoundaries() throws {
        let command = try WatchCommand.parse([
            "--sample-rate", "8000",
            "--channels", "1",
            "--silence", "0",
        ])
        XCTAssertEqual(command.sampleRate, 8_000)
        XCTAssertEqual(command.channels, 1)
        XCTAssertEqual(command.silence, 0)
    }

    func testWatchRejectsBlankAppQuery() {
        XCTAssertThrowsError(try WatchCommand.parse(["--app", " \n "]))
    }
}
