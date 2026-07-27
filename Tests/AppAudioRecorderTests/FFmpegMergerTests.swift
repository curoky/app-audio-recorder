import AVFoundation
import XCTest
@testable import AppAudioRecorder

final class FFmpegMergerTests: XCTestCase {
    // MARK: - 参数构造（纯函数，锁定混音契约）

    func testArgumentsEncodeMixContract() {
        let args = FFmpegMerger.arguments(
            containerURL: URL(fileURLWithPath: "/tmp/rec.m4a"),
            outputURL: URL(fileURLWithPath: "/tmp/rec-merged.wav"),
            sampleRate: 48_000,
            channels: 2,
            gain: 0.707
        )

        // 单容器作为唯一输入。
        XCTAssertEqual(value(args, after: "-i"), "/tmp/rec.m4a")

        // 输出显式跟随轨 0 格式（amix 自身协商不保证跟随）。
        XCTAssertEqual(value(args, after: "-ar"), "48000")
        XCTAssertEqual(value(args, after: "-ac"), "2")
        XCTAssertEqual(value(args, after: "-c:a"), "pcm_s16le")

        // 引用容器内两条轨 [0:a:0][0:a:1]；纯和 + 缩放 + 取较长时长。
        let filter = try? XCTUnwrap(value(args, after: "-filter_complex"))
        XCTAssertNotNil(filter)
        XCTAssertTrue(filter!.contains("[0:a:0][0:a:1]"))
        XCTAssertTrue(filter!.contains("amix=inputs=2"))
        XCTAssertTrue(filter!.contains("duration=longest"))
        XCTAssertTrue(filter!.contains("normalize=0"))
        XCTAssertTrue(filter!.contains("volume=0.707"))

        // 输出路径为最后一个参数。
        XCTAssertEqual(args.last, "/tmp/rec-merged.wav")
    }

    func testArgumentsFormatGainWithoutScientificNotation() {
        let args = FFmpegMerger.arguments(
            containerURL: URL(fileURLWithPath: "/tmp/rec.m4a"),
            outputURL: URL(fileURLWithPath: "/tmp/o.wav"),
            sampleRate: 16_000,
            channels: 1,
            gain: 0.5
        )
        let filter = try? XCTUnwrap(value(args, after: "-filter_complex"))
        XCTAssertEqual(filter, "[0:a:0][0:a:1]amix=inputs=2:duration=longest:dropout_transition=0:normalize=0,volume=0.5[out]")
    }

    // MARK: - 集成（需系统装有 ffmpeg，否则跳过）

    func testMergeFollowsFirstTrackFormatAndLongerDuration() async throws {
        try XCTSkipUnless(ffmpegAvailable(), "未安装 ffmpeg，跳过混音集成测试")

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 轨 0 48k/2ch/0.5s，轨 1 44.1k/1ch/1.0s：输出应跟随轨 0 的 48k/2ch，时长取较长 1.0s。
        let appURL = directory.appendingPathComponent("app.wav")
        let micURL = directory.appendingPathComponent("mic.wav")
        let containerURL = directory.appendingPathComponent("rec.m4a")
        let outputURL = directory.appendingPathComponent("rec-merged.wav")
        try writeTone(to: appURL, sampleRate: 48_000, channels: 2, frameCount: 24_000)
        try writeTone(to: micURL, sampleRate: 44_100, channels: 1, frameCount: 44_100)
        try packContainer(appURL: appURL, micURL: micURL, to: containerURL)

        try await FFmpegMerger.merge(containerURL: containerURL, outputURL: outputURL, gain: 0.5)

        let output = try AVAudioFile(forReading: outputURL)
        XCTAssertEqual(output.processingFormat.sampleRate, 48_000)
        XCTAssertEqual(output.processingFormat.channelCount, 2)
        XCTAssertEqual(output.length, 48_000, accuracy: 2)
    }

    func testMergeRejectsSingleTrackContainer() async throws {
        try XCTSkipUnless(ffmpegAvailable(), "未安装 ffmpeg，跳过混音集成测试")

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 单轨容器（模拟 record --no-mic 产出）应被 probe 拒绝，报 containerMissingSecondTrack。
        let appURL = directory.appendingPathComponent("app.wav")
        let containerURL = directory.appendingPathComponent("rec.m4a")
        let outputURL = directory.appendingPathComponent("rec-merged.wav")
        try writeTone(to: appURL, sampleRate: 48_000, channels: 2, frameCount: 24_000)
        try packContainer(appURL: appURL, micURL: nil, to: containerURL)

        do {
            try await FFmpegMerger.merge(containerURL: containerURL, outputURL: outputURL, gain: 0.5)
            XCTFail("单轨容器应抛出 containerMissingSecondTrack")
        } catch let error as RecorderError {
            guard case .containerMissingSecondTrack = error else {
                XCTFail("期望 containerMissingSecondTrack，实际为 \(error)")
                return
            }
        }
    }

    // MARK: - 辅助

    private func value(_ args: [String], after flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
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

    /// 用 ffmpeg 把一到两路 WAV 无损打包成 ALAC 多轨容器，模拟 record 产出。
    private func packContainer(appURL: URL, micURL: URL?, to output: URL) throws {
        var args = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-i", appURL.path]
        if let micURL {
            args += ["-i", micURL.path, "-map", "0:a:0", "-map", "1:a:0"]
        } else {
            args += ["-map", "0:a:0"]
        }
        args += ["-c:a", "alac", output.path]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: FFmpegMerger.ffmpegPath)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "打包测试容器失败")
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
