struct RecordingConfiguration: Equatable, Sendable {
    enum SampleRate: Int, CaseIterable, Hashable, Sendable {
        case hz8K = 8_000
        case hz16K = 16_000
        case hz24K = 24_000
        case hz32K = 32_000
        case hz44K = 44_100
        case hz48K = 48_000
    }

    enum ChannelCount: Int, CaseIterable, Hashable, Sendable {
        case mono = 1
        case stereo = 2
    }

    var sampleRate: SampleRate = .hz48K
    var channelCount: ChannelCount = .stereo
    var capturesMicrophone = true

    /// 麦克风设备的 CoreAudio UID；`nil` 表示跟随系统默认输入设备（自动切换），
    /// 只有用户主动在界面上锁定某个设备时才会填入具体值。
    var microphoneDeviceID: String?

    /// 单段录音的硬上限（秒），到点自动停止并保存。用一个粗暴的固定上限，
    /// 替代运行时磁盘轮询，避免无人值守时无限录制撑爆磁盘。默认 4 小时。
    let maxDurationSeconds: Double = 4 * 60 * 60
}
