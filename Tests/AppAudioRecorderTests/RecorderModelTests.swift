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
        XCTAssertEqual(model.callEndDelay, .twoSeconds)
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
}
