import Foundation

/// 录音相关的可预期错误，统一在边界处转成友好的退出信息。
enum RecorderError: Error, CustomStringConvertible {
    case screenRecordingPermissionDenied
    case appNotFound(query: String)
    case noAppsAvailable
    case audioConversionFailed
    case outputNotWritable(path: String)

    var description: String {
        switch self {
        case .screenRecordingPermissionDenied:
            return """
            未获得「屏幕录制」权限，无法捕获 app 音频。
            请到 系统设置 → 隐私与安全性 → 屏幕录制 中，为运行本工具的终端（或本可执行文件）打开开关，然后重新运行。
            """
        case let .appNotFound(query):
            return "未找到匹配「\(query)」且正在运行、可捕获音频的 app。可先运行 `list` 查看可用 app。"
        case .noAppsAvailable:
            return "当前没有可捕获音频的运行中 app。"
        case .audioConversionFailed:
            return "音频格式转换失败。"
        case let .outputNotWritable(path):
            return "输出路径不可写：\(path)"
        }
    }
}
