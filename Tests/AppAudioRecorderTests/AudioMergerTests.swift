import AVFoundation
import XCTest
@testable import AppAudioRecorder

final class AudioMergerTests: XCTestCase {
    func testBufferConversionAllocatesUpsampledCapacity() throws {
        let sourceFormat = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 44_100,
                channels: 1,
                interleaved: false
            )
        )
        let targetFormat = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let source = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 44_100)
        )
        source.frameLength = 44_100

        var converter: AVAudioConverter?
        let output = try source.converted(to: targetFormat, reusing: &converter)

        XCTAssertEqual(output.frameLength, 48_000, accuracy: 2)
    }

    func testMergesDifferentSampleRates() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let appURL = directory.appendingPathComponent("app.wav")
        let micURL = directory.appendingPathComponent("mic.wav")
        let outputURL = directory.appendingPathComponent("merged.wav")
        try writeTone(to: appURL, sampleRate: 48_000, frameCount: 48_000)
        try writeTone(to: micURL, sampleRate: 44_100, frameCount: 44_100)

        try AudioMerger.merge(
            appURL: appURL,
            micURL: micURL,
            outputURL: outputURL,
            gain: 0.5
        )

        let output = try AVAudioFile(forReading: outputURL)
        XCTAssertEqual(output.processingFormat.sampleRate, 48_000)
        XCTAssertEqual(output.length, 48_000, accuracy: 2)
    }

    func testUsesLongerInputDuration() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let appURL = directory.appendingPathComponent("app.wav")
        let micURL = directory.appendingPathComponent("mic.wav")
        let outputURL = directory.appendingPathComponent("merged.wav")
        try writeTone(to: appURL, sampleRate: 48_000, frameCount: 24_000)
        try writeTone(to: micURL, sampleRate: 44_100, frameCount: 44_100)

        try AudioMerger.merge(
            appURL: appURL,
            micURL: micURL,
            outputURL: outputURL,
            gain: 0.5
        )

        let output = try AVAudioFile(forReading: outputURL)
        XCTAssertEqual(output.length, 48_000, accuracy: 2)
    }

    func testConvertsMicChannelCountToAppFormat() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let appURL = directory.appendingPathComponent("app.wav")
        let micURL = directory.appendingPathComponent("mic.wav")
        let outputURL = directory.appendingPathComponent("merged.wav")
        try writeTone(
            to: appURL,
            sampleRate: 48_000,
            channels: 2,
            frameCount: 12_000
        )
        try writeTone(
            to: micURL,
            sampleRate: 44_100,
            channels: 1,
            frameCount: 11_025
        )

        try AudioMerger.merge(
            appURL: appURL,
            micURL: micURL,
            outputURL: outputURL,
            gain: 0.5
        )

        let output = try AVAudioFile(forReading: outputURL)
        XCTAssertEqual(output.processingFormat.channelCount, 2)
        XCTAssertEqual(output.length, 12_000, accuracy: 2)
    }

    func testRejectsNonFiniteGain() throws {
        let missing = URL(fileURLWithPath: "/missing.wav")
        XCTAssertThrowsError(
            try AudioMerger.merge(
                appURL: missing,
                micURL: missing,
                outputURL: missing,
                gain: .infinity
            )
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        return directory
    }

    private func writeTone(
        to url: URL,
        sampleRate: Double,
        channels: AVAudioChannelCount = 1,
        frameCount: AVAudioFrameCount
    ) throws {
        let file = try AudioFormatSupport.makePCM16File(
            at: url,
            sampleRate: sampleRate,
            channels: channels
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: frameCount
        ), let channelData = buffer.floatChannelData else {
            XCTFail("无法创建测试音频缓冲区")
            return
        }

        buffer.frameLength = frameCount
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frameCount) {
                channelData[channel][frame] =
                    0.25 * sin(2 * .pi * 440 * Float(frame) / Float(sampleRate))
            }
        }
        try file.write(from: buffer)
    }
}
