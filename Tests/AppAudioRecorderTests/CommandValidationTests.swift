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

    func testMergeRejectsNonFiniteGain() {
        XCTAssertThrowsError(
            try MergeCommand.parse(["app.wav", "mic.wav", "--gain", "inf"])
        )
    }
}
