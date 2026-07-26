import ArgumentParser
import Foundation

struct MergeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "merge",
        abstract: "把两路 WAV（如 record 产出的 app 与 mic）离线混音成一个文件。"
    )

    @Argument(help: "第一路输入 WAV 路径（如 app 音频）。")
    var appInput: String

    @Argument(help: "第二路输入 WAV 路径（如麦克风）。")
    var micInput: String

    @Option(name: [.short, .long], help: "输出 WAV 路径，默认在第一路同目录生成 <名>-merged.wav。")
    var output: String?

    @Option(help: "混音增益：两路相加前统一乘的系数。0.5 保证不削波，0.707≈-3dB 折中，1.0 等量叠加。")
    var gain: Float = 0.707

    func validate() throws {
        guard gain > 0 else {
            throw ValidationError("--gain 必须大于 0（当前 \(gain)）。")
        }
    }

    func run() async throws {
        let appURL = expand(appInput)
        let micURL = expand(micInput)
        for url in [appURL, micURL] where !FileManager.default.isReadableFile(atPath: url.path) {
            throw RecorderError.inputNotReadable(path: url.path)
        }

        let outputURL = resolveOutputURL(appURL: appURL)
        guard FileManager.default.isWritableFile(atPath: outputURL.deletingLastPathComponent().path) else {
            throw RecorderError.outputNotWritable(path: outputURL.path)
        }

        print("混音输入 : \(appURL.path)")
        print("           \(micURL.path)")
        print("输出文件 : \(outputURL.path)")
        print("混音增益 : \(gain)")
        print("正在合并音轨…")
        try await mergeTracks(appURL: appURL, micURL: micURL, mergedURL: outputURL)
        print("已保存：\(outputURL.path)")
    }

    /// 离线合并是 CPU 密集的纯计算，放到并发线程池，不占用协作线程池。
    @concurrent
    private func mergeTracks(appURL: URL, micURL: URL, mergedURL: URL) async throws {
        try AudioMerger.merge(appURL: appURL, micURL: micURL, outputURL: mergedURL, gain: gain)
    }

    private func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// 输出路径：用户指定则用之，否则在第一路输入同目录生成 `<去掉-app 后缀的基名>-merged.wav`。
    private func resolveOutputURL(appURL: URL) -> URL {
        if let output {
            return expand(output)
        }
        // record 产出的 app 文件名形如 `<base>-app.wav`，去掉 `-app` 得到干净基名。
        let stem = appURL.deletingPathExtension().lastPathComponent
        let base = stem.hasSuffix("-app") ? String(stem.dropLast(4)) : stem
        return appURL.deletingLastPathComponent()
            .appendingPathComponent("\(base)-merged")
            .appendingPathExtension("wav")
    }
}
