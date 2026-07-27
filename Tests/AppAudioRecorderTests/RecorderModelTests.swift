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
        firstModel.toggleMonitoredApplication(
            bundleIdentifier: "com.example.First"
        )
        firstModel.toggleMonitoredApplication(
            bundleIdentifier: "com.example.Second"
        )

        let restoredModel = RecorderModel(defaults: defaults)
        XCTAssertEqual(
            restoredModel.selectedBundleIdentifier,
            "com.example.Audio"
        )
        XCTAssertEqual(
            restoredModel.monitoredBundleIdentifiers,
            ["com.example.First", "com.example.Second"]
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

    func testMultipleCallRemindersAreQueuedAndOnlyFireOncePerCall() async {
        let suiteName = "RecorderModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var notificationCount = 0
        let model = RecorderModel(
            defaults: defaults,
            notifyCallDetected: {
                notificationCount += 1
            }
        )
        let firstApplication = CapturableApplication(
            name: "First",
            bundleIdentifier: "com.example.First",
            processID: 1
        )
        let secondApplication = CapturableApplication(
            name: "Second",
            bundleIdentifier: "com.example.Second",
            processID: 2
        )
        model.applications = [firstApplication, secondApplication]
        model.toggleMonitoredApplication(
            bundleIdentifier: firstApplication.bundleIdentifier
        )
        model.toggleMonitoredApplication(
            bundleIdentifier: secondApplication.bundleIdentifier
        )

        model.setCallMonitoringEnabled(true)
        model.handleCallActivity(
            CallActivityEvent(
                bundleIdentifier: firstApplication.bundleIdentifier,
                isActive: true
            )
        )
        model.handleCallActivity(
            CallActivityEvent(
                bundleIdentifier: firstApplication.bundleIdentifier,
                isActive: true
            )
        )
        model.handleCallActivity(
            CallActivityEvent(
                bundleIdentifier: secondApplication.bundleIdentifier,
                isActive: true
            )
        )

        XCTAssertTrue(model.isCallMonitoring)
        XCTAssertFalse(model.isRecording)
        XCTAssertEqual(notificationCount, 1)
        XCTAssertTrue(model.callReminderMessage?.contains("First") == true)

        await model.dismissCallReminder()

        XCTAssertEqual(notificationCount, 2)
        XCTAssertTrue(model.callReminderMessage?.contains("Second") == true)

        model.handleCallActivity(
            CallActivityEvent(
                bundleIdentifier: secondApplication.bundleIdentifier,
                isActive: false
            )
        )
        XCTAssertNil(model.callReminderMessage)

        model.handleCallActivity(
            CallActivityEvent(
                bundleIdentifier: firstApplication.bundleIdentifier,
                isActive: false
            )
        )
        model.handleCallActivity(
            CallActivityEvent(
                bundleIdentifier: firstApplication.bundleIdentifier,
                isActive: true
            )
        )

        XCTAssertEqual(notificationCount, 3)
        model.setCallMonitoringEnabled(false)
        await model.shutdown()
        XCTAssertFalse(model.isActive)
    }

    func testMonitoringSelectionKeepsOnlyOneProcessPerApplicationFamily() {
        let suiteName = "RecorderModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = RecorderModel(defaults: defaults)

        model.toggleMonitoredApplication(
            bundleIdentifier: "org.whispersystems.signal-desktop"
        )
        model.toggleMonitoredApplication(
            bundleIdentifier:
                "org.whispersystems.signal-desktop.helper.Renderer"
        )

        XCTAssertEqual(
            model.monitoredBundleIdentifiers,
            ["org.whispersystems.signal-desktop.helper.Renderer"]
        )
    }
}
