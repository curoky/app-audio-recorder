import XCTest
@testable import AppAudioRecorderGUI

@MainActor
final class RecorderModelTests: XCTestCase {
    func testPendingPrimaryActionIsImmediatelyActive() async {
        let model = RecorderModel()

        model.triggerPrimaryAction()

        XCTAssertTrue(model.isActive)
        await model.shutdown()
        XCTAssertFalse(model.isActive)
    }
}
