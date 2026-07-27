import XCTest

@testable import AppAudioRecorder

@MainActor
final class RecorderModelTests: XCTestCase {
    func testSelectedApplicationPersists() {
        let suiteName = "RecorderModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstModel = RecorderModel(defaults: defaults)
        firstModel.selectApplication(bundleIdentifier: "com.example.Audio")

        let restoredModel = RecorderModel(defaults: defaults)
        XCTAssertEqual(
            restoredModel.selectedBundleIdentifier,
            "com.example.Audio"
        )
    }

    func testDefaultRecordingConfiguration() {
        let model = RecorderModel()

        XCTAssertEqual(model.recordingConfiguration.sampleRate, .hz48K)
        XCTAssertEqual(model.recordingConfiguration.channelCount, .stereo)
        XCTAssertTrue(model.recordingConfiguration.capturesMicrophone)
        XCTAssertFalse(model.isCallMonitoring)
    }

    func testRecordingConfigurationOffersCommonAudioFormats() {
        XCTAssertEqual(
            RecordingConfiguration.SampleRate.allCases.map(\.rawValue),
            [8_000, 16_000, 24_000, 32_000, 44_100, 48_000]
        )
        XCTAssertEqual(
            RecordingConfiguration.ChannelCount.allCases.map(\.rawValue),
            [1, 2]
        )
    }

    func testPendingPrimaryActionIsImmediatelyActive() async {
        let model = RecorderModel()

        model.triggerPrimaryAction()

        XCTAssertTrue(model.isActive)
        await model.shutdown()
        XCTAssertFalse(model.isActive)
    }

    func testCallReminderRequiresManualRecordingAndOnlyFiresOncePerCall() async {
        var notificationCount = 0
        let model = RecorderModel(notifyCallDetected: {
            notificationCount += 1
        })
        let application = CapturableApplication(
            name: "Example",
            bundleIdentifier: "com.example.Audio",
            processID: 1
        )
        model.applications = [application]
        model.selectApplication(bundleIdentifier: application.bundleIdentifier)

        model.setCallMonitoringEnabled(true)
        model.handleCallActivity(true)
        model.handleCallActivity(true)

        XCTAssertTrue(model.isCallMonitoring)
        XCTAssertFalse(model.isRecording)
        XCTAssertEqual(notificationCount, 1)
        XCTAssertNotNil(model.callReminderMessage)

        model.handleCallActivity(false)
        model.handleCallActivity(true)

        XCTAssertEqual(notificationCount, 2)
        model.setCallMonitoringEnabled(false)
        await model.shutdown()
        XCTAssertFalse(model.isActive)
    }
}
