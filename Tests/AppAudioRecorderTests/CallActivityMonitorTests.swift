import XCTest

@testable import AppAudioRecorder

final class CallActivityMonitorTests: XCTestCase {
    func testSingleInactivePollDoesNotEndActiveCall() {
        var debouncer = CallActivityDebouncer()

        XCTAssertEqual(debouncer.update(rawIsActive: true), true)
        XCTAssertNil(debouncer.update(rawIsActive: true))
        XCTAssertNil(debouncer.update(rawIsActive: false))
        XCTAssertNil(debouncer.update(rawIsActive: true))
        XCTAssertTrue(debouncer.isActive)
    }

    func testTwoConsecutiveInactivePollsEndCallOnce() {
        var debouncer = CallActivityDebouncer()

        XCTAssertEqual(debouncer.update(rawIsActive: true), true)
        XCTAssertNil(debouncer.update(rawIsActive: false))
        XCTAssertEqual(debouncer.update(rawIsActive: false), false)
        XCTAssertNil(debouncer.update(rawIsActive: false))
        XCTAssertFalse(debouncer.isActive)

        XCTAssertEqual(debouncer.update(rawIsActive: true), true)
        XCTAssertNil(debouncer.update(rawIsActive: true))
    }
}
