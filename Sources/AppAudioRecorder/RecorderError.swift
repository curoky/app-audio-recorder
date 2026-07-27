import Foundation

/// 录音相关的可预期错误。遵从 `LocalizedError`，`errorDescription` 为面向用户的中文提示，
/// 由 ArgumentParser 在命令边界直接打印，无需再包一层退出类型。
enum RecorderError: LocalizedError {
    case screenRecordingPermissionDenied
    case microphonePermissionDenied
    case appNotFound(query: String)
    case noAppsAvailable
    case audioCaptureFailed
    case audioMergeFailed
    case mergeToolUnavailable
    case containerMissingSecondTrack
    case inputNotReadable(path: String)
    case outputNotWritable(path: String)
    case outputConflictsWithInput(path: String)

    var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionDenied:
            """
            未获得「屏幕录制」权限，无法捕获 app 音频。
            请到 系统设置 → 隐私与安全性 → 屏幕录制 中，为运行本工具的终端（或本可执行文件）打开开关，然后重新运行。
            """
        case .microphonePermissionDenied:
            """
            未获得「麦克风」权限，无法录制麦克风输入。
            请到 系统设置 → 隐私与安全性 → 麦克风 中，为运行本工具的终端（或本可执行文件）打开开关，然后重新运行；
            或加 --no-mic 只录制 app 音频。
            """
        case let .appNotFound(query):
            "未找到匹配「\(query)」且正在运行、可捕获音频的 app。可先运行 `list` 查看可用 app。"
        case .noAppsAvailable:
            "当前没有可捕获音频的运行中 app。"
        case .audioCaptureFailed:
            "音频捕获意外停止，已保存停止前成功写入的内容。"
        case .audioMergeFailed:
            "合并 app 音频与麦克风音轨失败。"
        case .mergeToolUnavailable:
            """
            未找到 ffmpeg，无法执行合并。
            本工具固定使用 \(FFmpegMerger.ffmpegPath)，请确认该文件存在且可执行，然后重新运行。
            """
        case .containerMissingSecondTrack:
            """
            容器只有一条音轨，无法混音（merge 需要 app + mic 两条轨）。
            该文件可能是 record --no-mic 产出的单轨容器；只录 app 音频时无需合并。
            """
        case let .inputNotReadable(path):
            "输入文件不存在或不可读：\(path)"
        case let .outputNotWritable(path):
            "输出路径不可写：\(path)"
        case let .outputConflictsWithInput(path):
            "输出路径不能与任一路输入文件相同：\(path)"
        }
    }
}
