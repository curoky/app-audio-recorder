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
}
