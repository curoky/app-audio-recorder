import AVFoundation
import CoreMedia
import OSLog
import ScreenCaptureKit

/// 基于 ScreenCaptureKit 的按 app 音频捕获引擎，可选同时捕获麦克风输入。
///
/// 只负责捕获生命周期与样本转发；样本落盘交给 `AudioContainerWriter`
/// （app 与可选 mic 写入同一个多轨容器）。
///
/// 并发模型：`SCStreamOutput` 回调固定在注册时传入的串行队列 `sampleQueue` 上触发，
/// `SCStreamDelegate` 的错误回调也显式转投该队列。所有可变写入状态（`writer`、
/// `failure`、`writerError`）都只在该队列上访问，故对外标记 `@unchecked Sendable`
/// 是有依据的——
/// 这是桥接回调式 API 的必要手段，而非规避编译期检查。
final class AudioCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let sampleQueue = DispatchQueue(label: "app-audio-recorder.sample")
    private let outputURL: URL
    private let configuration: RecordingConfiguration
    private let logger = AppLog.logger("capture")
    private var writer: AudioContainerWriter?
    private let events: AsyncStream<RecordingEngineEvent>
    private let eventContinuation: AsyncStream<RecordingEngineEvent>.Continuation
    private var stream: SCStream?
    private var failure: RecorderError?
    private var writerError: Error?
    /// 到达配置的时长上限后自动收尾的一次性定时器；用简单粗暴的硬上限避免无人值守时无限录制。
    private var durationLimitTimer: DispatchSourceTimer?
    /// 录制期间持有的休眠抑制凭据；防止系统在长时间录音（尤其无人值守）时睡眠截断音频。
    private var sleepAssertion: NSObjectProtocol?

    /// - Parameters:
    ///   - outputURL: 多轨容器落盘路径。
    ///   - configuration: 采样格式及是否额外捕获麦克风。
    init(
        outputURL: URL,
        configuration: RecordingConfiguration
    ) {
        self.outputURL = outputURL
        self.configuration = configuration
        (self.events, self.eventContinuation) = AsyncStream.makeStream(
            bufferingPolicy: .bufferingNewest(4)
        )
        super.init()
    }

    // MARK: - 生命周期

    func start(filter: SCContentFilter) async throws(RecorderError) {
        do {
            // 容器写入器在采样队列上创建，与后续样本追加共用同一串行域。
            try sampleQueue.sync {
                writer = try AudioContainerWriter(
                    outputURL: outputURL,
                    configuration: configuration
                )
            }

            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.sampleRate = configuration.sampleRate.rawValue
            config.channelCount = configuration.channelCount.rawValue
            // 不录制自己进程的声音。
            config.excludesCurrentProcessAudio = true
            if configuration.capturesMicrophone {
                // macOS 15+：让 SCStream 额外输出一路麦克风。两路共享同一时钟、同时开始。
                config.captureMicrophone = true
                // nil 时跟随系统默认输入设备（自动切换）；用户主动锁定某个设备时透传其 UID。
                config.microphoneCaptureDeviceID = configuration.microphoneDeviceID
            }
            // 只要音频，视频压到最小以省资源。
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.queueDepth = 6

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            if configuration.capturesMicrophone {
                try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sampleQueue)
            }
            try await stream.startCapture()
            self.stream = stream
            beginSleepAssertion()
            startDurationLimit()
            logger.debug(
                "捕获已启动：\(self.configuration.sampleRate.rawValue) Hz，\(self.configuration.channelCount.rawValue) 声道，麦克风 \(self.configuration.capturesMicrophone)"
            )
        } catch {
            sampleQueue.sync {
                writer?.cancelWriting(removeOutput: true)
                writer = nil
            }
            eventContinuation.finish()
            let message = String(describing: error)
            logger.error("启动捕获失败：\(message, privacy: .public)")
            throw Self.recorderError(from: error)
        }
    }

    func eventStream() async -> AsyncStream<RecordingEngineEvent> {
        events
    }

    func stop() async -> RecordingResult {
        var stopError: Error?
        if let stream {
            do {
                try await stream.stopCapture()
            } catch {
                // 即便停止失败也要走完容器收尾以写出有效文件；记录原始错误便于排查。
                let message = String(describing: error)
                logger.warning("停止捕获时报错，仍继续收尾容器：\(message, privacy: .public)")
                stopError = error
            }
            self.stream = nil
        }
        endSleepAssertion()

        let (
            writerToFinish,
            recordedFailure,
            recordedWriterError,
            finalizationError,
            recordedSeconds
        ) = sampleQueue.sync {
            stopDurationLimit()
            var finalizationError: Error?
            do {
                try writer?.finalizeInputs()
            } catch {
                finalizationError = error
            }
            let seconds =
                Double(writer?.recordedFrames ?? 0)
                / Double(configuration.sampleRate.rawValue)
            return (
                writer,
                failure,
                writerError,
                finalizationError,
                seconds
            )
        }
        eventContinuation.finish()

        var completionError: Error?
        var outputCompleted = false
        do {
            try await writerToFinish?.completeWriting()
            outputCompleted =
                writerToFinish != nil
                && recordedWriterError == nil
                && finalizationError == nil
        } catch {
            completionError = error
            let message = String(describing: error)
            logger.error("容器收尾写入失败：\(message, privacy: .public)")
        }

        if !outputCompleted {
            writerToFinish?.cancelWriting(removeOutput: true)
        }
        sampleQueue.sync {
            writer = nil
        }

        var warnings: [String] = []
        if let recordedFailure {
            warnings.append(recordedFailure.localizedDescription)
        }
        for error in [stopError, recordedWriterError, finalizationError, completionError] {
            guard let error else { continue }
            let message = error.localizedDescription
            if !warnings.contains(message) {
                warnings.append(message)
            }
        }
        if !outputCompleted {
            warnings.append("录音文件未能完成写入，已移除无效文件。")
        } else {
            logger.debug("容器已写出：\(self.outputURL.path, privacy: .public)")
        }

        return RecordingResult(
            outputURL: outputCompleted ? outputURL : nil,
            recordedSeconds: recordedSeconds,
            warning: warnings.isEmpty ? nil : warnings.joined(separator: "\n")
        )
    }

    // MARK: - SCStreamOutput（仅在 sampleQueue 上回调）

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard failure == nil else { return }
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
            recordFailure(.audioCaptureFailed, writerError: error)
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        sampleQueue.async {
            self.recordFailure(Self.recorderError(from: error))
        }
    }

    // MARK: - 休眠抑制

    private func beginSleepAssertion() {
        guard sleepAssertion == nil else { return }
        sleepAssertion = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .automaticTerminationDisabled],
            reason: "正在录制音频"
        )
    }

    private func endSleepAssertion() {
        guard let sleepAssertion else { return }
        ProcessInfo.processInfo.endActivity(sleepAssertion)
        self.sleepAssertion = nil
    }

    // MARK: - 时长上限（一次性定时器，仅在 sampleQueue 上调度）

    private func startDurationLimit() {
        sampleQueue.sync {
            guard durationLimitTimer == nil, failure == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: sampleQueue)
            timer.schedule(deadline: .now() + configuration.maxDurationSeconds)
            timer.setEventHandler { [weak self] in
                guard let self, self.failure == nil else { return }
                self.stopDurationLimit()
                self.logger.notice("已达到录音时长上限，自动停止并保存。")
                self.eventContinuation.yield(.stopRequested)
            }
            durationLimitTimer = timer
            timer.resume()
        }
    }

    private func stopDurationLimit() {
        durationLimitTimer?.cancel()
        durationLimitTimer = nil
    }

    /// 仅在 `sampleQueue` 上调用；保留首个故障并通知等待方。
    private func recordFailure(
        _ error: RecorderError,
        writerError: Error? = nil
    ) {
        guard failure == nil else { return }
        failure = error
        self.writerError = writerError
        let message = error.localizedDescription
        logger.error("捕获/写盘异常，将停止录制：\(message, privacy: .public)")
        eventContinuation.yield(.failure(error))
    }

    private static func recorderError(from error: Error) -> RecorderError {
        if let recorderError = error as? RecorderError {
            return recorderError
        }
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain, nsError.code == -3_801 {
            return .screenRecordingPermissionDenied
        }
        return .audioCaptureFailed
    }
}
