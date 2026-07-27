import ArgumentParser
import AsyncAlgorithms
import Foundation
import Logging

/// 常驻监听目标 app 的麦克风活动（默认微信），检测到通话开始时自动录制，通话结束
/// （麦克风静默超过阈值）时自动收尾保存；每段通话产出一个独立的带时间戳 `.m4a` 容器。
/// 按 Ctrl-C 退出监听（若正录制中会先收尾保存当前通话）。
///
/// 触发信号选用「目标 app 正在使用麦克风」（`CallActivityMonitor`）：语音/视频通话必开麦克风，
/// 而单纯放音（背景音乐、系统提示音、点开别人发来的语音消息）只走输出、不会误触发。
struct WatchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watch",
        abstract: "监听目标 app（默认微信）的麦克风活动，通话开始自动录制、结束自动保存。"
    )

    @Option(name: [.short, .long], help: "目标 app 的名称关键字或 bundleId，默认微信。")
    var app: String = ContentResolver.wechatBundleID

    @Option(name: .long, help: "输出目录，每段通话在此生成带时间戳的 .m4a；同名时追加序号。")
    var outputDir: String?

    @Option(help: "采样率（Hz）。")
    var sampleRate: Int = 48_000

    @Option(help: "声道数（1=单声道，2=立体声）。")
    var channels: Int = 2

    @Option(help: "麦克风静默多少秒后判定通话结束（去抖窗口）。")
    var silence: Double = 2.0

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

        // 启动即解析目标 app：拿到稳定 bundleId 供 CoreAudio 按 PID 反查匹配，同时提前触发/校验
        // 「屏幕录制」权限。前提是目标 app 此刻在运行（首个版本仅支持微信这一常驻场景）。
        let targetApp = try await ContentResolver.findApp(matching: app)
        let bundleID = targetApp.bundleIdentifier
        let appName = targetApp.applicationName

        // watch 恒定录制通话（app + 麦克风双轨），先确保麦克风授权，避免录到一半才失败。
        try await MicrophonePermission.ensureAuthorized()

        let dir = try outputDirectory()

        logger.info("开始监听麦克风活动", metadata: [
            "app": .string(appName),
            "bundleId": .string(bundleID),
            "outputDir": .string(dir.path),
            "silence": .stringConvertible(String(format: "%.1f", silence)),
        ])
        logger.info("检测到通话开始将自动录制，结束自动保存；按 Ctrl-C 退出。")

        let monitor = CallActivityMonitor(targetBundleID: bundleID, silenceSeconds: silence, logger: logger)
        monitor.start()
        defer { monitor.stop() }

        await drive(monitor: monitor, appName: appName, bundleID: bundleID, dir: dir, logger: logger)
        logger.info("已退出监听。")
    }

    /// 事件驱动主循环：把「通话活动」「Ctrl-C」「录制失败」三路 `AsyncSequence` 用
    /// `merge` 汇成一条流串行消费，从而在同一任务里安全地持有/切换当前录制引擎，
    /// 无需跨任务共享可变状态。
    ///
    /// 三路来源：`monitor.activityEvents()`（map 成开始/结束）、Ctrl-C（一次性）、
    /// 录制失败——失败与「当前引擎」绑定、随每段录制动态出现，故用 `AsyncChannel` 承载，
    /// 由录制任务在捕获意外停止时投递。
    private func drive(
        monitor: CallActivityMonitor,
        appName: String,
        bundleID: String,
        dir: URL,
        logger: Logger
    ) async {
        enum DriverEvent: Sendable { case callStart, callStop, interrupt, failure }

        let activity = monitor.activityEvents().map { $0 ? DriverEvent.callStart : .callStop }
        let interrupt = AsyncStream<DriverEvent> { continuation in
            let task = Task {
                await InterruptSignal.wait()
                continuation.yield(.interrupt)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        let failures = AsyncChannel<DriverEvent>()

        var active: (engine: AudioCaptureEngine, url: URL)?
        var failureForwarder: Task<Void, Never>?
        func stopForwarder() {
            failureForwarder?.cancel()
            failureForwarder = nil
        }

        loop: for await event in merge(activity, interrupt, failures) {
            switch event {
            case .callStart:
                guard active == nil else { break }
                guard let started = await startRecording(bundleID: bundleID, appName: appName, dir: dir, logger: logger)
                else { break }
                active = started
                // 录制中若捕获意外停止，投递一次 .failure 到 channel，交由主循环收尾。
                let engine = started.engine
                failureForwarder = Task {
                    await engine.waitForFailure()
                    if !Task.isCancelled { await failures.send(.failure) }
                }

            case .callStop, .failure:
                stopForwarder()
                if let current = active {
                    await finishRecording(current.engine, url: current.url, logger: logger)
                    active = nil
                }

            case .interrupt:
                logger.info("收到停止信号，正在退出监听…")
                stopForwarder()
                if let current = active {
                    logger.info("正在收尾当前通话录制…")
                    await finishRecording(current.engine, url: current.url, logger: logger)
                    active = nil
                }
                break loop
            }
        }
        stopForwarder()
    }

    /// 为一段通话启动录制：实时解析目标 app 过滤器并派生带时间戳的输出文件，随后启动引擎。
    /// 失败（app 已退出、启动异常等）返回 `nil`，由调用方跳过并继续监听。
    private func startRecording(
        bundleID: String,
        appName: String,
        dir: URL,
        logger: Logger
    ) async -> (engine: AudioCaptureEngine, url: URL)? {
        do {
            let targetApp = try await ContentResolver.findApp(matching: bundleID)
            let filter = try await ContentResolver.filter(for: targetApp)
            let stem = "\(sanitize(appName))-\(timestamp())"
            let url = URL.uniqueFile(in: dir, stem: stem, pathExtension: "m4a")

            let engine = AudioCaptureEngine(
                outputURL: url,
                capturesMicrophone: true,
                sampleRate: sampleRate,
                channelCount: channels,
                overwritesExistingOutput: false,
                logger: logger
            )
            try await engine.start(filter: filter)
            logger.info("通话开始，正在录制", metadata: ["output": .string(url.path)])
            return (engine, url)
        } catch {
            logger.error("启动录制失败，跳过本次通话", metadata: [
                "error": .string(String(describing: error)),
            ])
            return nil
        }
    }

    /// 收尾并保存一段通话录制；把产物路径打到 stdout 供脚本/管道消费。
    private func finishRecording(_ engine: AudioCaptureEngine, url: URL, logger: Logger) async {
        do {
            try await engine.stop()
        } catch {
            logger.warning("收尾录制时报错，已尽力保存", metadata: ["error": .string(String(describing: error))])
        }
        let seconds = engine.recordedSeconds
        logger.info("通话结束，已保存", metadata: [
            "output": .string(url.path),
            "seconds": .stringConvertible(String(format: "%.1f", seconds)),
        ])
        print(url.path)
    }

    /// 解析并校验输出目录（默认当前目录），支持 `~` 展开。
    func outputDirectory(fileManager: FileManager = .default) throws -> URL {
        let dir = outputDir.map { URL(expandingPath: $0) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: dir.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fileManager.isWritableFile(atPath: dir.path)
        else {
            throw RecorderError.outputNotWritable(path: dir.path)
        }
        return dir
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }

    private func sanitize(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-")
    }
}
