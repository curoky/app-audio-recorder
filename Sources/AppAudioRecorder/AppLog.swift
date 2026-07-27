import ArgumentParser
import Foundation
import Logging

/// 全局日志接线。
///
/// 诊断/状态/进度/警告一律走 `swift-log` 的 `Logger`（输出到 **stderr**，带级别、时间戳与
/// 模块 label），把 **stdout 留给可被管道消费的数据**（`list` 的 app 列表、`record` 的产物提示）。
/// 这样 `app-audio-recorder list | grep ...` 不会被状态噪音污染。
///
/// `LoggingSystem.bootstrap` 进程内只能调用一次，因此由子命令在 `run()` 起点调用
/// `LoggingOptions.bootstrap()`；内部用一次性守卫保证幂等（重复调用无副作用），便于测试。
enum AppLog {
    /// 所有 Logger 的公共前缀 label，便于在结构化输出里识别来源。
    static let subsystem = "app-audio-recorder"

    /// 以给定模块名派生一个子 logger（label 形如 `app-audio-recorder.record`）。
    static func logger(_ module: String) -> Logger {
        Logger(label: "\(subsystem).\(module)")
    }
}

/// `--verbose` / `--quiet` 全局选项，供各子命令用 `@OptionGroup` 复用。
///
/// 用 `Sendable` 值类型承载配置并显式接线日志级别，不建全局可变单例（契合并发规则）。
struct LoggingOptions: ParsableArguments {
    @Flag(name: [.short, .long], help: "输出更详细的诊断日志（debug 级别）。")
    var verbose: Bool = false

    @Flag(name: [.short, .long], help: "只输出错误，静默进度与状态日志。")
    var quiet: Bool = false

    /// 根据 flag 解析出的日志级别：`--quiet` 只留 error，`--verbose` 放开到 debug，否则 info。
    var logLevel: Logger.Level {
        if quiet { return .error }
        if verbose { return .debug }
        return .info
    }

    /// 用当前级别 bootstrap 全局日志系统（进程内幂等；重复调用只认第一次）。
    func bootstrap() {
        LoggingBootstrap.once(level: logLevel)
    }
}

/// `LoggingSystem.bootstrap` 的一次性守卫。`bootstrap` 全局仅可调用一次，
/// 多次调用会 `fatalError`；这里用串行队列 + flag 保证幂等。
private enum LoggingBootstrap {
    nonisolated(unsafe) private static var didBootstrap = false
    private static let lock = NSLock()

    static func once(level: Logger.Level) {
        lock.lock()
        defer { lock.unlock() }
        guard !didBootstrap else { return }
        didBootstrap = true
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = level
            return handler
        }
    }
}
