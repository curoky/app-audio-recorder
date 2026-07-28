import XCTest

@testable import AppAudioRecorder

final class RecordingHealthTests: XCTestCase {
    func testAudibleTracksProduceNoWarnings() {
        let warnings = RecordingHealth.warnings(
            app: audible(),
            mic: audible()
        )
        XCTAssertTrue(warnings.isEmpty)
    }

    func testMicOnlyRecordingIgnoresAbsentMicTrack() {
        let warnings = RecordingHealth.warnings(app: audible(), mic: nil)
        XCTAssertTrue(warnings.isEmpty)
    }

    func testEmptyTrackIsReportedAsMissing() {
        let warnings = RecordingHealth.warnings(
            app: .empty,
            mic: audible()
        )
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("目标 App"))
        XCTAssertTrue(warnings[0].contains("音轨为空"))
    }

    func testMeasuredSilentTrackIsReportedAsSilent() {
        let silentMic = TrackAudioHealth(
            capturedFrames: 48_000,
            peakAmplitude: 0,
            didMeasurePeak: true,
            droppedBuffers: 0
        )
        let warnings = RecordingHealth.warnings(app: audible(), mic: silentMic)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("麦克风"))
        XCTAssertTrue(warnings[0].contains("静音"))
    }

    func testUnmeasuredTrackWithFramesIsNotReportedAsSilent() {
        // 有捕获帧但从未成功测量峰值（如非 float32），不应误报静音。
        let unmeasured = TrackAudioHealth(
            capturedFrames: 48_000,
            peakAmplitude: 0,
            didMeasurePeak: false,
            droppedBuffers: 0
        )
        let warnings = RecordingHealth.warnings(app: unmeasured, mic: nil)
        XCTAssertTrue(warnings.isEmpty)
    }

    func testQuietButAudibleTrackIsNotReportedAsSilent() {
        let quiet = TrackAudioHealth(
            capturedFrames: 48_000,
            peakAmplitude: RecordingHealth.silencePeakThreshold * 2,
            didMeasurePeak: true,
            droppedBuffers: 0
        )
        let warnings = RecordingHealth.warnings(app: quiet, mic: nil)
        XCTAssertTrue(warnings.isEmpty)
    }

    func testExcessiveDroppedBuffersAreReported() {
        let dropping = TrackAudioHealth(
            capturedFrames: 48_000,
            peakAmplitude: 0.5,
            didMeasurePeak: true,
            droppedBuffers: RecordingHealth.droppedBufferWarningThreshold
        )
        let warnings = RecordingHealth.warnings(app: dropping, mic: nil)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("丢弃"))
    }

    func testFewDroppedBuffersAreTolerated() {
        let dropping = TrackAudioHealth(
            capturedFrames: 48_000,
            peakAmplitude: 0.5,
            didMeasurePeak: true,
            droppedBuffers: RecordingHealth.droppedBufferWarningThreshold - 1
        )
        let warnings = RecordingHealth.warnings(app: dropping, mic: nil)
        XCTAssertTrue(warnings.isEmpty)
    }

    func testEmptyTrackDoesNotAlsoReportSilence() {
        // 缺轨只报一条「音轨为空」，不再叠加「静音」提示。
        let warnings = RecordingHealth.warnings(app: .empty, mic: nil)
        XCTAssertEqual(warnings.count, 1)
    }

    private func audible() -> TrackAudioHealth {
        TrackAudioHealth(
            capturedFrames: 48_000,
            peakAmplitude: 0.5,
            didMeasurePeak: true,
            droppedBuffers: 0
        )
    }
}
