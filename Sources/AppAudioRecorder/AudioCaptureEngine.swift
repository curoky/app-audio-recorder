import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// 基于 ScreenCaptureKit 的按 app 音频捕获引擎。
///
/// 设计约束：
/// - 所有对可变状态（`audioFile`/`converter`/`totalFrames`）的访问都在 `sampleQueue`
///   这一条串行队列上完成，因此对外标记 `@unchecked Sendable` 是安全的。
/// - 只捕获音频，视频配置压到最小以降低开销。
final class AudioCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let outputURL: URL

    private let sampleQueue = DispatchQueue(label: "app-audio-recorder.sample")
    private var stream: SCStream?
    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var totalFrames: AVAudioFramePosition = 0
    private var writeError: Error?

    /// 采样率与声道数，用于报告与文件头。
    let sampleRate: Int
    let channelCount: Int

    init(outputURL: URL, sampleRate: Int = 48_000, channelCount: Int = 2) {
        self.outputURL = outputURL
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    /// 已写入的时长（秒），供结束时报告。
    var recordedSeconds: Double {
        sampleQueue.sync { Double(totalFrames) / Double(sampleRate) }
    }

    // MARK: - 生命周期

    func start(filter: SCContentFilter) async throws {
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = sampleRate
        config.channelCount = channelCount
        // 不录制自己进程的声音。
        config.excludesCurrentProcessAudio = true
        // 只要音频，视频压到最小以省资源。
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 6

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async throws {
        if let stream {
            try await stream.stopCapture()
            self.stream = nil
        }
        // 在采样队列上同步关闭文件，确保 WAV 头长度被正确写回。
        sampleQueue.sync { self.audioFile = nil }
        if let writeError {
            throw writeError
        }
    }

    // MARK: - SCStreamOutput

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        write(sampleBuffer)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        sampleQueue.async { self.writeError = error }
    }

    // MARK: - 写文件（仅在 sampleQueue 上调用）

    private func write(_ sampleBuffer: CMSampleBuffer) {
        guard writeError == nil else { return }
        guard let input = Self.makePCMBuffer(from: sampleBuffer) else { return }
        do {
            let file = try ensureFile(inputFormat: input.format)
            let target = file.processingFormat
            let buffer: AVAudioPCMBuffer
            if input.format.isEqual(target) {
                buffer = input
            } else {
                buffer = try convert(input, to: target)
            }
            try file.write(from: buffer)
            totalFrames += AVAudioFramePosition(buffer.frameLength)
        } catch {
            writeError = error
        }
    }

    private func ensureFile(inputFormat: AVAudioFormat) throws -> AVAudioFile {
        if let audioFile { return audioFile }
        // 落盘为 16-bit 整型 PCM 的 WAV，兼容性最佳；
        // processingFormat 会是同采样率/声道的 float 交错格式，与 ScreenCaptureKit 输入一致。
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: Int(inputFormat.channelCount),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: outputURL, settings: settings)
        audioFile = file
        return file
    }

    private func convert(_ input: AVAudioPCMBuffer, to target: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let converter: AVAudioConverter
        if let existing = self.converter, existing.inputFormat.isEqual(input.format) {
            converter = existing
        } else {
            guard let created = AVAudioConverter(from: input.format, to: target) else {
                throw RecorderError.audioConversionFailed
            }
            self.converter = created
            converter = created
        }
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: input.frameLength) else {
            throw RecorderError.audioConversionFailed
        }
        try converter.convert(to: output, from: input)
        return output
    }

    /// 把 ScreenCaptureKit 的 `CMSampleBuffer` 转成 `AVAudioPCMBuffer`。
    private static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee,
              let format = AVAudioFormat(streamDescription: &asbd)
        else { return nil }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return nil }
        buffer.frameLength = frameCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        return buffer
    }
}
