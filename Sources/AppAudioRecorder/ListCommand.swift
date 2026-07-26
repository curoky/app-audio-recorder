import ArgumentParser
import Foundation

struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "列出当前可捕获音频的运行中 app。"
    )

    func run() async throws {
        do {
            let apps = try await ContentResolver.runningApps()
            guard !apps.isEmpty else {
                print("没有可捕获音频的运行中 app。")
                return
            }
            print("可录音的 app（共 \(apps.count) 个）：")
            print(String(repeating: "-", count: 60))
            for app in apps {
                let marker = app.bundleIdentifier == ContentResolver.wechatBundleID ? " ← 微信" : ""
                print("  \(app.applicationName)\(marker)")
                print("      bundleId: \(app.bundleIdentifier)   pid: \(app.processID)")
            }
        } catch let error as RecorderError {
            throw ExitWithMessage(error.description)
        }
    }
}
