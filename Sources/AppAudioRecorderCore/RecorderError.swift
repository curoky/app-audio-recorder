import Foundation

/// 录音相关的可预期错误。遵从 `LocalizedError`，`errorDescription` 为面向用户的中文提示，
/// CLI 可直接打印，GUI 可直接展示。
public enum RecorderError: LocalizedError, Sendable {
    case screenRecordingPermissionDenied
    case microphonePermissionDenied
    case appNotFound(query: String)
    case noAppsAvailable
    case audioCaptureFailed
    case outputNotWritable(path: String)
    case invalidConfiguration

    public var errorDescription: String? {
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
        case let .outputNotWritable(path):
            "输出路径不可写：\(path)"
        case .invalidConfiguration:
            "录制配置无效。"
        }
    }
}
