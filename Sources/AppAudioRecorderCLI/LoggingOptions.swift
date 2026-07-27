import ArgumentParser
import Foundation
import Logging

/// `--verbose` / `--quiet` 全局选项，供各子命令复用。
struct LoggingOptions: ParsableArguments {
    @Flag(name: [.short, .long], help: "输出更详细的诊断日志（debug 级别）。")
    var verbose = false

    @Flag(name: [.short, .long], help: "只输出错误，静默进度与状态日志。")
    var quiet = false

    private var logLevel: Logger.Level {
        if quiet { return .error }
        if verbose { return .debug }
        return .info
    }

    func bootstrap() {
        LoggingBootstrap.once(level: logLevel)
    }
}

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
