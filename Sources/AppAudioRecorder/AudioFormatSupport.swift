import AVFoundation
import Foundation

/// 音频与路径相关的共享工具，收敛 `WAVWriter`/`AudioMerger`/各命令间原本重复的逻辑：
/// 16-bit PCM WAV 落盘格式、按需格式转换、`~` 路径展开。
enum AudioFormatSupport {
    /// 创建一个 16-bit 整型 PCM WAV 写入文件（小端、非浮点），落盘格式全项目统一走这里。
    static func makePCM16File(
        at url: URL,
        sampleRate: Double,
        channels: AVAudioChannelCount
    ) throws -> AVAudioFile {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channels),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        return try AVAudioFile(forWriting: url, settings: settings)
    }
}

extension AVAudioPCMBuffer {
    /// 把缓冲区转换成 `target` 格式；格式已一致时原样返回，避免多余分配。
    /// - Parameter converter: 传入可复用的转换器缓存（首次为 nil 时创建并回填）。
    func converted(
        to target: AVAudioFormat,
        reusing converter: inout AVAudioConverter?
    ) throws(RecorderError) -> AVAudioPCMBuffer {
        if format.isEqual(target) { return self }

        let active: AVAudioConverter
        if let existing = converter, existing.inputFormat.isEqual(format) {
            active = existing
        } else {
            guard let created = AVAudioConverter(from: format, to: target) else {
                throw .audioConversionFailed
            }
            converter = created
            active = created
        }

        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: frameLength) else {
            throw .audioConversionFailed
        }
        do {
            try active.convert(to: output, from: self)
        } catch {
            throw .audioConversionFailed
        }
        return output
    }
}

extension URL {
    /// 从命令行字符串构造本地文件 URL，展开开头的 `~`。
    init(expandingPath path: String) {
        self.init(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}
