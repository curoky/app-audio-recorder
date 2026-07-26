import Dispatch

/// 把 SIGINT（Ctrl-C）暴露为可 await 的信号，供结构化并发等待停止。
///
/// 用 `AsyncStream` 桥接 `DispatchSource` 信号回调：`onTermination` 在等待任务被取消时
/// 自动关闭信号源，天然满足「只触发一次 + 可取消」，无需手动加锁或 resume 防护。
enum InterruptSignal {
    /// 挂起直到收到一次 SIGINT，或当前任务被取消。
    static func wait() async {
        for await _ in stream() { break }
    }

    private static func stream() -> AsyncStream<Void> {
        AsyncStream { continuation in
            // 忽略默认终止行为，改由 dispatch source 捕获。
            signal(SIGINT, SIG_IGN)
            let queue = DispatchQueue(label: "app-audio-recorder.signal")
            let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
            source.setEventHandler { continuation.yield(()) }
            continuation.onTermination = { _ in source.cancel() }
            source.resume()
        }
    }
}
