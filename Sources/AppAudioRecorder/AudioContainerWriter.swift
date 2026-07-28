import AVFoundation
import CoreMedia

/// 把 ScreenCaptureKit 输出的音频样本写入单个多轨容器（`.m4a` / ALAC 无损）。
///
/// app 与可选麦克风各写一条 ALAC 轨；样本连同其 `CMSampleBuffer` 的 PTS 一起处理，
/// 较晚开始的轨按首帧 PTS 补起始静音，中途 PTS 缺口和结束时的短轨尾部也补静音，
/// 因此事后用 `-c copy` 无损 demux 回独立 WAV 时仍保留两轨时间线。
///
/// 会话起点优先取「每条预期轨首帧 PTS 的较小值」：收齐后统一
/// `startSession(atSourceTime:)` 再回放，从而精确保留两轨起始偏移。若某轨迟迟没有首帧，
/// 暂存达到约一秒或 256 个样本缓冲后即按已有最早 PTS 启动，避免内存随录制时长增长。
///
/// 非 `Sendable`：实例只由 `AudioCaptureEngine` 在其串行采样队列上使用，不跨隔离域共享，
/// 因此内部可变状态无需加锁。
nonisolated final class AudioContainerWriter {
    private static let maximumPendingBuffers = 256
    private static let maximumSilenceChunkFrames = 1_024
    private static let gapToleranceSeconds = 0.005

    /// 容器内的音轨类别。
    enum Track: Hashable { case app, mic }

    private struct TrackFormat {
        let description: CMAudioFormatDescription
        let audioFormat: AVAudioFormat
    }

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
    private var nextExpectedPTS: [Track: CMTime] = [:]
    private var trackFormats: [Track: TrackFormat] = [:]
    private var writtenFrames: [Track: AVAudioFramePosition] = [:]
    private var droppedBuffers: [Track: Int] = [:]
    /// 真实捕获（非合成静音）追加成功的帧数，用于区分「录到了」与「只补了静音」。
    private var capturedFrames: [Track: Int64] = [:]
    private var peakAmplitude: [Track: Float] = [:]
    private var didMeasurePeak: [Track: Bool] = [:]

    /// 已写入 app 轨的帧数，供结束时估算时长。
    private(set) var appFrames: AVAudioFramePosition = 0

    var recordedFrames: AVAudioFramePosition {
        writtenFrames.values.max() ?? 0
    }

    /// 指定轨的健康度量，仅统计真实捕获样本；`.mic` 未启用时返回 `.empty`。
    func health(for track: Track) -> TrackAudioHealth {
        guard expectedTracks.contains(track) else { return .empty }
        return TrackAudioHealth(
            capturedFrames: capturedFrames[track, default: 0],
            peakAmplitude: peakAmplitude[track, default: 0],
            didMeasurePeak: didMeasurePeak[track, default: false],
            droppedBuffers: droppedBuffers[track, default: 0]
        )
    }

    /// - Parameters:
    ///   - outputURL: 多轨容器落盘路径（`.m4a`）。
    ///   - configuration: 音频格式及是否额外写一条麦克风轨。
    init(
        outputURL: URL,
        configuration: RecordingConfiguration
    ) throws {
        let sampleRate = configuration.sampleRate.rawValue
        self.outputURL = outputURL
        maximumPendingFrames = sampleRate
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

        // ALAC 无损：源为 ScreenCaptureKit 的 float32 LPCM，编码器按 16-bit 量化后无损封装，
        // 与旧的 16-bit PCM WAV 量化精度一致。
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: Double(sampleRate),
            AVNumberOfChannelsKey: configuration.channelCount.rawValue,
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

        if configuration.capturesMicrophone {
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
        if finalizationError == nil {
            do {
                try padShorterTracks()
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
        nextExpectedPTS.removeAll()
        trackFormats.removeAll()
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
        guard let input = inputs[track],
            let format = trackFormat(from: sampleBuffer)
        else { return }
        trackFormats[track] = format

        let samplePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if let expectedPTS = nextExpectedPTS[track] {
            let gapSeconds = CMTimeGetSeconds(CMTimeSubtract(samplePTS, expectedPTS))
            if gapSeconds.isFinite, gapSeconds > Self.gapToleranceSeconds {
                try appendSilence(
                    from: expectedPTS,
                    to: samplePTS,
                    format: format,
                    track: track,
                    input: input
                )
            }
        } else if let sessionOrigin, CMTimeCompare(samplePTS, sessionOrigin) > 0 {
            try appendSilence(
                from: sessionOrigin,
                to: samplePTS,
                format: format,
                track: track,
                input: input
            )
        }

        if try appendToInput(sampleBuffer, to: track, input: input) {
            measureCapturedAudio(sampleBuffer, format: format.audioFormat, track: track)
            nextExpectedPTS[track] = bufferEndTime(sampleBuffer, format: format.audioFormat)
        }
    }

    private func appendSilence(
        from start: CMTime,
        to end: CMTime,
        format: TrackFormat,
        track: Track,
        input: AVAssetWriterInput
    ) throws {
        let gapSeconds = CMTimeGetSeconds(CMTimeSubtract(end, start))
        guard gapSeconds.isFinite, gapSeconds > 0 else { return }

        let sampleRate = format.audioFormat.sampleRate
        let timescale = CMTimeScale(sampleRate.rounded())
        var remainingFrames = Int64((gapSeconds * sampleRate).rounded())
        var emittedFrames: Int64 = 0

        while remainingFrames > 0 {
            guard input.isReadyForMoreMediaData else { return }
            let frameCount = AVAudioFrameCount(
                min(remainingFrames, Int64(Self.maximumSilenceChunkFrames))
            )
            let presentationTime = CMTimeAdd(
                start,
                CMTime(value: emittedFrames, timescale: timescale)
            )
            let silence = try makeSilenceBuffer(
                formatDescription: format.description,
                format: format.audioFormat,
                frameCount: frameCount,
                presentationTime: presentationTime
            )
            guard try appendToInput(silence, to: track, input: input) else { return }
            remainingFrames -= Int64(frameCount)
            emittedFrames += Int64(frameCount)
            nextExpectedPTS[track] = CMTimeAdd(
                presentationTime,
                CMTime(value: Int64(frameCount), timescale: timescale)
            )
        }
    }

    private func padShorterTracks() throws {
        guard let finalEnd = nextExpectedPTS.values.max(by: {
            CMTimeCompare($0, $1) < 0
        }), let sessionOrigin, let fallbackFormat = trackFormats.values.first
        else { return }

        for track in expectedTracks {
            let start = nextExpectedPTS[track] ?? sessionOrigin
            guard CMTimeCompare(start, finalEnd) < 0,
                let input = inputs[track]
            else { continue }
            try appendSilence(
                from: start,
                to: finalEnd,
                format: trackFormats[track] ?? fallbackFormat,
                track: track,
                input: input
            )
        }
    }

    private func trackFormat(from sampleBuffer: CMSampleBuffer) -> TrackFormat? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
            var streamDescription =
                CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
            let audioFormat = AVAudioFormat(streamDescription: &streamDescription)
        else { return nil }
        return TrackFormat(description: description, audioFormat: audioFormat)
    }

    /// 统计真实捕获帧数并扫描 float32 样本峰值，用于停止时的轨道健康判定。
    ///
    /// 仅在成功追加真实样本后调用；补的静音不计入。非 float32 或读取失败时只累加帧数、
    /// 不标记已测峰值，避免把「无法测量」误判成「静音」。峰值扫描按裸 buffer 遍历，
    /// 交错与非交错布局都适用。
    private func measureCapturedAudio(
        _ sampleBuffer: CMSampleBuffer,
        format: AVAudioFormat,
        track: Track
    ) {
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        capturedFrames[track, default: 0] += Int64(frameCount)
        guard frameCount > 0,
            format.commonFormat == .pcmFormatFloat32,
            let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return }
        pcmBuffer.frameLength = frameCount
        guard
            CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sampleBuffer,
                at: 0,
                frameCount: Int32(frameCount),
                into: pcmBuffer.mutableAudioBufferList
            ) == noErr
        else { return }

        var peak = peakAmplitude[track, default: 0]
        for buffer in UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList) {
            guard let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let samples = data.assumingMemoryBound(to: Float.self)
            for index in 0..<count {
                let magnitude = abs(samples[index])
                if magnitude > peak { peak = magnitude }
            }
        }
        peakAmplitude[track] = peak
        didMeasurePeak[track] = true
    }

    private func bufferEndTime(
        _ sampleBuffer: CMSampleBuffer,
        format: AVAudioFormat
    ) -> CMTime {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        return CMTimeAdd(
            presentationTime,
            CMTime(
                value: Int64(CMSampleBufferGetNumSamples(sampleBuffer)),
                timescale: CMTimeScale(format.sampleRate.rounded())
            )
        )
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
    ) throws -> Bool {
        guard input.isReadyForMoreMediaData else {
            droppedBuffers[track, default: 0] += 1
            return false
        }
        guard input.append(sampleBuffer) else {
            throw writer.error ?? RecorderError.audioCaptureFailed
        }
        let frameCount = AVAudioFramePosition(CMSampleBufferGetNumSamples(sampleBuffer))
        writtenFrames[track, default: 0] += frameCount
        if track == .app {
            appFrames += frameCount
        }
        return true
    }
}
