import AVFoundation
import CoreMedia

/// 把 ScreenCaptureKit 输出的音频样本写入单个多轨容器（`.m4a` / ALAC 无损）。
///
/// app 与可选麦克风各写一条 ALAC 轨；样本连同其 `CMSampleBuffer` 的 PTS 一起落轨，
/// 两轨的相对起始偏移由容器时间线原生保存——无需在录制端插静音，事后也能用
/// `-c copy` 无损 demux 回独立 WAV。
///
/// 会话起点取「每条预期轨首帧 PTS 的较小值」：因此在收齐所有预期轨的首帧之前先暂存
/// 样本，收齐后统一 `startSession(atSourceTime:)` 再回放，从而精确保留两轨起始偏移
/// （app 与麦克风虽共享同一时钟，仍以此兜底任何首帧错位）。
///
/// 非 `Sendable`：实例只由 `AudioCaptureEngine` 在其串行采样队列上使用，不跨隔离域共享，
/// 因此内部可变状态无需加锁。
nonisolated final class AudioContainerWriter {
    /// 容器内的音轨类别。
    enum Track: Hashable { case app, mic }

    private let writer: AVAssetWriter
    private let inputs: [Track: AVAssetWriterInput]
    private let expectedTracks: Set<Track>

    private var firstPTS: [Track: CMTime] = [:]
    /// 会话开始前暂存的样本，按到达顺序回放。持有 `CMSampleBuffer` 即保留其数据与时序。
    private var pending: [(track: Track, buffer: CMSampleBuffer)] = []
    private var sessionStarted = false

    /// 已写入 app 轨的帧数，供结束时估算时长。
    private(set) var appFrames: AVAudioFramePosition = 0

    /// - Parameters:
    ///   - outputURL: 多轨容器落盘路径（`.m4a`）。
    ///   - sampleRate: 目标采样率。
    ///   - channels: 目标声道数。
    ///   - capturesMicrophone: 是否额外写一条麦克风轨。
    init(outputURL: URL, sampleRate: Int, channels: Int, capturesMicrophone: Bool) throws {
        // AVAssetWriter 遇到已存在文件会失败，先移除以对齐旧的覆盖写行为。
        try? FileManager.default.removeItem(at: outputURL)
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)

        // ALAC 无损：源为 ScreenCaptureKit 的 float32 LPCM，编码器按 16-bit 量化后无损封装，
        // 与旧的 16-bit PCM WAV 量化精度一致。
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: Double(sampleRate),
            AVNumberOfChannelsKey: channels,
            AVEncoderBitDepthHintKey: 16,
        ]

        func makeInput() -> AVAssetWriterInput {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            // 采样来自实时捕获回调，按到即写，不做节流。
            input.expectsMediaDataInRealTime = true
            return input
        }

        var inputs: [Track: AVAssetWriterInput] = [:]
        var expected: Set<Track> = [.app]

        let appInput = makeInput()
        writer.add(appInput)
        inputs[.app] = appInput

        if capturesMicrophone {
            let micInput = makeInput()
            writer.add(micInput)
            inputs[.mic] = micInput
            expected.insert(.mic)
        }

        self.inputs = inputs
        self.expectedTracks = expected

        guard writer.startWriting() else {
            throw writer.error ?? RecorderError.audioCaptureFailed
        }
    }

    /// 追加一段样本到指定轨。会话开始前先暂存，收齐每条预期轨首帧后统一开始并回放。
    func append(_ sampleBuffer: CMSampleBuffer, to track: Track) throws {
        guard inputs[track] != nil else { return }

        guard sessionStarted else {
            if firstPTS[track] == nil {
                firstPTS[track] = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            }
            pending.append((track, sampleBuffer))
            if expectedTracks.isSubset(of: Set(firstPTS.keys)) {
                try startSessionAndFlush()
            }
            return
        }
        try appendReady(sampleBuffer, to: track)
    }

    /// 标记所有输入结束（结束写入前的同步收尾）。必须在采样队列上调用。
    ///
    /// 兜底：若某些预期轨始终没到齐、会话尚未开始，则用已收到的首帧（或零）起会话并
    /// 回放暂存样本，避免丢弃已录内容。
    func finalizeInputs() {
        if !sessionStarted {
            try? startSessionAndFlush()
        }
        for input in inputs.values {
            input.markAsFinished()
        }
    }

    /// 异步收尾写入。应在 `finalizeInputs()` 之后、不再有样本追加时调用。
    func completeWriting() async throws {
        // finishWriting 的完成回调是 @Sendable，且可在任意线程触发；此处经采样队列同步
        // 收尾后不再有并发访问，用 nonisolated(unsafe) 桥接非 Sendable 的 AVAssetWriter。
        nonisolated(unsafe) let writer = self.writer
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        if writer.status == .failed {
            throw writer.error ?? RecorderError.audioCaptureFailed
        }
    }

    // MARK: - 私有

    private func startSessionAndFlush() throws {
        let origin = firstPTS.values.min() ?? .zero
        writer.startSession(atSourceTime: origin)
        sessionStarted = true

        let buffered = pending
        pending.removeAll()
        for item in buffered {
            try appendReady(item.buffer, to: item.track)
        }
    }

    private func appendReady(_ sampleBuffer: CMSampleBuffer, to track: Track) throws {
        guard let input = inputs[track] else { return }
        // 实时音频码率下几乎总是就绪；未就绪或追加失败都视为写盘异常，向上暴露而非静默丢弃。
        guard input.isReadyForMoreMediaData, input.append(sampleBuffer) else {
            throw writer.error ?? RecorderError.audioCaptureFailed
        }
        if track == .app {
            appFrames += AVAudioFramePosition(CMSampleBufferGetNumSamples(sampleBuffer))
        }
    }
}
