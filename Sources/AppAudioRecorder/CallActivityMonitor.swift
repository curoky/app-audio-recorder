import AppKit
import CoreAudio
import Foundation
import OSLog

struct ProcessAudioActivity: Equatable {
    let usesInput: Bool
    let usesOutput: Bool
}

/// 每三秒轮询目标 app 家族的 CoreAudio 进程活动，并输出去抖后的疑似通话状态。
///
/// 输入与输出可以由同一 app 的不同 helper 进程承载，因此按 bundle family 聚合：
/// 家族内至少一路输入且至少一路输出同时活动时才视为通话。
final class CallActivityMonitor: @unchecked Sendable {
    private static let pollingInterval: TimeInterval = 3
    private static let endDelay: TimeInterval = 2

    private let queue = DispatchQueue(label: "app-audio-recorder.call-monitor")
    private let targetBundleMatcher: ApplicationBundleMatcher
    private let logger = AppLog.logger("call-monitor")
    private let events: AsyncStream<Bool>
    private let continuation: AsyncStream<Bool>.Continuation

    // 以下状态仅在 `queue` 上访问。
    private var pollingTimer: DispatchSourceTimer?
    private var callActive = false
    private var pendingStop: DispatchWorkItem?

    init(targetBundleID: String) {
        targetBundleMatcher = ApplicationBundleMatcher(
            targetBundleIdentifier: targetBundleID
        )
        (events, continuation) = AsyncStream.makeStream(
            bufferingPolicy: .unbounded
        )
    }

    func activityEvents() -> AsyncStream<Bool> { events }

    /// 立即扫描一次，随后固定轮询；同一实例只启动一次。
    func start() {
        queue.async { [self] in
            guard pollingTimer == nil else { return }
            recomputeState()

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(
                deadline: .now() + Self.pollingInterval,
                repeating: Self.pollingInterval
            )
            timer.setEventHandler { [weak self] in
                self?.recomputeState()
            }
            pollingTimer = timer
            timer.resume()
        }
    }

    /// 停止轮询并结束事件流（幂等）。
    func stop() {
        queue.async { [self] in
            pendingStop?.cancel()
            pendingStop = nil
            pollingTimer?.cancel()
            pollingTimer = nil
            continuation.finish()
        }
    }

    static func hasCallActivity(_ activities: [ProcessAudioActivity]) -> Bool {
        activities.contains(where: \.usesInput)
            && activities.contains(where: \.usesOutput)
    }

    // MARK: - 状态计算（仅在 queue 上调用）

    private func recomputeState() {
        guard let activities = matchedProcessActivities() else {
            logger.warning("读取 CoreAudio 进程活动失败，本轮保持现有状态")
            return
        }
        let rawActive = Self.hasCallActivity(activities)
        if rawActive {
            pendingStop?.cancel()
            pendingStop = nil
            guard !callActive else { return }
            callActive = true
            logger.info("检测到目标 app 同时使用音频输入与输出")
            continuation.yield(true)
            return
        }

        guard callActive, pendingStop == nil else { return }
        let work = DispatchWorkItem { [self] in
            pendingStop = nil
            guard callActive else { return }
            callActive = false
            logger.info("目标 app 通话活动结束")
            continuation.yield(false)
        }
        pendingStop = work
        queue.asyncAfter(deadline: .now() + Self.endDelay, execute: work)
    }

    // MARK: - CoreAudio 读取辅助

    private static func address(
        _ selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func matchedProcessActivities() -> [ProcessAudioActivity]? {
        guard let objectIDs = processObjects() else { return nil }
        var activities: [ProcessAudioActivity] = []
        for objectID in objectIDs where matchesTarget(objectID) {
            guard let usesInput = isRunning(
                objectID,
                selector: kAudioProcessPropertyIsRunningInput
            ), let usesOutput = isRunning(
                objectID,
                selector: kAudioProcessPropertyIsRunningOutput
            ) else {
                return nil
            }
            activities.append(
                ProcessAudioActivity(
                    usesInput: usesInput,
                    usesOutput: usesOutput
                )
            )
        }
        return activities
    }

    private func processObjects() -> [AudioObjectID]? {
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            systemObject,
            &address,
            0,
            nil,
            &dataSize
        ) == noErr else {
            return nil
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.stride
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            systemObject,
            &address,
            0,
            nil,
            &dataSize,
            &ids
        ) == noErr else {
            return nil
        }
        return ids
    }

    private func matchesTarget(_ objectID: AudioObjectID) -> Bool {
        guard let pid = processPID(objectID),
            let bundleID = NSRunningApplication(
                processIdentifier: pid
            )?.bundleIdentifier
        else { return false }
        return targetBundleMatcher.matches(bundleID)
    }

    private func processPID(_ objectID: AudioObjectID) -> pid_t? {
        var address = Self.address(kAudioProcessPropertyPID)
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &pid
        ) == noErr else {
            return nil
        }
        return pid
    }

    private func isRunning(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> Bool? {
        var address = Self.address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else {
            return nil
        }
        return value != 0
    }
}
