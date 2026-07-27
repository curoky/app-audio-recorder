import AVFoundation
import Foundation
import Subprocess
import System

/// 用 `ffmpeg` 把两路 WAV（app 音频 + 麦克风）离线混音成一个 16-bit PCM WAV。
///
/// 由 `merge` 子命令调用。混音语义与旧的原生实现一致：
/// - `amix=normalize=0` + `volume=<gain>` 等价 `gain * (app + mic)`（纯和后统一缩放），
///   `pcm_s16le` 编码对越界样本饱和 clamp，等价硬限幅防削波；
/// - `duration=longest` 让时长取较长一路，较短一路结束后按静音补齐；
/// - 输出显式 `-ar/-ac` 跟随第一路（app）的采样率/声道——`amix` 自身的格式协商并不
///   保证跟随第一路，必须强制。
///
/// 第一路格式用 `AVAudioFile` 探测（只读元数据，不做 DSP），因此只依赖 `ffmpeg` 一个外部命令。
enum FFmpegMerger {
    /// 固定的 `ffmpeg` 可执行路径（自编译静态版本），不依赖 `PATH` 查找。
    static let ffmpegPath = "/opt/sb/bin/ffmpeg"

    /// 混音入口：探测第一路格式 → 构造参数 → 调用 `ffmpeg`。
    static func merge(
        appURL: URL,
        micURL: URL,
        outputURL: URL,
        gain: Float
    ) async throws(RecorderError) {
        let format = try probeFormat(appURL)
        let args = arguments(
            appURL: appURL,
            micURL: micURL,
            outputURL: outputURL,
            sampleRate: format.sampleRate,
            channels: format.channels,
            gain: gain
        )
        try await run(args)
    }

    /// 构造 `ffmpeg` 参数（不含可执行名），抽成纯函数便于单测。
    static func arguments(
        appURL: URL,
        micURL: URL,
        outputURL: URL,
        sampleRate: Int,
        channels: Int,
        gain: Float
    ) -> [String] {
        // %g 避免 Float 打印出多余精度或科学计数法（0.707 → "0.707"）。
        let gainLiteral = String(format: "%g", Double(gain))
        let filter =
            "[0:a][1:a]amix=inputs=2:duration=longest:dropout_transition=0:normalize=0,"
            + "volume=\(gainLiteral)[out]"
        return [
            "-hide_banner", "-nostdin", "-y",
            "-i", appURL.path,
            "-i", micURL.path,
            "-filter_complex", filter,
            "-map", "[out]",
            "-ar", "\(sampleRate)",
            "-ac", "\(channels)",
            "-c:a", "pcm_s16le",
            outputURL.path,
        ]
    }

    // MARK: - 私有

    private static func probeFormat(_ url: URL) throws(RecorderError) -> (sampleRate: Int, channels: Int) {
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            return (Int(format.sampleRate), Int(format.channelCount))
        } catch {
            throw .audioMergeFailed
        }
    }

    /// 用固定路径的 `ffmpeg` 启动混音，await 子进程结束（`swift-subprocess`，async-native）。
    /// 可执行文件缺失时 `run` 抛错，映射为「未安装」；启动成功但非 0 退出映射为混音失败。
    private static func run(_ args: [String]) async throws(RecorderError) {
        let status: TerminationStatus
        do {
            status = try await Subprocess.run(
                .path(FilePath(ffmpegPath)),
                arguments: Arguments(args),
                output: .discarded,
                error: .discarded
            ).terminationStatus
        } catch {
            throw .mergeToolUnavailable
        }
        guard status.isSuccess else { throw .audioMergeFailed }
    }
}
