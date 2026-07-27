import XCTest

@testable import AppAudioRecorder

final class CallApplicationTests: XCTestCase {
    func testRecognizesSupportedMainBundles() {
        XCTAssertEqual(
            CallApplication.matching(bundleIdentifier: "com.tencent.xinWeChat"),
            .weChat
        )
        XCTAssertEqual(
            CallApplication.matching(bundleIdentifier: "org.whispersystems.signal-desktop"),
            .signal
        )
        XCTAssertEqual(
            CallApplication.matching(bundleIdentifier: "net.whatsapp.WhatsApp"),
            .whatsApp
        )
        XCTAssertEqual(
            CallApplication.matching(bundleIdentifier: "ru.keepcoder.Telegram"),
            .telegram
        )
        XCTAssertEqual(
            CallApplication.matching(bundleIdentifier: "org.telegram.desktop"),
            .telegram
        )
    }

    func testSupportedApplicationMatcherIncludesDescendantBundles() {
        let signal = ApplicationBundleMatcher(
            targetBundleIdentifier: "org.whispersystems.signal-desktop"
        )
        let whatsApp = ApplicationBundleMatcher(
            targetBundleIdentifier: "net.whatsapp.WhatsApp"
        )

        XCTAssertTrue(signal.matches("org.whispersystems.signal-desktop.helper"))
        XCTAssertTrue(signal.matches("org.whispersystems.signal-desktop.helper.Renderer"))
        XCTAssertTrue(whatsApp.matches("net.whatsapp.WhatsApp.ShareExtension"))
    }

    func testMainAndHelperBundlesBelongToSameFamilyInBothDirections() {
        let main = ApplicationBundleMatcher(
            targetBundleIdentifier: "org.whispersystems.signal-desktop"
        )
        let helper = ApplicationBundleMatcher(
            targetBundleIdentifier: "org.whispersystems.signal-desktop.helper.Renderer"
        )

        XCTAssertTrue(main.belongsToSameFamily(as: "org.whispersystems.signal-desktop.helper"))
        XCTAssertTrue(helper.belongsToSameFamily(as: "org.whispersystems.signal-desktop"))
    }

    func testTelegramVariantsRemainSeparateCaptureTargets() {
        let native = ApplicationBundleMatcher(
            targetBundleIdentifier: "ru.keepcoder.Telegram"
        )
        let desktop = ApplicationBundleMatcher(
            targetBundleIdentifier: "org.telegram.desktop"
        )

        XCTAssertTrue(native.matches("ru.keepcoder.Telegram.Share"))
        XCTAssertFalse(native.matches("org.telegram.desktop"))
        XCTAssertTrue(desktop.matches("org.telegram.desktop.helper"))
        XCTAssertFalse(desktop.matches("ru.keepcoder.Telegram"))
        XCTAssertFalse(native.belongsToSameFamily(as: "org.telegram.desktop"))
    }

    func testUnknownApplicationMatcherRemainsExact() {
        let matcher = ApplicationBundleMatcher(targetBundleIdentifier: "com.example.Audio")

        XCTAssertTrue(matcher.matches("com.example.Audio"))
        XCTAssertFalse(matcher.matches("com.example.Audio.Helper"))
    }
}
