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
    private static let chunkFrames: AVAudioFrameCount = 4_096

    /// 把 `appURL` 与 `micURL` 混音写入 `outputURL`（16-bit PCM WAV）。
    /// - Parameter gain: 两路相加前统一乘的线性增益，须 > 0。
    static func merge(appURL: URL, micURL: URL, outputURL: URL, gain: Float) throws(RecorderError) {
        guard gain.isFinite, gain > 0 else {
            throw .audioMergeFailed
        }
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

        let appReader = try ConvertedAudioReader(file: appFile, targetFormat: mixFormat)
        let micReader = try ConvertedAudioReader(file: micFile, targetFormat: mixFormat)
        guard let mixed = AVAudioPCMBuffer(pcmFormat: mixFormat, frameCapacity: chunkFrames)
        else { throw RecorderError.audioMergeFailed }

        let outputFile = try AudioFormatSupport.makePCM16File(
            at: outputURL,
            sampleRate: sampleRate,
            channels: channels
        )
        let channelCount = Int(channels)
        while true {
            let app = try appReader.read(maxFrames: chunkFrames)
            let mic = try micReader.read(maxFrames: chunkFrames)
            let frames = max(app.frameLength, mic.frameLength)
            guard frames > 0 else { break }
            mixed.frameLength = frames

            guard let appData = app.floatChannelData,
                  let micData = mic.floatChannelData,
                  let outData = mixed.floatChannelData
            else { throw RecorderError.audioMergeFailed }

            for ch in 0..<channelCount {
                let appPtr = appData[ch]
                let micPtr = micData[ch]
                let outPtr = outData[ch]
                let appCount = Int(app.frameLength)
                let micCount = Int(mic.frameLength)
                for frame in 0..<Int(frames) {
                    let a = frame < appCount ? appPtr[frame] : 0
                    let m = frame < micCount ? micPtr[frame] : 0
                    outPtr[frame] = min(1, max(-1, gain * (a + m)))
                }
            }
            try outputFile.write(from: mixed)
        }
    }

    /// 按目标格式分块读取，转换器跨块复用以保持重采样状态连续。
    private final class ConvertedAudioReader {
        private let file: AVAudioFile
        private let converter: AVAudioConverter?
        private let sourceBuffer: AVAudioPCMBuffer?
        private let outputBuffer: AVAudioPCMBuffer
        private var inputEnded = false
        private var conversionEnded = false

        init(file: AVAudioFile, targetFormat: AVAudioFormat) throws {
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: AudioMerger.chunkFrames
            ) else {
                throw RecorderError.audioConversionFailed
            }
            self.file = file
            self.outputBuffer = outputBuffer
            if file.processingFormat.isEqual(targetFormat) {
                self.converter = nil
                self.sourceBuffer = nil
            } else {
                guard let converter = AVAudioConverter(
                    from: file.processingFormat,
                    to: targetFormat
                ), let sourceBuffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat,
                    frameCapacity: AudioMerger.chunkFrames
                ) else {
                    throw RecorderError.audioConversionFailed
                }
                self.converter = converter
                self.sourceBuffer = sourceBuffer
            }
        }

        func read(maxFrames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
            let output = outputBuffer
            output.frameLength = 0
            guard !conversionEnded else { return output }

            guard let converter, let sourceBuffer else {
                let remainingFrames = file.length - file.framePosition
                guard remainingFrames > 0 else {
                    conversionEnded = true
                    return output
                }
                try file.read(
                    into: output,
                    frameCount: min(maxFrames, AVAudioFrameCount(remainingFrames))
                )
                return output
            }

            var inputError: Error?
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) {
                [self] requestedFrames, inputStatus in
                if inputEnded {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                guard requestedFrames > 0 else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                let remainingFrames = file.length - file.framePosition
                guard remainingFrames > 0 else {
                    inputEnded = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }

                do {
                    sourceBuffer.frameLength = 0
                    try file.read(
                        into: sourceBuffer,
                        frameCount: min(
                            requestedFrames,
                            sourceBuffer.frameCapacity,
                            AVAudioFrameCount(remainingFrames)
                        )
                    )
                } catch {
                    inputError = error
                    inputStatus.pointee = .noDataNow
                    return nil
                }

                guard sourceBuffer.frameLength > 0 else {
                    inputEnded = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return sourceBuffer
            }

            if inputError != nil || status == .error {
                throw conversionError ?? RecorderError.audioConversionFailed
            }
            if status == .endOfStream || (inputEnded && output.frameLength == 0) {
                conversionEnded = true
            }
            return output
        }
    }
}
