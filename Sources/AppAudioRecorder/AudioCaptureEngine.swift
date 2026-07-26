import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// 基于 ScreenCaptureKit 的按 app 音频捕获引擎，可选同时捕获麦克风输入。
///
/// 只负责捕获生命周期与样本转发；样本落盘交给 `WAVWriter`（app 与 mic 各一路）。
///
/// 并发模型：`SCStreamOutput` 回调固定在注册时传入的串行队列 `sampleQueue` 上触发，
/// `SCStreamDelegate` 的错误回调也显式转投该队列。所有可变写入状态（`appWriter`/
/// `micWriter`/`writeError`）都只在该队列上访问，故对外标记 `@unchecked Sendable`
/// 是有依据的——这是桥接回调式 API 的必要手段，而非规避编译期检查。
final class AudioCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let sampleRate: Int
    let channelCount: Int
    /// 是否同时捕获麦克风输入。
    let capturesMicrophone: Bool

    private let sampleQueue = DispatchQueue(label: "app-audio-recorder.sample")
    private let appWriter: WAVWriter
    private let micWriter: WAVWriter?
    private let failureEvents: AsyncStream<Void>
    private let failureContinuation: AsyncStream<Void>.Continuation
    private var stream: SCStream?
    private var writeError: Error?

    /// - Parameters:
    ///   - appOutputURL: app 音频落盘路径。
    ///   - micOutputURL: 麦克风落盘路径；为 nil 时不捕获麦克风。
    init(
        appOutputURL: URL,
        micOutputURL: URL?,
        sampleRate: Int = 48_000,
        channelCount: Int = 2
    ) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.capturesMicrophone = micOutputURL != nil
        self.appWriter = WAVWriter(outputURL: appOutputURL)
        self.micWriter = micOutputURL.map { WAVWriter(outputURL: $0) }
        (self.failureEvents, self.failureContinuation) = AsyncStream.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        super.init()
    }

    /// 已写入的时长（秒），以 app 音轨为准，供结束时报告。
    var recordedSeconds: Double {
        sampleQueue.sync { Double(appWriter.totalFrames) / Double(sampleRate) }
    }

    // MARK: - 生命周期

    func start(filter: SCContentFilter) async throws(RecorderError) {
        do {
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.sampleRate = sampleRate
            config.channelCount = channelCount
            // 不录制自己进程的声音。
            config.excludesCurrentProcessAudio = true
            if capturesMicrophone {
                // macOS 15+：让 SCStream 额外输出一路麦克风。两路共享同一时钟、同时开始。
                config.captureMicrophone = true
            }
            // 只要音频，视频压到最小以省资源。
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.queueDepth = 6

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            if capturesMicrophone {
                try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sampleQueue)
            }
            try await stream.startCapture()
            self.stream = stream
        } catch {
            throw .audioCaptureFailed
        }
    }

    /// 等待捕获流或任一路写盘发生异常。
    func waitForFailure() async {
        for await _ in failureEvents { return }
    }

    func stop() async throws(RecorderError) {
        var stopError: Error?
        if let stream {
            do {
                try await stream.stopCapture()
            } catch {
                stopError = error
            }
            self.stream = nil
        }
        // 在采样队列上同步收尾，确保各路 WAV 头长度被正确写回。
        let recordedError = sampleQueue.sync {
            appWriter.finish()
            micWriter?.finish()
            return writeError
        }
        failureContinuation.finish()

        if let error = recordedError ?? stopError {
            if let recorderError = error as? RecorderError {
                throw recorderError
            }
            throw .audioCaptureFailed
        }
    }

    // MARK: - SCStreamOutput（仅在 sampleQueue 上回调）

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard writeError == nil else { return }
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }

        let writer: WAVWriter?
        switch type {
        case .audio: writer = appWriter
        case .microphone: writer = micWriter
        default: writer = nil
        }
        guard let writer else { return }

        do {
            try writer.write(sampleBuffer)
        } catch {
            recordFailure(error)
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        sampleQueue.async { self.recordFailure(error) }
    }

    /// 仅在 `sampleQueue` 上调用；保留首个错误并通知等待方。
    private func recordFailure(_ error: Error) {
        guard writeError == nil else { return }
        writeError = error
        failureContinuation.yield()
    }
}
