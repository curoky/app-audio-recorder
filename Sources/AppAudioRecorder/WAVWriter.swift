import AVFoundation
import CoreMedia

/// 把 ScreenCaptureKit 输出的浮点音频样本落盘为 16-bit PCM WAV。
///
/// 非 `Sendable`：实例只由 `AudioCaptureEngine` 在其串行采样队列上使用，不跨隔离域共享，
/// 因此无需加锁或 actor 隔离。文件按首个样本的输入格式惰性创建。
nonisolated final class WAVWriter {
    private let outputURL: URL
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private(set) var totalFrames: AVAudioFramePosition = 0

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    /// 追加一段样本；必要时把浮点样本转换成文件的处理格式再写入。
    func write(_ sampleBuffer: CMSampleBuffer) throws {
        guard let input = Self.pcmBuffer(from: sampleBuffer) else { return }
        let file = try ensureFile(inputFormat: input.format)
        let target = file.processingFormat
        let buffer = input.format.isEqual(target) ? input : try convert(input, to: target)
        try file.write(from: buffer)
        totalFrames += AVAudioFramePosition(buffer.frameLength)
    }

    /// 关闭文件以写回 WAV 头长度。必须在停止写入后、且仍在采样队列上调用。
    func finish() {
        file = nil
    }

    private func ensureFile(inputFormat: AVAudioFormat) throws -> AVAudioFile {
        if let file { return file }
        // 落盘为 16-bit 整型 PCM WAV，兼容性最佳；processingFormat 会是同采样率/声道的
        // float 交错格式，与 ScreenCaptureKit 的输入一致。
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: Int(inputFormat.channelCount),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let created = try AVAudioFile(forWriting: outputURL, settings: settings)
        file = created
        return created
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
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
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
