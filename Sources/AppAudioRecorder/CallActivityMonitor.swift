import AppKit
import CoreAudio
import Foundation
import OSLog

/// 监听目标 app 是否正在使用麦克风（语音/视频通话的强特征），把「开始/停止用麦克风」
/// 抽象成一条**去抖后**的 `AsyncStream<Bool>`：`true`=通话开始，`false`=通话结束。
///
/// 依据 CoreAudio 的进程音频对象 API（macOS 14.4+）：每个正在用音频的进程暴露为一个
/// `AudioObjectID`，其 `kAudioProcessPropertyIsRunningInput` 表示该进程此刻是否在采集输入。
/// 通过进程对象的 PID 反查 `NSRunningApplication` 的 bundleId 来匹配目标 app 及其已知 helper
/// （从而无需读取 CoreAudio 的 CFString 属性，也天然跟随目标 app 重启后的新 PID）；同时监听
/// 进程对象**列表**变化，以捕获通话开始时才出现的进程对象。读取这些元数据不需要任何额外权限。
///
/// 并发模型：所有可变状态与 CoreAudio 监听回调都固定在串行队列 `queue` 上访问/触发
/// （`AudioObjectAddPropertyListenerBlock` 注册到该队列）。因此 `@unchecked Sendable` 是桥接
/// 这套回调式 C API 的**有依据**标注，而非规避编译期检查。监听块强引用 `self`，由 `stop()`
/// 显式移除来打破环——`watch` 命令在 `defer` 里保证调用。
final class CallActivityMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app-audio-recorder.call-monitor")
    private let targetBundleMatcher: ApplicationBundleMatcher
    private let endDelay: CallEndDelay
    private let logger = AppLog.logger("call-monitor")

    private let events: AsyncStream<Bool>
    private let continuation: AsyncStream<Bool>.Continuation

    // 以下状态仅在 `queue` 上访问。
    private var inputListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var listListenerBlock: AudioObjectPropertyListenerBlock?
    /// 去抖后对外发出的活动状态（避免抖动导致频繁启停）。
    private var micActive = false
    /// 等待静默确认的停止任务；期间若麦克风又活动则取消。
    private var pendingStop: DispatchWorkItem?

    init(targetBundleID: String, endDelay: CallEndDelay) {
        self.targetBundleMatcher = ApplicationBundleMatcher(
            targetBundleIdentifier: targetBundleID
        )
        self.endDelay = endDelay
        // 布尔事件极小且低频，用 unbounded 保证不丢失任何一次翻转。
        (self.events, self.continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    /// 去抖后的通话活动事件流：`true`=开始用麦克风，`false`=静默超过阈值判定结束。
    func activityEvents() -> AsyncStream<Bool> { events }

    /// 装上监听并做一次初始扫描（若目标 app 已在通话则立即发出 `true`）。
    func start() {
        queue.async { [self] in
            installProcessListListener()
            refreshInputListeners()
            recomputeState()
        }
    }

    /// 移除所有监听并结束事件流（幂等）。
    func stop() {
        queue.async { [self] in
            pendingStop?.cancel()
            pendingStop = nil
            removeProcessListListener()
            for (objectID, block) in inputListeners {
                removeInputListener(objectID, block)
            }
            inputListeners.removeAll()
            continuation.finish()
        }
    }

    // MARK: - 监听装卸（仅在 queue 上调用）

    private func installProcessListListener() {
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        let block: AudioObjectPropertyListenerBlock = { [self] _, _ in
            // 回调已在 `queue` 上：列表变化时重扫进程对象并重算状态。
            refreshInputListeners()
            recomputeState()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, block
        )
        if status == noErr {
            listListenerBlock = block
        } else {
            logger.warning("注册进程列表监听失败：\(status)")
        }
    }

    private func removeProcessListListener() {
        guard let block = listListenerBlock else { return }
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, block
        )
        listListenerBlock = nil
    }

    /// 对当前匹配到的进程对象增删 `IsRunningInput` 监听，使其与进程列表保持一致。
    private func refreshInputListeners() {
        let matched = Set(matchedProcessObjects())
        for (objectID, block) in inputListeners where !matched.contains(objectID) {
            removeInputListener(objectID, block)
            inputListeners[objectID] = nil
        }
        for objectID in matched where inputListeners[objectID] == nil {
            addInputListener(objectID)
        }
    }

    private func addInputListener(_ objectID: AudioObjectID) {
        var address = Self.address(kAudioProcessPropertyIsRunningInput)
        let block: AudioObjectPropertyListenerBlock = { [self] _, _ in
            recomputeState()
        }
        let status = AudioObjectAddPropertyListenerBlock(objectID, &address, queue, block)
        if status == noErr {
            inputListeners[objectID] = block
        } else {
            logger.warning("注册麦克风活动监听失败：对象 \(objectID)，状态 \(status)")
        }
    }

    private func removeInputListener(_ objectID: AudioObjectID, _ block: @escaping AudioObjectPropertyListenerBlock) {
        var address = Self.address(kAudioProcessPropertyIsRunningInput)
        AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, block)
    }

    // MARK: - 状态计算（仅在 queue 上调用）

    /// 聚合所有匹配进程的 `IsRunningInput`，套用去抖后决定是否对外翻转状态。
    private func recomputeState() {
        let rawActive = matchedProcessObjects().contains { isRunningInput($0) }
        if rawActive {
            // 有活动：撤销待定的停止，必要时立即对外发出「开始」。
            pendingStop?.cancel()
            pendingStop = nil
            guard !micActive else { return }
            micActive = true
            logger.info("检测到目标 app 开始使用麦克风")
            continuation.yield(true)
        } else {
            // 无活动：仅在录制中且尚无待定停止时，安排静默去抖后再判定结束。
            guard micActive, pendingStop == nil else { return }
            let work = DispatchWorkItem { [self] in
                pendingStop = nil
                guard micActive else { return }
                micActive = false
                logger.info("目标 app 麦克风已静默，判定通话结束")
                continuation.yield(false)
            }
            pendingStop = work
            queue.asyncAfter(deadline: .now() + endDelay.rawValue, execute: work)
        }
    }

    // MARK: - CoreAudio 读取辅助

    /// 全局作用域、主元素的属性地址。
    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// 当前进程音频对象中，PID 反查 bundleId 命中目标 app 家族的那些。
    private func matchedProcessObjects() -> [AudioObjectID] {
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &dataSize) == noErr,
            dataSize > 0
        else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.stride
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &dataSize, &ids) == noErr else {
            return []
        }
        return ids.filter { matchesTarget($0) }
    }

    private func matchesTarget(_ objectID: AudioObjectID) -> Bool {
        guard let pid = processPID(objectID),
            let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        else { return false }
        return targetBundleMatcher.matches(bundleID)
    }

    private func processPID(_ objectID: AudioObjectID) -> pid_t? {
        var address = Self.address(kAudioProcessPropertyPID)
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &pid) == noErr else {
            return nil
        }
        return pid
    }

    private func isRunningInput(_ objectID: AudioObjectID) -> Bool {
        var address = Self.address(kAudioProcessPropertyIsRunningInput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }
}
