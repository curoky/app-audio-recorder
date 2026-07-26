import AVFoundation
import Foundation

/// 把两路 WAV（app 音频 + 麦克风）离线混音成一个文件。
///
/// 由独立的 `merge` 子命令调用（录制与混音解耦：`record` 只产出两路独立文件，
/// 合并按需手动跑）。混音在浮点域先把两路各乘以 `gain` 再逐样本相加，最后硬限幅到
/// [-1, 1] 兜底防削波；两路时长不一致时以较长者为准，较短一路缺失部分按静音处理。
///
/// `gain` 相当于对整体混音的缩放（`gain * (app + mic)`）：传 0.5 可保证数学上不削波，
/// 0.707（-3dB）是响度与安全的折中，1.0 为等量叠加（仍靠硬限幅兜底）。
///
/// CPU 密集，调用方应放到后台执行（`@concurrent`），不占用协作线程池。
enum AudioMerger {
    /// 把 `appURL` 与 `micURL` 混音写入 `outputURL`（16-bit PCM WAV）。
    /// - Parameter gain: 两路相加前统一乘的线性增益，须 > 0。
    static func merge(appURL: URL, micURL: URL, outputURL: URL, gain: Float) throws(RecorderError) {
        do {
            try mergeThrowing(appURL: appURL, micURL: micURL, outputURL: outputURL, gain: gain)
        } catch let error as RecorderError {
            throw error
        } catch {
            throw .audioMergeFailed
        }
    }

    private static func mergeThrowing(appURL: URL, micURL: URL, outputURL: URL, gain: Float) throws {
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
                // 先按 gain 缩放两路之和，再硬限幅：gain<=0.5 时数学上必不削波，
                // 更高增益（含 >1）靠 min/max 兜底，防止溢出 [-1, 1] 造成失真。
                outPtr[frame] = min(1, max(-1, gain * (a + m)))
            }
        }

        let file = try AudioFormatSupport.makePCM16File(at: outputURL, sampleRate: sampleRate, channels: channels)
        try file.write(from: mixed)
    }

    /// 一次性把整个文件读入内存并转换成指定格式的缓冲区。
    private static func readAll(_ file: AVAudioFile, as format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount)
        else { throw RecorderError.audioMergeFailed }
        try file.read(into: source)

        var converter: AVAudioConverter?
        return try source.converted(to: format, reusing: &converter)
    }
}
