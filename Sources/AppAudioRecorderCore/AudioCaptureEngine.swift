import AVFoundation
import CoreMedia
import Logging
import ScreenCaptureKit

/// 基于 ScreenCaptureKit 的按 app 音频捕获引擎，可选同时捕获麦克风输入。
///
/// 只负责捕获生命周期与样本转发；样本落盘交给 `AudioContainerWriter`
/// （app 与可选 mic 写入同一个多轨容器）。
///
/// 并发模型：`SCStreamOutput` 回调固定在注册时传入的串行队列 `sampleQueue` 上触发，
/// `SCStreamDelegate` 的错误回调也显式转投该队列。所有可变写入状态（`writer`/
/// `writeError`）都只在该队列上访问，故对外标记 `@unchecked Sendable` 是有依据的——
/// 这是桥接回调式 API 的必要手段，而非规避编译期检查。
final class AudioCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let sampleRate: Int
    let channelCount: Int
    /// 是否同时捕获麦克风输入。
    let capturesMicrophone: Bool

    private let sampleQueue = DispatchQueue(label: "app-audio-recorder.sample")
    private let outputURL: URL
    private let overwritesExistingOutput: Bool
    private let logger: Logger
    private var writer: AudioContainerWriter?
    private let failureEvents: AsyncStream<Void>
    private let failureContinuation: AsyncStream<Void>.Continuation
    private var stream: SCStream?
    private var writeError: Error?

    /// - Parameters:
    ///   - outputURL: 多轨容器落盘路径。
    ///   - capturesMicrophone: 是否额外捕获麦克风并写入第二条轨。
    ///   - logger: 诊断日志（stderr）；记录捕获生命周期与被泛化前的原始错误。
    init(
        outputURL: URL,
        capturesMicrophone: Bool,
        sampleRate: Int = 48_000,
        channelCount: Int = 2,
        overwritesExistingOutput: Bool = false,
        logger: Logger = AppLog.logger("capture")
    ) {
        self.outputURL = outputURL
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.capturesMicrophone = capturesMicrophone
        self.overwritesExistingOutput = overwritesExistingOutput
        self.logger = logger
        (self.failureEvents, self.failureContinuation) = AsyncStream.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        super.init()
    }

    /// 已写入的时长（秒），以 app 音轨为准，供结束时报告。
    var recordedSeconds: Double {
        sampleQueue.sync { Double(writer?.appFrames ?? 0) / Double(sampleRate) }
    }

    // MARK: - 生命周期

    func start(filter: SCContentFilter) async throws(RecorderError) {
        do {
            // 容器写入器在采样队列上创建，与后续样本追加共用同一串行域。
            try sampleQueue.sync {
                writer = try AudioContainerWriter(
                    outputURL: outputURL,
                    sampleRate: sampleRate,
                    channels: channelCount,
                    capturesMicrophone: capturesMicrophone,
                    overwritesExistingOutput: overwritesExistingOutput
                )
            }

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
            logger.debug("捕获已启动", metadata: [
                "sampleRate": .stringConvertible(sampleRate),
                "channels": .stringConvertible(channelCount),
                "mic": .stringConvertible(capturesMicrophone),
            ])
        } catch {
            sampleQueue.sync {
                writer?.cancelWriting(removeOutput: true)
                writer = nil
            }
            failureContinuation.finish()
            logger.error("启动捕获失败", metadata: ["error": .string(String(describing: error))])
            throw .audioCaptureFailed
        }
    }

    /// 等待捕获流或写盘发生异常。
    func waitForFailure() async {
        for await _ in failureEvents { return }
    }

    func stop() async throws(RecorderError) {
        var stopError: Error?
        if let stream {
            do {
                try await stream.stopCapture()
            } catch {
                // 即便停止失败也要走完容器收尾以写出有效文件；记录原始错误便于排查。
                logger.warning("停止捕获时报错，仍继续收尾容器", metadata: ["error": .string(String(describing: error))])
                stopError = error
            }
            self.stream = nil
        }
        // 先在采样队列上同步标记所有输入结束（不再有样本追加），并取出已记录的错误。
        let (writerToFinish, recordedError, finalizationError) = sampleQueue.sync {
            var finalizationError: Error?
            do {
                try writer?.finalizeInputs()
            } catch {
                finalizationError = error
            }
            return (writer, writeError, finalizationError)
        }
        failureContinuation.finish()

        // 容器收尾（异步 flush 到磁盘）在采样队列之外进行，此时已无并发样本追加。
        do {
            try await writerToFinish?.completeWriting()
        } catch {
            logger.error("容器收尾写入失败", metadata: ["error": .string(String(describing: error))])
            stopError = stopError ?? error
        }

        if let error = recordedError ?? finalizationError ?? stopError {
            if let recorderError = error as? RecorderError {
                throw recorderError
            }
            throw .audioCaptureFailed
        }
        logger.debug("容器已写出", metadata: ["output": .string(outputURL.path)])
    }

    // MARK: - SCStreamOutput（仅在 sampleQueue 上回调）

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard writeError == nil else { return }
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }

        let track: AudioContainerWriter.Track
        switch type {
        case .audio: track = .app
        case .microphone: track = .mic
        default: return
        }

        do {
            try writer?.append(sampleBuffer, to: track)
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
        logger.error("捕获/写盘异常，将停止录制", metadata: ["error": .string(String(describing: error))])
        failureContinuation.yield()
    }
}
