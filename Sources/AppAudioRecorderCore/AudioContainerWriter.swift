import AVFoundation
import CoreMedia

/// 把 ScreenCaptureKit 输出的音频样本写入单个多轨容器（`.m4a` / ALAC 无损）。
///
/// app 与可选麦克风各写一条 ALAC 轨；样本连同其 `CMSampleBuffer` 的 PTS 一起处理，
/// 较晚开始的轨按首帧 PTS 补起始静音后落盘，因此事后用 `-c copy` 无损 demux 回独立
/// WAV 时也仍保留两轨对齐。
///
/// 会话起点优先取「每条预期轨首帧 PTS 的较小值」：收齐后统一
/// `startSession(atSourceTime:)` 再回放，从而精确保留两轨起始偏移。若某轨迟迟没有首帧，
/// 暂存达到约一秒或 256 个样本缓冲后即按已有最早 PTS 启动，避免内存随录制时长增长。
///
/// 非 `Sendable`：实例只由 `AudioCaptureEngine` 在其串行采样队列上使用，不跨隔离域共享，
/// 因此内部可变状态无需加锁。
nonisolated final class AudioContainerWriter {
    private static let maximumPendingBuffers = 256

    /// 容器内的音轨类别。
    enum Track: Hashable { case app, mic }

    private let writer: AVAssetWriter
    private let inputs: [Track: AVAssetWriterInput]
    private let expectedTracks: Set<Track>
    private let outputURL: URL
    private let maximumPendingFrames: Int

    private var firstPTS: [Track: CMTime] = [:]
    /// 会话开始前暂存的样本，按到达顺序回放。持有 `CMSampleBuffer` 即保留其数据与时序。
    private var pending: [(track: Track, buffer: CMSampleBuffer)] = []
    private var pendingFrames: [Track: Int] = [:]
    private var sessionStarted = false
    private var sessionOrigin: CMTime?
    private var startedTracks: Set<Track> = []

    /// 已写入 app 轨的帧数，供结束时估算时长。
    private(set) var appFrames: AVAudioFramePosition = 0

    /// - Parameters:
    ///   - outputURL: 多轨容器落盘路径（`.m4a`）。
    ///   - sampleRate: 目标采样率。
    ///   - channels: 目标声道数。
    ///   - capturesMicrophone: 是否额外写一条麦克风轨。
    init(
        outputURL: URL,
        sampleRate: Int,
        channels: Int,
        capturesMicrophone: Bool,
        overwritesExistingOutput: Bool = true
    ) throws {
        guard AudioFormatConstraints.sampleRates.contains(sampleRate),
              AudioFormatConstraints.channelCounts.contains(channels)
        else {
            throw RecorderError.audioCaptureFailed
        }
        if overwritesExistingOutput {
            try? FileManager.default.removeItem(at: outputURL)
        }
        self.outputURL = outputURL
        maximumPendingFrames = sampleRate
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
        guard writer.canAdd(appInput) else {
            throw RecorderError.audioCaptureFailed
        }
        writer.add(appInput)
        inputs[.app] = appInput

        if capturesMicrophone {
            let micInput = makeInput()
            guard writer.canAdd(micInput) else {
                throw RecorderError.audioCaptureFailed
            }
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
            pendingFrames[track, default: 0] += CMSampleBufferGetNumSamples(sampleBuffer)
            if expectedTracks.isSubset(of: Set(firstPTS.keys))
                || pendingFrames.values.contains(where: { $0 >= maximumPendingFrames })
                || pending.count >= Self.maximumPendingBuffers
            {
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
    func finalizeInputs() throws {
        var finalizationError: Error?
        if !sessionStarted {
            do {
                try startSessionAndFlush()
            } catch {
                finalizationError = error
            }
        }
        for input in inputs.values {
            input.markAsFinished()
        }
        if let finalizationError {
            throw finalizationError
        }
    }

    /// 取消尚未完成的写入，并按需移除本次产生的无效容器。
    func cancelWriting(removeOutput: Bool) {
        if writer.status == .unknown || writer.status == .writing {
            writer.cancelWriting()
        }
        pending.removeAll()
        pendingFrames.removeAll()
        if removeOutput {
            try? FileManager.default.removeItem(at: outputURL)
        }
    }

    /// 异步收尾写入。应在 `finalizeInputs()` 之后、不再有样本追加时调用。
    func completeWriting() async throws {
        // finishWriting 的完成回调是 @Sendable，且可在任意线程触发；此处经采样队列同步
        // 收尾后不再有并发访问，用 nonisolated(unsafe) 桥接非 Sendable 的 AVAssetWriter。
        nonisolated(unsafe) let writer = self.writer
        guard writer.status == .writing else {
            throw writer.error ?? RecorderError.audioCaptureFailed
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw writer.error ?? RecorderError.audioCaptureFailed
        }
    }

    // MARK: - 私有

    private func startSessionAndFlush() throws {
        guard writer.status == .writing else {
            throw writer.error ?? RecorderError.audioCaptureFailed
        }
        let origin = firstPTS.values.min() ?? .zero
        writer.startSession(atSourceTime: origin)
        sessionStarted = true
        sessionOrigin = origin

        let buffered = pending.sorted {
            CMTimeCompare(
                CMSampleBufferGetPresentationTimeStamp($0.buffer),
                CMSampleBufferGetPresentationTimeStamp($1.buffer)
            ) < 0
        }
        pending.removeAll()
        pendingFrames.removeAll()
        for item in buffered {
            try appendReady(item.buffer, to: item.track)
        }
    }

    private func appendReady(_ sampleBuffer: CMSampleBuffer, to track: Track) throws {
        guard let input = inputs[track] else { return }
        if !startedTracks.contains(track) {
            try appendInitialSilenceIfNeeded(matching: sampleBuffer, to: track, input: input)
            startedTracks.insert(track)
        }
        try appendToInput(sampleBuffer, to: track, input: input)
    }

    /// AVAssetWriter 会把每条音轨的首个音频样本各自归零；为较晚开始的轨补起始静音，
    /// 才能让编码后的两轨继续共享同一容器时间线。
    private func appendInitialSilenceIfNeeded(
        matching sampleBuffer: CMSampleBuffer,
        to track: Track,
        input: AVAssetWriterInput
    ) throws {
        guard let sessionOrigin else { return }
        let samplePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard CMTimeCompare(samplePTS, sessionOrigin) > 0,
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              var streamDescription =
                  CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
              let format = AVAudioFormat(streamDescription: &streamDescription)
        else { return }

        let offsetSeconds = CMTimeGetSeconds(CMTimeSubtract(samplePTS, sessionOrigin))
        guard offsetSeconds.isFinite, offsetSeconds > 0 else { return }

        let timescale = CMTimeScale(format.sampleRate.rounded())
        var remainingFrames = Int64((offsetSeconds * format.sampleRate).rounded())
        var emittedFrames: Int64 = 0
        let maximumChunkFrames = max(1, Int64(format.sampleRate.rounded()))

        while remainingFrames > 0 {
            let frameCount = AVAudioFrameCount(min(remainingFrames, maximumChunkFrames))
            let presentationTime = CMTimeAdd(
                sessionOrigin,
                CMTime(value: emittedFrames, timescale: timescale)
            )
            let silence = try makeSilenceBuffer(
                formatDescription: formatDescription,
                format: format,
                frameCount: frameCount,
                presentationTime: presentationTime
            )
            try appendToInput(silence, to: track, input: input)
            remainingFrames -= Int64(frameCount)
            emittedFrames += Int64(frameCount)
        }
    }

    private func makeSilenceBuffer(
        formatDescription: CMAudioFormatDescription,
        format: AVAudioFormat,
        frameCount: AVAudioFrameCount,
        presentationTime: CMTime
    ) throws -> CMSampleBuffer {
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw RecorderError.audioCaptureFailed
        }
        pcmBuffer.frameLength = frameCount
        for buffer in UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList) {
            buffer.mData?.assumingMemoryBound(to: UInt8.self).initialize(
                repeating: 0,
                count: Int(buffer.mDataByteSize)
            )
        }

        let sampleRate = CMTimeScale(format.sampleRate.rounded())
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: sampleRate),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleSize = Int(format.streamDescription.pointee.mBytesPerFrame)
        var sampleBuffer: CMSampleBuffer?
        let createStatus = withUnsafePointer(to: &sampleSize) { sampleSizePointer in
            CMSampleBufferCreate(
                allocator: kCFAllocatorDefault,
                dataBuffer: nil,
                dataReady: false,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: formatDescription,
                sampleCount: Int(frameCount),
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: format.isInterleaved ? 1 : 0,
                sampleSizeArray: format.isInterleaved ? sampleSizePointer : nil,
                sampleBufferOut: &sampleBuffer
            )
        }
        guard createStatus == noErr, let sampleBuffer else {
            throw RecorderError.audioCaptureFailed
        }

        let dataStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            bufferList: pcmBuffer.audioBufferList
        )
        guard dataStatus == noErr, CMSampleBufferSetDataReady(sampleBuffer) == noErr else {
            throw RecorderError.audioCaptureFailed
        }
        return sampleBuffer
    }

    private func appendToInput(
        _ sampleBuffer: CMSampleBuffer,
        to track: Track,
        input: AVAssetWriterInput
    ) throws {
        // 实时音频码率下几乎总是就绪；未就绪或追加失败都视为写盘异常，向上暴露而非静默丢弃。
        guard input.isReadyForMoreMediaData, input.append(sampleBuffer) else {
            throw writer.error ?? RecorderError.audioCaptureFailed
        }
        if track == .app {
            appFrames += AVAudioFramePosition(CMSampleBufferGetNumSamples(sampleBuffer))
        }
    }
}
