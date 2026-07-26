import ArgumentParser
import Foundation

struct RecordCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "录制指定 app 的音频，默认录制微信。按 Ctrl-C 结束并保存。"
    )

    @Option(name: [.short, .long], help: "目标 app 的名称关键字或 bundleId，默认微信。")
    var app: String = ContentResolver.wechatBundleID

    @Option(name: [.short, .long], help: "输出 WAV 文件路径，默认当前目录下带时间戳的文件。")
    var output: String?

    @Option(help: "采样率（Hz）。")
    var sampleRate: Int = 48_000

    @Option(help: "声道数（1=单声道，2=立体声）。")
    var channels: Int = 2

    @Option(help: "最长录制秒数；0 表示不限，直到 Ctrl-C。")
    var duration: Int = 0

    func run() async throws {
        do {
            try await record()
        } catch let error as RecorderError {
            throw ExitWithMessage(error.description)
        }
    }

    private func record() async throws {
        let targetApp = try await ContentResolver.findApp(matching: app)
        let filter = try await ContentResolver.filter(for: targetApp)
        let outputURL = try resolveOutputURL(appName: targetApp.applicationName)

        let engine = AudioCaptureEngine(
            outputURL: outputURL,
            sampleRate: sampleRate,
            channelCount: channels
        )

        print("目标 app : \(targetApp.applicationName) (\(targetApp.bundleIdentifier))")
        print("输出文件 : \(outputURL.path)")
        print("采样率   : \(sampleRate) Hz，\(channels) 声道")
        if duration > 0 {
            print("将录制 \(duration) 秒后自动停止（或按 Ctrl-C 提前结束）…")
        } else {
            print("正在录制…按 Ctrl-C 结束并保存。")
        }

        try await engine.start(filter: filter)
        await waitForStop(duration: duration)

        try await engine.stop()
        let seconds = engine.recordedSeconds
        print(String(format: "\n已保存：%@（时长约 %.1f 秒）", outputURL.path, seconds))
    }

    /// 等待停止条件：Ctrl-C 或达到时长上限。
    private func waitForStop(duration: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeState = ResumeGuard()

            // 处理 SIGINT（Ctrl-C）。先忽略默认行为，再挂 dispatch source。
            signal(SIGINT, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            source.setEventHandler {
                if resumeState.tryResume() {
                    print("\n收到停止信号，正在保存…")
                    continuation.resume()
                }
            }
            source.resume()

            if duration > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(duration)) {
                    if resumeState.tryResume() {
                        source.cancel()
                        continuation.resume()
                    }
                }
            }
        }
    }

    private func resolveOutputURL(appName: String) throws -> URL {
        let url: URL
        if let output {
            url = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let safeName = appName.replacingOccurrences(of: "/", with: "-")
            let name = "\(safeName)-\(formatter.string(from: Date())).wav"
            url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(name)
        }
        let dir = url.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: dir.path) else {
            throw RecorderError.outputNotWritable(path: url.path)
        }
        return url
    }
}

/// 保证 continuation 只被 resume 一次的小工具（Ctrl-C 与超时可能竞争）。
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func tryResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }
}
