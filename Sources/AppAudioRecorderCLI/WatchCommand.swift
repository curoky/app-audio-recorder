import AppAudioRecorderCore
import ArgumentParser
import Foundation
import Logging

struct WatchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watch",
        abstract: "监听目标 app（默认微信）的麦克风活动，通话开始自动录制、结束自动保存。"
    )

    @Option(name: [.short, .long], help: "目标 app 的名称关键字或 bundleId，默认微信。")
    var app: String = Recorder.defaultBundleIdentifier

    @Option(name: .long, help: "输出目录，每段通话在此生成带时间戳的 .m4a；同名时追加序号。")
    var outputDir: String?

    @Option(help: "采样率（Hz）。")
    var sampleRate = 48_000

    @Option(help: "声道数（1=单声道，2=立体声）。")
    var channels = 2

    @Option(help: "麦克风静默多少秒后判定通话结束（去抖窗口）。")
    var silence = 2.0

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
        guard silence.isFinite, silence >= 0 else {
            throw ValidationError("--silence 必须是有限的非负数（当前 \(silence)）。")
        }
    }

    func run() async throws {
        logging.bootstrap()
        let logger = AppLog.logger("watch")
        let application = try await Recorder.application(matching: app)
        let directory = try outputDirectory()
        let watcher = CallRecordingWatcher(
            application: application,
            outputDirectory: directory,
            sampleRate: sampleRate,
            channelCount: channels,
            silenceSeconds: silence,
            logger: logger
        )

        logger.info("开始监听麦克风活动", metadata: [
            "app": .string(application.name),
            "bundleId": .string(application.bundleIdentifier),
            "outputDir": .string(directory.path),
            "silence": .stringConvertible(String(format: "%.1f", silence)),
        ])
        logger.info("检测到通话开始将自动录制，结束自动保存；按 Ctrl-C 退出。")

        let events = try await watcher.start()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await event in events {
                    Self.report(event, logger: logger)
                }
            }
            group.addTask {
                await InterruptSignal.wait()
            }

            await group.next()
            logger.info("收到停止信号，正在退出监听…")
            if let result = await watcher.stop() {
                Self.report(result, logger: logger)
            }
            group.cancelAll()
        }
        logger.info("已退出监听。")
    }

    func outputDirectory(fileManager: FileManager = .default) throws -> URL {
        let directory = outputDir.map { URL(expandingPath: $0) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        try RecordingFiles.validateOutputDirectory(directory, fileManager: fileManager)
        return directory
    }

    private static func report(_ event: CallRecordingEvent, logger: Logger) {
        switch event {
        case let .started(outputURL):
            logger.info("通话开始，正在录制", metadata: ["output": .string(outputURL.path)])
        case let .finished(result):
            report(result, logger: logger)
        case let .failed(message):
            logger.error("启动录制失败，继续监听", metadata: ["error": .string(message)])
        }
    }

    private static func report(_ result: RecordingResult, logger: Logger) {
        if let warning = result.warning {
            logger.warning("收尾录制时报错，已尽力保存", metadata: ["error": .string(warning)])
        }
        logger.info("通话结束，已保存", metadata: [
            "output": .string(result.outputURL.path),
            "seconds": .stringConvertible(String(format: "%.1f", result.recordedSeconds)),
        ])
        print(result.outputURL.path)
    }
}
