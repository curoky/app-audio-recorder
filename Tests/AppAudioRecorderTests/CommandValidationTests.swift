import XCTest
@testable import AppAudioRecorder

final class CommandValidationTests: XCTestCase {
    func testRecordRejectsInvalidAudioConfiguration() {
        XCTAssertThrowsError(try RecordCommand.parse(["--sample-rate", "0"]))
        XCTAssertThrowsError(try RecordCommand.parse(["--channels", "3"]))
        XCTAssertThrowsError(try RecordCommand.parse(["--duration=-1"]))
    }

    func testRecordRejectsBlankAppQuery() {
        XCTAssertThrowsError(try RecordCommand.parse(["--app", " \n "]))
    }

    func testWatchRejectsInvalidConfiguration() {
        XCTAssertThrowsError(try WatchCommand.parse(["--sample-rate", "0"]))
        XCTAssertThrowsError(try WatchCommand.parse(["--channels", "3"]))
        XCTAssertThrowsError(try WatchCommand.parse(["--silence=-1"]))
    }

    func testWatchRejectsBlankAppQuery() {
        XCTAssertThrowsError(try WatchCommand.parse(["--app", " \n "]))
    }
}
