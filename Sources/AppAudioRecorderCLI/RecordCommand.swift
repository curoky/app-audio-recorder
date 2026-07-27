import AppAudioRecorderCore
import ArgumentParser
import Foundation
import Logging

struct RecordCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "录制指定 app 的音频（默认同时录麦克风），默认目标微信。按 Ctrl-C 结束并保存。"
    )

    @Option(name: [.short, .long], help: "目标 app 的名称关键字或 bundleId，默认微信。")
    var app: String = Recorder.defaultBundleIdentifier

    @Option(name: [.short, .long], help: "输出容器基础路径，默认当前目录下带时间戳的文件（产出 .m4a）。")
    var output: String?

    @Flag(name: .long, inversion: .prefixedNo, help: "是否同时录制麦克风输入（默认开启）。")
    var mic: Bool = true

    @Option(help: "采样率（Hz）。")
    var sampleRate: Int = 48_000

    @Option(help: "声道数（1=单声道，2=立体声）。")
    var channels: Int = 2

    @Option(help: "最长录制秒数；0 表示不限，直到 Ctrl-C。")
    var duration: Int = 0

    @OptionGroup var logging: LoggingOptions

    func validate() throws {
        guard !app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("--app 不能为空。")
        }
        guard AudioFormatConstraints.sampleRates.contains(sampleRate) else {
            throw ValidationError("--sample-rate 必须在 8000...48000 Hz 范围内（当前 \(sampleRate)）。")
        }
        guard AudioFormatConstraints.channelCounts.contains(channels) else {
            throw ValidationError("--channels 只能是 1 或 2（当前 \(channels)）。")
        }
        guard duration >= 0 else {
            throw ValidationError("--duration 不能为负数（当前 \(duration)）。")
        }
    }

    func run() async throws {
        logging.bootstrap()
        let logger = AppLog.logger("record")

        let targetApp = try await Recorder.application(matching: app)
        let outputURL = try containerURL(appName: targetApp.name)
        logger.info("准备录制", metadata: [
            "app": .string(targetApp.name),
            "bundleId": .string(targetApp.bundleIdentifier),
            "output": .string(outputURL.path),
            "sampleRate": .stringConvertible(sampleRate),
            "channels": .stringConvertible(channels),
            "mic": .stringConvertible(mic),
        ])
        let session = try await Recorder.startRecording(
            application: targetApp,
            outputURL: outputURL,
            capturesMicrophone: mic,
            sampleRate: sampleRate,
            channelCount: channels,
            logger: logger
        )
        if duration > 0 {
            logger.info("将录制 \(duration) 秒后自动停止（或按 Ctrl-C 提前结束）…")
        } else {
            logger.info("正在录制…按 Ctrl-C 结束并保存。")
        }

        await waitForStop(duration: duration, session: session, logger: logger)
        let result = await session.stop()

        logger.info("录制结束", metadata: [
            "seconds": .stringConvertible(String(format: "%.1f", result.recordedSeconds)),
        ])
        if mic {
            logger.debug("容器含 app / mic 两条 ALAC 轨，起始偏移已按首帧 PTS 对齐。")
        }
        if let warning = result.warning {
            logger.error("录制收尾失败", metadata: ["error": .string(warning)])
            throw RecorderError.audioCaptureFailed
        }
        // 产物路径是可被管道/脚本消费的结果，走 stdout。
        print(result.outputURL.path)
    }

    /// 等待停止条件：Ctrl-C 或达到时长上限，谁先满足谁结束。
    ///
    /// 用 `TaskGroup` 让三个条件竞速：任一子任务先返回，就取消其余（`InterruptSignal`
    /// 的 `onTermination` 会随之关闭信号源），因此无需手动处理二者的竞争。
    private func waitForStop(duration: Int, session: RecordingSession, logger: Logger) async {
        enum StopReason { case interrupt, timeout, failure }

        let reason = await withTaskGroup(of: StopReason.self) { group in
            group.addTask {
                await InterruptSignal.wait()
                return .interrupt
            }
            group.addTask {
                await session.waitForFailure()
                return .failure
            }
            if duration > 0 {
                group.addTask {
                    try? await Task.sleep(for: .seconds(duration))
                    return .timeout
                }
            }
            let first = await group.next() ?? .interrupt
            group.cancelAll()
            return first
        }

        switch reason {
        case .interrupt:
            logger.info("收到停止信号，正在保存…")
        case .failure:
            logger.warning("捕获意外停止，正在保存已录内容…")
        case .timeout:
            logger.info("到达时长上限，正在保存…")
        }
    }

    /// 从基础路径派生输出容器路径（单个 `.m4a` 多轨容器）。
    private func containerURL(appName: String) throws -> URL {
        let base = baseURL(appName: appName)
        let dir = base.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: dir.path) else {
            throw RecorderError.outputNotWritable(path: base.path)
        }
        return base.appendingPathExtension("m4a")
    }

    /// 基础路径（不含扩展名）：用户指定则去掉其 `.m4a`/`.wav` 扩展名，否则用当前目录带时间戳的名字。
    private func baseURL(appName: String) -> URL {
        if let output {
            let expanded = URL(expandingPath: output)
            let ext = expanded.pathExtension.lowercased()
            return (ext == "m4a" || ext == "wav")
                ? expanded.deletingPathExtension()
                : expanded
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let safeName = appName.replacingOccurrences(of: "/", with: "-")
        let name = "\(safeName)-\(formatter.string(from: Date()))"
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(name)
    }
}
