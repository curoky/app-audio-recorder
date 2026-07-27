import ArgumentParser
import Foundation

/// 顶层命令，聚合子命令。
@main
struct AppAudioRecorder: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app-audio-recorder",
        abstract: "对 macOS 上指定 app 的音频进行录音（基于 ScreenCaptureKit）。",
        discussion: """
        需要「屏幕录制」权限：系统设置 → 隐私与安全性 → 屏幕录制。
        首次运行会触发系统授权弹窗；授权后重新运行即可。

        示例：
          app-audio-recorder list                 # 列出可录音的 app
          app-audio-recorder record               # 默认录制微信
          app-audio-recorder record --app WeChat  # 按名称/ bundleId 录制

        录麦克风时会把 app 与 mic 写入单个多轨容器（.m4a）；离线混音见 `task merge`（用 ffmpeg 直接合并容器内两条轨）。
        """,
        version: "0.1.0",
        subcommands: [ListCommand.self, RecordCommand.self],
        defaultSubcommand: RecordCommand.self
    )
}
