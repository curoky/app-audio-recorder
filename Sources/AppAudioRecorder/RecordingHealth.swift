import Foundation

/// 单条音轨的健康度量：真实捕获（非合成静音）帧数、真实样本峰值幅度及写盘丢帧数。
///
/// `didMeasurePeak` 区分「测到了但很静」与「根本没测到峰值（非 float32 等异常）」，
/// 后者不作静音判定，避免误报。
struct TrackAudioHealth: Sendable, Equatable {
    var capturedFrames: Int64
    var peakAmplitude: Float
    var didMeasurePeak: Bool
    var droppedBuffers: Int

    static let empty = TrackAudioHealth(
        capturedFrames: 0,
        peakAmplitude: 0,
        didMeasurePeak: false,
        droppedBuffers: 0
    )
}

/// 由每条轨的度量生成面向用户的健康告警。
///
/// 手动开始/停止只决定录制时长，并不保证这段时间两路都真的有声音进来；缺轨、静音、
/// 大量丢帧都会让「已保存」的文件实际不可用。停止时据此明确提示，而不是只报时长。
enum RecordingHealth {
    /// 低于该峰值即视为「全程接近静音」。约 -70 dBFS，真实（哪怕很轻的）声音都会超过。
    static let silencePeakThreshold: Float = 0.000_3
    /// 丢帧数达到该阈值才提示；个位数属实时写盘的正常抖动，不打扰。
    static let droppedBufferWarningThreshold = 10

    /// 生成健康告警；一切正常时返回空数组。`mic` 为 `nil` 表示本次未录麦克风。
    static func warnings(app: TrackAudioHealth, mic: TrackAudioHealth?) -> [String] {
        var messages = trackWarnings(
            label: "目标 App",
            health: app,
            silentHint: "，可能目标 App 全程没有输出声音"
        )
        if let mic {
            messages.append(
                contentsOf: trackWarnings(
                    label: "麦克风",
                    health: mic,
                    silentHint: "，请检查系统输入设备是否选对、是否被静音"
                )
            )
        }
        return messages
    }

    private static func trackWarnings(
        label: String,
        health: TrackAudioHealth,
        silentHint: String
    ) -> [String] {
        var messages: [String] = []
        if health.capturedFrames == 0 {
            messages.append("未捕获到任何\(label)音频，本次\(label)音轨为空。")
        } else if health.didMeasurePeak,
            health.peakAmplitude < silencePeakThreshold
        {
            messages.append("\(label)音轨全程接近静音\(silentHint)。")
        }
        if health.droppedBuffers >= droppedBufferWarningThreshold {
            messages.append(
                "\(label)有 \(health.droppedBuffers) 段音频因写盘拥塞被丢弃，音轨可能出现空洞。"
            )
        }
        return messages
    }
}
