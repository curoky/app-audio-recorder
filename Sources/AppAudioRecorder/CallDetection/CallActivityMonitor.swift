import AppKit
import CoreAudio
import Foundation
import OSLog

struct ProcessAudioActivity {
    let usesInput: Bool
    let usesOutput: Bool
}

struct CallActivityEvent: Sendable {
    let bundleIdentifier: String
    let isActive: Bool
}

struct CallActivityDebouncer: Sendable {
    private static let requiredInactivePolls = 2

    private(set) var isActive = false
    private var inactivePollCount = 0

    /// 返回去抖后的状态变化；`nil` 表示本轮不应发出事件。
    mutating func update(rawIsActive: Bool) -> Bool? {
        if rawIsActive {
            inactivePollCount = 0
            guard !isActive else { return nil }
            isActive = true
            return true
        }

        guard isActive else { return nil }
        inactivePollCount += 1
        guard inactivePollCount >= Self.requiredInactivePolls else {
            return nil
        }
        inactivePollCount = 0
        isActive = false
        return false
    }
}

/// 每三秒轮询多个目标 app 家族的 CoreAudio 进程活动，并分别输出去抖后的疑似通话状态。
///
/// 输入与输出可以由同一 app 的不同 helper 进程承载，因此按 bundle family 聚合：
/// 家族内至少一路输入且至少一路输出同时活动时才视为通话；连续两轮无活动才判定结束。
final class CallActivityMonitor: @unchecked Sendable {
    private static let pollingInterval: TimeInterval = 3

    private let queue = DispatchQueue(label: "app-audio-recorder.call-monitor")
    private let targets: [Target]
    private let logger = AppLog.logger("call-monitor")
    private let events: AsyncStream<CallActivityEvent>
    private let continuation: AsyncStream<CallActivityEvent>.Continuation

    // 以下状态仅在 `queue` 上访问。
    private var pollingTimer: DispatchSourceTimer?
    private var activityDebouncers: [String: CallActivityDebouncer] = [:]

    init(targetBundleIdentifiers: Set<String>) {
        targets = targetBundleIdentifiers.sorted().map {
            Target(
                bundleIdentifier: $0,
                matcher: ApplicationBundleMatcher(targetBundleIdentifier: $0)
            )
        }
        (events, continuation) = AsyncStream.makeStream(
            bufferingPolicy: .unbounded
        )
    }

    func activityEvents() -> AsyncStream<CallActivityEvent> { events }

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
            pollingTimer?.cancel()
            pollingTimer = nil
            activityDebouncers.removeAll()
            continuation.finish()
        }
    }

    static func hasCallActivity(_ activities: [ProcessAudioActivity]) -> Bool {
        activities.contains(where: \.usesInput)
            && activities.contains(where: \.usesOutput)
    }

    // MARK: - 状态计算（仅在 queue 上调用）

    private func recomputeState() {
        guard let activitiesByBundleIdentifier = matchedProcessActivities() else {
            logger.warning("读取 CoreAudio 进程活动失败，本轮保持现有状态")
            return
        }

        for target in targets {
            updateState(
                bundleIdentifier: target.bundleIdentifier,
                isActive: Self.hasCallActivity(
                    activitiesByBundleIdentifier[target.bundleIdentifier, default: []]
                )
            )
        }
    }

    private func updateState(bundleIdentifier: String, isActive: Bool) {
        let transition = activityDebouncers[
            bundleIdentifier,
            default: CallActivityDebouncer()
        ].update(rawIsActive: isActive)
        guard let transition else { return }

        if transition {
            logger.info("检测到 \(bundleIdentifier, privacy: .public) 同时使用音频输入与输出")
        } else {
            logger.info("\(bundleIdentifier, privacy: .public) 通话活动结束")
        }
        continuation.yield(
            CallActivityEvent(
                bundleIdentifier: bundleIdentifier,
                isActive: transition
            )
        )
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

    private func matchedProcessActivities() -> [String: [ProcessAudioActivity]]? {
        guard let objectIDs = processObjects() else { return nil }
        var activitiesByBundleIdentifier: [String: [ProcessAudioActivity]] = [:]
        for objectID in objectIDs {
            let matchedBundleIdentifiers = matchedTargets(objectID)
            guard !matchedBundleIdentifiers.isEmpty else { continue }
            guard let usesInput = isRunning(
                objectID,
                selector: kAudioProcessPropertyIsRunningInput
            ), let usesOutput = isRunning(
                objectID,
                selector: kAudioProcessPropertyIsRunningOutput
            ) else {
                return nil
            }
            let activity = ProcessAudioActivity(
                usesInput: usesInput,
                usesOutput: usesOutput
            )
            for bundleIdentifier in matchedBundleIdentifiers {
                activitiesByBundleIdentifier[bundleIdentifier, default: []].append(
                    activity
                )
            }
        }
        return activitiesByBundleIdentifier
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

    private func matchedTargets(_ objectID: AudioObjectID) -> [String] {
        guard let pid = processPID(objectID),
            let bundleID = NSRunningApplication(
                processIdentifier: pid
            )?.bundleIdentifier
        else { return [] }
        return targets.compactMap {
            $0.matcher.matches(bundleID) ? $0.bundleIdentifier : nil
        }
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

    private struct Target: Sendable {
        let bundleIdentifier: String
        let matcher: ApplicationBundleMatcher
    }
}
