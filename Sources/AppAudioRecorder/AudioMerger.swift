import AVFoundation
import Foundation

/// 把两路 WAV（app 音频 + 麦克风）离线混音成一个文件。
///
/// 由独立的 `merge` 子命令调用（录制与混音解耦：`record` 只产出两路独立文件，
/// 合并按需手动跑）。混音在浮点域逐样本相加并硬限幅到 [-1, 1] 防削波；
/// 两路时长不一致时以较长者为准，较短一路缺失部分按静音处理。
///
/// CPU 密集，调用方应放到后台执行（`@concurrent`），不占用协作线程池。
enum AudioMerger {
    /// 把 `appURL` 与 `micURL` 混音写入 `outputURL`（16-bit PCM WAV）。
    static func merge(appURL: URL, micURL: URL, outputURL: URL) throws(RecorderError) {
        do {
            try mergeThrowing(appURL: appURL, micURL: micURL, outputURL: outputURL)
        } catch let error as RecorderError {
            throw error
        } catch {
            throw .audioMergeFailed
        }
    }

    private static func mergeThrowing(appURL: URL, micURL: URL, outputURL: URL) throws {
        let appFile = try AVAudioFile(forReading: appURL)
        let micFile = try AVAudioFile(forReading: micURL)

        // 以 app 音轨的采样率/声道为混音目标格式（非交错 float，便于逐样本运算）。
        let sampleRate = appFile.processingFormat.sampleRate
        let channels = appFile.processingFormat.channelCount
        guard let mixFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ) else {
            throw RecorderError.audioMergeFailed
        }

        let app = try readAll(appFile, as: mixFormat)
        let mic = try readAll(micFile, as: mixFormat)

        let frames = max(app.frameLength, mic.frameLength)
        guard frames > 0,
              let mixed = AVAudioPCMBuffer(pcmFormat: mixFormat, frameCapacity: frames)
        else { throw RecorderError.audioMergeFailed }
        mixed.frameLength = frames

        guard let appData = app.floatChannelData,
              let micData = mic.floatChannelData,
              let outData = mixed.floatChannelData
        else { throw RecorderError.audioMergeFailed }

        let channelCount = Int(channels)
        for ch in 0..<channelCount {
            let appPtr = appData[ch]
            let micPtr = micData[ch]
            let outPtr = outData[ch]
            let appCount = Int(app.frameLength)
            let micCount = Int(mic.frameLength)
            for frame in 0..<Int(frames) {
                let a = frame < appCount ? appPtr[frame] : 0
                let m = frame < micCount ? micPtr[frame] : 0
                // 相加后硬限幅，防止两路叠加溢出 [-1, 1] 造成削波失真。
                outPtr[frame] = min(1, max(-1, a + m))
            }
        }

        try writePCM16(mixed, to: outputURL, sampleRate: sampleRate, channels: channels)
    }

    /// 一次性把整个文件读入内存并转换成指定格式的缓冲区。
    private static func readAll(_ file: AVAudioFile, as format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount)
        else { throw RecorderError.audioMergeFailed }
        try file.read(into: source)

        if file.processingFormat.isEqual(format) {
            return source
        }
        guard let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { throw RecorderError.audioMergeFailed }
        try converter.convert(to: output, from: source)
        return output
    }

    private static func writePCM16(
        _ buffer: AVAudioPCMBuffer,
        to outputURL: URL,
        sampleRate: Double,
        channels: AVAudioChannelCount
    ) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channels),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: outputURL, settings: settings)
        try file.write(from: buffer)
    }
}
