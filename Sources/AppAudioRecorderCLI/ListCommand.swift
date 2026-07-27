import AppAudioRecorderCore
import ArgumentParser

struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "列出当前可捕获音频的运行中 app。"
    )

    @OptionGroup var logging: LoggingOptions

    func run() async throws {
        logging.bootstrap()
        let logger = AppLog.logger("list")

        let apps = try await Recorder.applications()
        guard !apps.isEmpty else {
            logger.warning("没有可捕获音频的运行中 app。")
            return
        }
        logger.info("找到可录音的 app", metadata: ["count": .stringConvertible(apps.count)])

        // app 列表是可被管道消费的数据，走 stdout；上面的状态提示走 logger（stderr）。
        print(String(repeating: "-", count: 60))
        for app in apps {
            let marker = app.bundleIdentifier == Recorder.defaultBundleIdentifier ? " ← 微信" : ""
            print("  \(app.name)\(marker)")
            print("      bundleId: \(app.bundleIdentifier)   pid: \(app.processID)")
        }
    }
}
