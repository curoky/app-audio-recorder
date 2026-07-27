import AVFoundation
import XCTest
@testable import AppAudioRecorder

final class FFmpegMergerTests: XCTestCase {
    // MARK: - 参数构造（纯函数，锁定混音契约）

    func testArgumentsEncodeMixContract() {
        let args = FFmpegMerger.arguments(
            appURL: URL(fileURLWithPath: "/tmp/a-app.wav"),
            micURL: URL(fileURLWithPath: "/tmp/a-mic.wav"),
            outputURL: URL(fileURLWithPath: "/tmp/a-merged.wav"),
            sampleRate: 48_000,
            channels: 2,
            gain: 0.707
        )

        // 两路输入按 app、mic 顺序传入。
        XCTAssertEqual(indexedValue(args, after: "-i", occurrence: 1), "/tmp/a-app.wav")
        XCTAssertEqual(indexedValue(args, after: "-i", occurrence: 2), "/tmp/a-mic.wav")

        // 输出显式跟随第一路格式（amix 自身协商不保证跟随）。
        XCTAssertEqual(value(args, after: "-ar"), "48000")
        XCTAssertEqual(value(args, after: "-ac"), "2")
        XCTAssertEqual(value(args, after: "-c:a"), "pcm_s16le")

        // 纯和 + 缩放 + 取较长时长：normalize=0、volume=gain、duration=longest。
        let filter = try? XCTUnwrap(value(args, after: "-filter_complex"))
        XCTAssertNotNil(filter)
        XCTAssertTrue(filter!.contains("amix=inputs=2"))
        XCTAssertTrue(filter!.contains("duration=longest"))
        XCTAssertTrue(filter!.contains("normalize=0"))
        XCTAssertTrue(filter!.contains("volume=0.707"))

        // 输出路径为最后一个参数。
        XCTAssertEqual(args.last, "/tmp/a-merged.wav")
    }

    func testArgumentsFormatGainWithoutScientificNotation() {
        let args = FFmpegMerger.arguments(
            appURL: URL(fileURLWithPath: "/tmp/a.wav"),
            micURL: URL(fileURLWithPath: "/tmp/b.wav"),
            outputURL: URL(fileURLWithPath: "/tmp/o.wav"),
            sampleRate: 16_000,
            channels: 1,
            gain: 0.5
        )
        let filter = try? XCTUnwrap(value(args, after: "-filter_complex"))
        XCTAssertEqual(filter, "[0:a][1:a]amix=inputs=2:duration=longest:dropout_transition=0:normalize=0,volume=0.5[out]")
    }

    // MARK: - 集成（需系统装有 ffmpeg，否则跳过）

    func testMergeFollowsFirstInputFormatAndLongerDuration() async throws {
        try XCTSkipUnless(ffmpegAvailable(), "未安装 ffmpeg，跳过混音集成测试")

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 第一路 48k/2ch/0.5s，第二路 44.1k/1ch/1.0s：输出应跟随第一路 48k/2ch，时长取较长 1.0s。
        let appURL = directory.appendingPathComponent("app.wav")
        let micURL = directory.appendingPathComponent("mic.wav")
        let outputURL = directory.appendingPathComponent("merged.wav")
        try writeTone(to: appURL, sampleRate: 48_000, channels: 2, frameCount: 24_000)
        try writeTone(to: micURL, sampleRate: 44_100, channels: 1, frameCount: 44_100)

        try await FFmpegMerger.merge(appURL: appURL, micURL: micURL, outputURL: outputURL, gain: 0.5)

        let output = try AVAudioFile(forReading: outputURL)
        XCTAssertEqual(output.processingFormat.sampleRate, 48_000)
        XCTAssertEqual(output.processingFormat.channelCount, 2)
        XCTAssertEqual(output.length, 48_000, accuracy: 2)
    }

    // MARK: - 辅助

    private func value(_ args: [String], after flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// 取第 `occurrence` 次出现的 `flag` 之后一个值（用于多次出现的 `-i`）。
    private func indexedValue(_ args: [String], after flag: String, occurrence: Int) -> String? {
        var seen = 0
        for (i, arg) in args.enumerated() where arg == flag {
            seen += 1
            if seen == occurrence { return i + 1 < args.count ? args[i + 1] : nil }
        }
        return nil
    }

    private func ffmpegAvailable() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: FFmpegMerger.ffmpegPath)
        process.arguments = ["-version"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func writeTone(
        to url: URL,
        sampleRate: Double,
        channels: AVAudioChannelCount = 1,
        frameCount: AVAudioFrameCount
    ) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channels),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
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
