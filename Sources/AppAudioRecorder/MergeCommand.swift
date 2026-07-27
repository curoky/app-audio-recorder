import ArgumentParser
import Foundation

struct MergeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "merge",
        abstract: "把 record 产出的多轨容器（app + mic 两条轨）离线混音成一个 WAV。"
    )

    @Argument(help: "输入多轨容器路径（record 产出的 .m4a，含 app 与 mic 两条音轨）。")
    var container: String

    @Option(name: [.short, .long], help: "输出 WAV 路径，默认在容器同目录生成 <名>-merged.wav。")
    var output: String?

    @Option(help: "混音增益：两路相加前统一乘的系数。0.5 保证不削波，0.707≈-3dB 折中，1.0 等量叠加。")
    var gain: Float = 0.707

    func validate() throws {
        guard gain.isFinite, gain > 0 else {
            throw ValidationError("--gain 必须是大于 0 的有限数值（当前 \(gain)）。")
        }
    }

    func run() async throws {
        let containerURL = URL(expandingPath: container)
        guard FileManager.default.isReadableFile(atPath: containerURL.path) else {
            throw RecorderError.inputNotReadable(path: containerURL.path)
        }

        let outputURL = resolveOutputURL(containerURL: containerURL)
        if outputURL.standardizedFileURL == containerURL.standardizedFileURL {
            throw RecorderError.outputConflictsWithInput(path: outputURL.path)
        }
        guard FileManager.default.isWritableFile(atPath: outputURL.deletingLastPathComponent().path) else {
            throw RecorderError.outputNotWritable(path: outputURL.path)
        }

        print("混音输入 : \(containerURL.path)")
        print("输出文件 : \(outputURL.path)")
        print("混音增益 : \(gain)")
        print("正在合并音轨…")
        try await FFmpegMerger.merge(containerURL: containerURL, outputURL: outputURL, gain: gain)
        print("已保存：\(outputURL.path)")
    }

    /// 输出路径：用户指定则用之，否则在容器同目录生成 `<容器基名>-merged.wav`。
    private func resolveOutputURL(containerURL: URL) -> URL {
        if let output {
            return URL(expandingPath: output)
        }
        let base = containerURL.deletingPathExtension().lastPathComponent
        return containerURL.deletingLastPathComponent()
            .appendingPathComponent("\(base)-merged")
            .appendingPathExtension("wav")
    }
}
