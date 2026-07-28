import XCTest

@testable import AppAudioRecorder

@MainActor
final class RecorderModelTests: XCTestCase {
    func testSelectedApplicationPersists() {
        let suiteName = "RecorderModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstModel = RecorderModel(defaults: defaults)
        firstModel.selectApplication(bundleIdentifier: "com.example.Audio")
        firstModel.toggleMonitoredApplication(
            bundleIdentifier: "com.example.First"
        )
        firstModel.toggleMonitoredApplication(
            bundleIdentifier: "com.example.Second"
        )

        let restoredModel = RecorderModel(defaults: defaults)
        XCTAssertEqual(
            restoredModel.selectedBundleIdentifier,
            "com.example.Audio"
        )
        XCTAssertEqual(
            restoredModel.monitoredBundleIdentifiers,
            ["com.example.First", "com.example.Second"]
        )
    }

    func testDefaultRecordingConfiguration() {
        let model = RecorderModel()

        XCTAssertEqual(model.recordingConfiguration.sampleRate, .hz48K)
        XCTAssertEqual(model.recordingConfiguration.channelCount, .stereo)
        XCTAssertTrue(model.recordingConfiguration.capturesMicrophone)
        XCTAssertFalse(model.isCallMonitoring)
    }

    func testRecordingConfigurationOffersCommonAudioFormats() {
        XCTAssertEqual(
            RecordingConfiguration.SampleRate.allCases.map(\.rawValue),
            [8_000, 16_000, 24_000, 32_000, 44_100, 48_000]
        )
        XCTAssertEqual(
            RecordingConfiguration.ChannelCount.allCases.map(\.rawValue),
            [1, 2]
        )
    }

    func testPendingPrimaryActionIsImmediatelyActive() async {
        let model = RecorderModel()

        model.triggerPrimaryAction()

        XCTAssertTrue(model.isActive)
        await model.shutdown()
        XCTAssertFalse(model.isActive)
    }

    func testMultipleCallRemindersAreQueuedAndOnlyFireOncePerCall() async {
        let suiteName = "RecorderModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var notificationCount = 0
        let model = RecorderModel(
            defaults: defaults,
            notifyCallDetected: {
                notificationCount += 1
            }
        )
        let firstApplication = CapturableApplication(
            name: "First",
            bundleIdentifier: "com.example.First",
            processID: 1
        )
        let secondApplication = CapturableApplication(
            name: "Second",
            bundleIdentifier: "com.example.Second",
            processID: 2
        )
        model.applications = [firstApplication, secondApplication]
        model.toggleMonitoredApplication(
            bundleIdentifier: firstApplication.bundleIdentifier
        )
        model.toggleMonitoredApplication(
            bundleIdentifier: secondApplication.bundleIdentifier
        )

        model.setCallMonitoringEnabled(true)
        model.handleCallActivity(
            CallActivityEvent(
                bundleIdentifier: firstApplication.bundleIdentifier,
                isActive: true
            )
        )
        model.handleCallActivity(
            CallActivityEvent(
                bundleIdentifier: firstApplication.bundleIdentifier,
                isActive: true
            )
        )
        model.handleCallActivity(
            CallActivityEvent(
                bundleIdentifier: secondApplication.bundleIdentifier,
                isActive: true
            )
        )

        XCTAssertTrue(model.isCallMonitoring)
        XCTAssertFalse(model.isRecording)
        XCTAssertEqual(notificationCount, 1)
        XCTAssertTrue(model.callReminderMessage?.contains("First") == true)

        await model.dismissCallReminder()

        XCTAssertEqual(notificationCount, 2)
        XCTAssertTrue(model.callReminderMessage?.contains("Second") == true)

        model.handleCallActivity(
            CallActivityEvent(
                bundleIdentifier: secondApplication.bundleIdentifier,
                isActive: false
            )
        )
        XCTAssertNil(model.callReminderMessage)

        model.handleCallActivity(
            CallActivityEvent(
                bundleIdentifier: firstApplication.bundleIdentifier,
                isActive: false
            )
        )
        model.handleCallActivity(
            CallActivityEvent(
                bundleIdentifier: firstApplication.bundleIdentifier,
                isActive: true
            )
        )

        XCTAssertEqual(notificationCount, 3)
        model.setCallMonitoringEnabled(false)
        await model.shutdown()
        XCTAssertFalse(model.isActive)
    }

    func testMonitoringSelectionKeepsOnlyOneProcessPerApplicationFamily() {
        let suiteName = "RecorderModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = RecorderModel(defaults: defaults)

        model.toggleMonitoredApplication(
            bundleIdentifier: "org.whispersystems.signal-desktop"
        )
        model.toggleMonitoredApplication(
            bundleIdentifier:
                "org.whispersystems.signal-desktop.helper.Renderer"
        )

        XCTAssertEqual(
            model.monitoredBundleIdentifiers,
            ["org.whispersystems.signal-desktop.helper.Renderer"]
        )
    }

    func testStopRequestedEventAutomaticallyStopsAndSavesOutput() async throws {
        let suiteName = "RecorderModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = ModelRecordingEngine(
            stopResult: RecordingEngineStopResult(
                outputCompleted: true,
                recordedSeconds: 4.5,
                warning: nil
            )
        )
        var startedApplication: CapturableApplication?
        var startedOutputURL: URL?
        var startedConfiguration: RecordingConfiguration?
        let model = RecorderModel(
            defaults: defaults,
            notifyCallDetected: {},
            recordingStarter: { application, outputURL, configuration in
                startedApplication = application
                startedOutputURL = outputURL
                startedConfiguration = configuration
                return RecordingSession(
                    engine: engine,
                    outputURL: outputURL
                )
            }
        )
        model.outputDirectory = directory
        let application = CapturableApplication(
            name: "Meeting",
            bundleIdentifier: "com.example.Meeting",
            processID: 1
        )
        model.applications = [application]
        model.selectApplication(bundleIdentifier: application.bundleIdentifier)

        model.triggerPrimaryAction()
        await waitUntil("录制未进入 recording 状态") {
            model.isRecording && model.canPerformPrimaryAction
        }

        XCTAssertEqual(startedApplication, application)
        XCTAssertEqual(startedConfiguration, RecordingConfiguration())
        XCTAssertEqual(startedOutputURL?.deletingLastPathComponent(), directory)

        // 引擎请求停止（如到达时长上限）应触发既有收尾流程并保存已录内容。
        await engine.emit(.stopRequested)
        await waitUntil("stopRequested 未触发自动停止") {
            !model.isActive
        }

        XCTAssertEqual(model.latestOutputURL, startedOutputURL)
        XCTAssertTrue(model.statusMessage.contains("4.5"))
        let stopCount = await engine.stopCount
        XCTAssertEqual(stopCount, 1)
    }

    func testCaptureFailureAutomaticallyStopsAndPreservesCompletedOutput() async throws {
        let suiteName = "RecorderModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let warning = RecorderError.audioCaptureFailed.localizedDescription
        let engine = ModelRecordingEngine(
            stopResult: RecordingEngineStopResult(
                outputCompleted: true,
                recordedSeconds: 2,
                warning: warning
            )
        )
        let model = RecorderModel(
            defaults: defaults,
            notifyCallDetected: {},
            recordingStarter: { _, outputURL, _ in
                RecordingSession(engine: engine, outputURL: outputURL)
            }
        )
        model.outputDirectory = directory
        let application = CapturableApplication(
            name: "Meeting",
            bundleIdentifier: "com.example.Meeting",
            processID: 1
        )
        model.applications = [application]
        model.selectApplication(bundleIdentifier: application.bundleIdentifier)

        model.triggerPrimaryAction()
        await waitUntil("录制未进入 recording 状态") {
            model.isRecording
        }
        await engine.emit(.failure(.audioCaptureFailed))
        await waitUntil("捕获故障后未自动停止") {
            !model.isActive && model.latestOutputURL != nil
        }

        XCTAssertEqual(model.errorMessage, warning)
        XCTAssertTrue(model.statusMessage.contains("2.0"))
        let stopCount = await engine.stopCount
        XCTAssertEqual(stopCount, 1)
    }

    func testReminderRecordingUsesTriggeredApplicationWithoutChangingManualTarget() async throws {
        let suiteName = "RecorderModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = ModelRecordingEngine(
            stopResult: RecordingEngineStopResult(
                outputCompleted: true,
                recordedSeconds: 1,
                warning: nil
            )
        )
        var startedApplication: CapturableApplication?
        let model = RecorderModel(
            defaults: defaults,
            notifyCallDetected: {},
            recordingStarter: { application, outputURL, _ in
                startedApplication = application
                return RecordingSession(
                    engine: engine,
                    outputURL: outputURL
                )
            }
        )
        model.outputDirectory = directory
        let manualApplication = CapturableApplication(
            name: "Manual",
            bundleIdentifier: "com.example.Manual",
            processID: 1
        )
        let monitoredApplication = CapturableApplication(
            name: "Monitored",
            bundleIdentifier: "com.example.Monitored",
            processID: 2
        )
        model.applications = [manualApplication, monitoredApplication]
        model.selectApplication(
            bundleIdentifier: manualApplication.bundleIdentifier
        )
        model.toggleMonitoredApplication(
            bundleIdentifier: monitoredApplication.bundleIdentifier
        )
        model.setCallMonitoringEnabled(true)
        model.handleCallActivity(
            CallActivityEvent(
                bundleIdentifier: monitoredApplication.bundleIdentifier,
                isActive: true
            )
        )

        model.startRecordingFromReminder()
        await waitUntil("提醒触发的录制未启动") {
            model.isRecording
        }

        XCTAssertEqual(startedApplication, monitoredApplication)
        XCTAssertEqual(
            model.selectedBundleIdentifier,
            manualApplication.bundleIdentifier
        )

        await model.shutdown()
        XCTAssertFalse(model.isActive)
        let stopCount = await engine.stopCount
        XCTAssertEqual(stopCount, 1)
    }

    func testRecordingStartFailureRestoresIdleState() async throws {
        let suiteName = "RecorderModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundleIdentifier = "com.example.Missing"
        let model = RecorderModel(
            defaults: defaults,
            notifyCallDetected: {},
            recordingStarter: { _, _, _ in
                throw RecorderError.applicationNotRunning(
                    bundleIdentifier: bundleIdentifier
                )
            }
        )
        model.outputDirectory = directory
        let application = CapturableApplication(
            name: "Missing",
            bundleIdentifier: bundleIdentifier,
            processID: 1
        )
        model.applications = [application]
        model.selectApplication(bundleIdentifier: bundleIdentifier)

        model.triggerPrimaryAction()
        await waitUntil("启动失败后模型未恢复空闲状态") {
            !model.isActive && model.errorMessage != nil
        }

        XCTAssertEqual(model.statusMessage, "操作失败")
        XCTAssertTrue(model.errorMessage?.contains(bundleIdentifier) == true)
        XCTAssertNil(model.latestOutputURL)
    }

    private func waitUntil(
        _ failureMessage: String,
        condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<200 {
            if condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(failureMessage)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        return directory
    }
}

private actor ModelRecordingEngine: RecordingEngine {
    private let events: AsyncStream<RecordingEngineEvent>
    private let continuation: AsyncStream<RecordingEngineEvent>.Continuation
    private let stopResult: RecordingEngineStopResult
    private(set) var stopCount = 0

    init(stopResult: RecordingEngineStopResult) {
        self.stopResult = stopResult
        (events, continuation) = AsyncStream.makeStream(
            bufferingPolicy: .unbounded
        )
    }

    func eventStream() async -> AsyncStream<RecordingEngineEvent> {
        events
    }

    func emit(_ event: RecordingEngineEvent) {
        continuation.yield(event)
    }

    func stop() async -> RecordingEngineStopResult {
        stopCount += 1
        continuation.finish()
        return stopResult
    }
}
