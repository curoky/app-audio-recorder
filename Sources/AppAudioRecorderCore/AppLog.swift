import Logging

/// CLI 与 GUI 共用的 logger 命名。
public enum AppLog {
    /// 所有 Logger 的公共前缀 label，便于在结构化输出里识别来源。
    public static let subsystem = "app-audio-recorder"

    /// 以给定模块名派生一个子 logger（label 形如 `app-audio-recorder.record`）。
    public static func logger(_ module: String) -> Logger {
        Logger(label: "\(subsystem).\(module)")
    }
}
