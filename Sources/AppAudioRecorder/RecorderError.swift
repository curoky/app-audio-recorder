import Foundation

/// 录音相关的可预期错误。遵从 `LocalizedError`，`errorDescription` 为面向用户的中文提示，
/// 可由界面直接展示。
enum RecorderError: LocalizedError, Sendable {
    case screenRecordingPermissionDenied
    case microphonePermissionDenied
    case applicationNotRunning(bundleIdentifier: String)
    case noAppsAvailable
    case audioCaptureFailed
    case insufficientDiskSpace(availableBytes: Int64)
    case outputNotWritable(path: String)

    var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionDenied:
            return """
            未获得「屏幕录制」权限，无法捕获 app 音频。
            请到 系统设置 → 隐私与安全性 → 屏幕录制 中，为 App Audio Recorder 打开开关，然后重新打开 App。
            """
        case .microphonePermissionDenied:
            return """
            未获得「麦克风」权限，无法录制麦克风输入。
            请到 系统设置 → 隐私与安全性 → 麦克风 中，为 App Audio Recorder 打开开关；也可以关闭「同时录制麦克风」后重试手动录制。
            """
        case .applicationNotRunning(let bundleIdentifier):
            return "所选 app 已退出或当前不可捕获，请刷新列表后重试。（\(bundleIdentifier)）"
        case .noAppsAvailable:
            return "当前没有可捕获音频的运行中 app。"
        case .audioCaptureFailed:
            return "音频捕获意外停止。"
        case .insufficientDiskSpace(let availableBytes):
            let megabytes = max(0, availableBytes) / 1_000_000
            return "磁盘可用空间不足（剩余 \(megabytes) MB），无法继续录制。"
        case .outputNotWritable(let path):
            return "输出路径不可写：\(path)"
        }
    }
}
