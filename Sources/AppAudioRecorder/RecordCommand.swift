import ArgumentParser
import Foundation

struct RecordCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "录制指定 app 的音频（默认同时录麦克风），默认目标微信。按 Ctrl-C 结束并保存。"
    )

    @Option(name: [.short, .long], help: "目标 app 的名称关键字或 bundleId，默认微信。")
    var app: String = ContentResolver.wechatBundleID

    @Option(name: [.short, .long], help: "输出 WAV 基础路径，默认当前目录下带时间戳的文件。")
    var output: String?

    @Flag(name: .long, inversion: .prefixedNo, help: "是否同时录制麦克风输入（默认开启）。")
    var mic: Bool = true

    @Option(help: "采样率（Hz）。")
    var sampleRate: Int = 48_000

    @Option(help: "声道数（1=单声道，2=立体声）。")
    var channels: Int = 2

    @Option(help: "最长录制秒数；0 表示不限，直到 Ctrl-C。")
    var duration: Int = 0

    func run() async throws {
        let targetApp = try await ContentResolver.findApp(matching: app)
        let filter = try await ContentResolver.filter(for: targetApp)
        let paths = try outputPaths(appName: targetApp.applicationName)

        if mic {
            // 录麦克风前先确保授权，避免录到一半才失败。
            try await MicrophonePermission.ensureAuthorized()
        }

        let engine = AudioCaptureEngine(
            appOutputURL: paths.app,
            micOutputURL: mic ? paths.mic : nil,
            sampleRate: sampleRate,
            channelCount: channels
        )

        print("目标 app : \(targetApp.applicationName) (\(targetApp.bundleIdentifier))")
        if mic {
            print("输出文件 : \(paths.app.path)")
            print("           \(paths.mic!.path)")
        } else {
            print("输出文件 : \(paths.app.path)")
        }
        print("采样率   : \(sampleRate) Hz，\(channels) 声道\(mic ? "，含麦克风" : "")")
        if duration > 0 {
            print("将录制 \(duration) 秒后自动停止（或按 Ctrl-C 提前结束）…")
        } else {
            print("正在录制…按 Ctrl-C 结束并保存。")
        }

        try await engine.start(filter: filter)
        await waitForStop(duration: duration)
        try await engine.stop()

        let seconds = engine.recordedSeconds
        if mic, let micURL = paths.mic {
            print(String(format: "\n已保存（时长约 %.1f 秒）：", seconds))
            print("  app : \(paths.app.path)")
            print("  mic : \(micURL.path)")
            print("如需合并：app-audio-recorder merge \"\(paths.app.path)\" \"\(micURL.path)\"")
        } else {
            print(String(format: "\n已保存：%@（时长约 %.1f 秒）", paths.app.path, seconds))
        }
    }

    /// 等待停止条件：Ctrl-C 或达到时长上限，谁先满足谁结束。
    ///
    /// 用 `TaskGroup` 让两个条件竞速：任一子任务先返回，就取消其余（`InterruptSignal`
    /// 的 `onTermination` 会随之关闭信号源），因此无需手动处理二者的竞争。
    private func waitForStop(duration: Int) async {
        enum StopReason { case interrupt, timeout }

        let reason = await withTaskGroup(of: StopReason.self) { group in
            group.addTask {
                await InterruptSignal.wait()
                return .interrupt
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

        if reason == .interrupt {
            print("\n收到停止信号，正在保存…")
        }
    }

    /// 输出文件的路径。`mic` 仅在录麦克风时使用。
    private struct OutputPaths {
        let app: URL
        let mic: URL?
    }

    /// 从基础路径派生输出路径。
    /// - 录麦克风：`<base>-app.wav` / `<base>-mic.wav` 两路独立文件（合并交给 `merge` 子命令）。
    /// - 不录麦克风：`<base>.wav` 单文件。
    private func outputPaths(appName: String) throws -> OutputPaths {
        let base = baseURL(appName: appName)
        let dir = base.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: dir.path) else {
            throw RecorderError.outputNotWritable(path: base.path)
        }

        guard mic else {
            return OutputPaths(app: base.appendingPathExtension("wav"), mic: nil)
        }
        return OutputPaths(app: suffixed(base, "app"), mic: suffixed(base, "mic"))
    }

    /// 基础路径（不含扩展名）：用户指定则去掉其 `.wav` 扩展名，否则用当前目录带时间戳的名字。
    private func baseURL(appName: String) -> URL {
        if let output {
            let expanded = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
            return expanded.pathExtension.lowercased() == "wav"
                ? expanded.deletingPathExtension()
                : expanded
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let safeName = appName.replacingOccurrences(of: "/", with: "-")
        let name = "\(safeName)-\(formatter.string(from: Date()))"
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(name)
    }

    private func suffixed(_ base: URL, _ suffix: String) -> URL {
        let name = base.lastPathComponent
        return base.deletingLastPathComponent()
            .appendingPathComponent("\(name)-\(suffix)")
            .appendingPathExtension("wav")
    }
}
