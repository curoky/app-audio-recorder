import Foundation

/// 录音相关的可预期错误。遵从 `LocalizedError`，`errorDescription` 为面向用户的中文提示，
/// 可由界面直接展示。
enum RecorderError: LocalizedError, Sendable {
    case screenRecordingPermissionDenied
    case microphonePermissionDenied
    case applicationNotRunning(bundleIdentifier: String)
    case noAppsAvailable
    case audioCaptureFailed
    case outputNotWritable(path: String)
    case operationAlreadyRunning

    var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionDenied:
            """
            未获得「屏幕录制」权限，无法捕获 app 音频。
            请到 系统设置 → 隐私与安全性 → 屏幕录制 中，为 App Audio Recorder 打开开关，然后重新打开 App。
            """
        case .microphonePermissionDenied:
            """
            未获得「麦克风」权限，无法录制麦克风输入。
            请到 系统设置 → 隐私与安全性 → 麦克风 中，为 App Audio Recorder 打开开关；也可以关闭「同时录制麦克风」后重试手动录制。
            """
        case .applicationNotRunning(let bundleIdentifier):
            "所选 app 已退出或当前不可捕获，请刷新列表后重试。（\(bundleIdentifier)）"
        case .noAppsAvailable:
            "当前没有可捕获音频的运行中 app。"
        case .audioCaptureFailed:
            "音频捕获意外停止，已保存停止前成功写入的内容。"
        case .outputNotWritable(let path):
            "输出路径不可写：\(path)"
        case .operationAlreadyRunning:
            "当前操作已在运行。"
        }
    }
}
