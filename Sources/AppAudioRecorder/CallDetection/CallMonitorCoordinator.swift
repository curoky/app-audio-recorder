import Foundation
import Observation

/// 通话检测附加功能的编排器：拥有监听选择、`CallActivityMonitor` 生命周期、去抖后的
/// 提醒排队与逐个提醒逻辑。与核心录制通过两个注入闭包解耦：
/// - `isRecordingBusy`：录制/收尾进行时不弹提醒，也不覆盖状态行；
/// - `updateStatus`：把监听状态行写回共享的界面状态。
///
/// 该类型只产生「疑似通话」提醒，从不创建或停止录制 writer；是否录制由 `RecorderModel` 决定。
@MainActor
@Observable
final class CallMonitorCoordinator {
    private(set) var isMonitoring = false
    private(set) var reminderMessage: String?
    /// 触发当前提醒的 App；`RecorderModel` 据此在用户确认后开始录制。
    private(set) var reminderApplication: CapturableApplication?
    private(set) var monitoredBundleIdentifiers: Set<String>

    /// 录制/收尾是否进行中；由所有者在活动状态变化后保持最新。
    var isRecordingBusy: @MainActor () -> Bool = { false }
    /// 把监听相关的状态行写回界面。仅在非录制忙碌时调用。
    var updateStatus: @MainActor (String) -> Void = { _ in }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let notifyCallDetected: @MainActor () -> Void
    @ObservationIgnored private var monitor: CallActivityMonitor?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    private var monitoredApplicationsByBundleIdentifier: [String: CapturableApplication] = [:]
    private var activeCallBundleIdentifiers: Set<String> = []
    private var pendingCallBundleIdentifiers: [String] = []

    private static let monitoredBundleIdentifiersKey = "monitoredBundleIdentifiers"

    init(
        defaults: UserDefaults,
        notifyCallDetected: @escaping @MainActor () -> Void
    ) {
        self.defaults = defaults
        self.notifyCallDetected = notifyCallDetected
        monitoredBundleIdentifiers = Set(
            defaults.stringArray(forKey: Self.monitoredBundleIdentifiersKey) ?? []
        )
    }

    var monitoringStatusText: String {
        "正在监听 \(monitoredApplicationsByBundleIdentifier.count) 个 app 的通话活动"
    }

    /// 切换监听目标；同一已适配 App 家族只保留一个进程。监听进行中禁止修改。
    func toggleMonitored(bundleIdentifier: String) {
        guard !isMonitoring else { return }
        if monitoredBundleIdentifiers.remove(bundleIdentifier) == nil {
            let rootBundleIdentifier = ApplicationBundleMatcher(
                targetBundleIdentifier: bundleIdentifier
            ).rootBundleIdentifier
            monitoredBundleIdentifiers = Set(
                monitoredBundleIdentifiers.filter {
                    ApplicationBundleMatcher(
                        targetBundleIdentifier: $0
                    ).rootBundleIdentifier != rootBundleIdentifier
                }
            )
            monitoredBundleIdentifiers.insert(bundleIdentifier)
        }
        persistMonitoredBundleIdentifiers()
    }

    /// 把持久化的监听目标对齐到当前运行进程（helper 归并到主 app）。
    func reconcile(with loadedApplications: [CapturableApplication]) {
        let reconciled = Set(
            monitoredBundleIdentifiers.map { bundleIdentifier in
                let matcher = ApplicationBundleMatcher(
                    targetBundleIdentifier: bundleIdentifier
                )
                return loadedApplications.first {
                    matcher.belongsToSameFamily(as: $0.bundleIdentifier)
                }?.bundleIdentifier ?? bundleIdentifier
            }
        )
        guard reconciled != monitoredBundleIdentifiers else { return }
        monitoredBundleIdentifiers = reconciled
        persistMonitoredBundleIdentifiers()
    }

    func setEnabled(
        _ enabled: Bool,
        monitoredApplications: [CapturableApplication]
    ) {
        if enabled {
            start(monitoredApplications: monitoredApplications)
        } else {
            _ = stopMonitoring()
        }
    }

    /// 停止监听并等待事件流收尾（幂等）。供所有者在退出流程中调用。
    func shutdown() async {
        await stopMonitoring()?.value
    }

    func handleActivity(_ event: CallActivityEvent) {
        guard isMonitoring,
            monitoredApplicationsByBundleIdentifier[event.bundleIdentifier] != nil
        else { return }

        if event.isActive {
            guard activeCallBundleIdentifiers.insert(
                event.bundleIdentifier
            ).inserted else { return }
            pendingCallBundleIdentifiers.append(event.bundleIdentifier)
            presentNextReminderIfPossible()
            return
        }

        activeCallBundleIdentifiers.remove(event.bundleIdentifier)
        pendingCallBundleIdentifiers.removeAll {
            $0 == event.bundleIdentifier
        }
        if reminderApplication?.bundleIdentifier == event.bundleIdentifier {
            clearReminder()
            presentNextReminderIfPossible()
        } else if !isRecordingBusy(), reminderApplication == nil {
            updateStatus(monitoringStatusText)
        }
    }

    func dismissReminder() async {
        clearReminder()
        await Task.yield()
        presentNextReminderIfPossible()
    }

    /// 若当前空闲且有待处理通话，弹出下一个提醒。录制/收尾进行时不打扰。
    func presentNextReminderIfPossible() {
        guard isMonitoring, !isRecordingBusy(),
            reminderApplication == nil
        else { return }

        while !pendingCallBundleIdentifiers.isEmpty {
            let bundleIdentifier = pendingCallBundleIdentifiers.removeFirst()
            guard activeCallBundleIdentifiers.contains(bundleIdentifier),
                let application =
                    monitoredApplicationsByBundleIdentifier[bundleIdentifier]
            else { continue }

            reminderApplication = application
            reminderMessage =
                "检测到 \(application.name) 同时使用音频输入与输出，是否开始录制？"
            updateStatus("检测到 \(application.name) 疑似通话，等待手动录制")
            notifyCallDetected()
            return
        }

        updateStatus(monitoringStatusText)
    }

    func clearReminder() {
        reminderApplication = nil
        reminderMessage = nil
    }

    private func start(monitoredApplications: [CapturableApplication]) {
        guard monitor == nil, !monitoredApplications.isEmpty else { return }

        let monitor = CallActivityMonitor(
            targetBundleIdentifiers: Set(
                monitoredApplications.map(\.bundleIdentifier)
            )
        )
        self.monitor = monitor
        monitoredApplicationsByBundleIdentifier = Dictionary(
            uniqueKeysWithValues: monitoredApplications.map {
                ($0.bundleIdentifier, $0)
            }
        )
        activeCallBundleIdentifiers.removeAll()
        pendingCallBundleIdentifiers.removeAll()
        clearReminder()
        isMonitoring = true
        if !isRecordingBusy() {
            updateStatus(monitoringStatusText)
        }

        monitor.start()
        monitorTask = Task { [weak self, monitor] in
            for await event in monitor.activityEvents() {
                guard !Task.isCancelled else { break }
                self?.handleActivity(event)
            }
        }
    }

    @discardableResult
    private func stopMonitoring() -> Task<Void, Never>? {
        guard let monitor else { return nil }
        self.monitor = nil
        let task = monitorTask
        monitorTask = nil
        task?.cancel()
        monitor.stop()

        isMonitoring = false
        monitoredApplicationsByBundleIdentifier.removeAll()
        activeCallBundleIdentifiers.removeAll()
        pendingCallBundleIdentifiers.removeAll()
        clearReminder()
        if !isRecordingBusy() {
            updateStatus("通话提醒已关闭")
        }
        return task
    }

    private func persistMonitoredBundleIdentifiers() {
        defaults.set(
            monitoredBundleIdentifiers.sorted(),
            forKey: Self.monitoredBundleIdentifiersKey
        )
    }
}
