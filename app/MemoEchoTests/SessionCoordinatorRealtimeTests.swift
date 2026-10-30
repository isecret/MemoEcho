import AVFoundation
import XCTest
@testable import MemoEcho

@MainActor
final class SessionCoordinatorRealtimeTests: XCTestCase {
    func testCancelledMainCaptureAndWaitingMeterCanHandBackToNewMainCaptureWithoutDeadlock() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let meterRecorder = HandoffMeterRecorder()
        let meter = MicrophoneLevelController(recorder: meterRecorder)
        let meterWaiting = CoordinatorRealtimeGate()
        fixture.coordinator.beforeCaptureStart = { await meter.stopAndWait() }
        fixture.coordinator.onFeedbackEvent = { if case .recordingStarted = $0 { meter.stop() } }
        meter.beforeCaptureStart = {
            await meterWaiting.open()
            await fixture.coordinator.waitForCaptureClose()
        }
        fixture.coordinator.startRecording()
        await fixture.recorder.started.wait()
        fixture.recorder.pauseStop = true
        fixture.coordinator.cancel()
        await fixture.recorder.stopEntered.wait()
        meter.start(device: nil, authorize: {})
        await meterWaiting.wait()
        XCTAssertEqual(meterRecorder.starts, 0)
        fixture.coordinator.startRecording()
        XCTAssertFalse(meter.isRunning)
        fixture.recorder.pauseStop = false
        await fixture.recorder.releaseStop.open()
        await waitUntil { fixture.recorder.completedStarts == 2 }
        XCTAssertEqual(fixture.coordinator.state, .recording)
        XCTAssertEqual(meterRecorder.starts, 0, "Cancelled meter startup must not reopen after the main drain")
        XCTAssertEqual(fixture.recorder.stops, 1)
    }

    func testCancelAndRestartWaitForSlowCloseWithoutStoppingNewCapture() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.recorder.pauseStop = true
        fixture.coordinator.startRecording()
        await fixture.recorder.started.wait()
        fixture.recorder.emit(samples: 8_000)
        fixture.coordinator.finishRecording()
        await fixture.recorder.stopEntered.wait()
        fixture.coordinator.cancel()
        XCTAssertEqual(fixture.coordinator.state, .cancelled, "UI cancellation must not await hardware")
        fixture.coordinator.startRecording()
        let openedTooEarly = expectation(description: "No restart before old close")
        openedTooEarly.isInverted = true
        fixture.recorder.onStart = { openedTooEarly.fulfill() }
        await fulfillment(of: [openedTooEarly], timeout: 0.05)
        XCTAssertEqual(fixture.recorder.retainFullAudioArguments.count, 1)
        XCTAssertEqual(fixture.recorder.stops, 1)
        fixture.recorder.onStart = nil
        fixture.recorder.pauseStop = false
        await fixture.recorder.releaseStop.open()
        await waitUntil { fixture.recorder.completedStarts == 2 }
        XCTAssertEqual(fixture.coordinator.state, .recording)
        XCTAssertEqual(fixture.recorder.stops, 1)
        XCTAssertEqual(fixture.driver.pastes, 0)
        XCTAssertEqual(fixture.probe.polishCalls, 0)
    }

    func testMainCaptureWaitsForMeterReleaseAndCancelledWaitNeverOpensCapture() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let entered = CoordinatorRealtimeGate()
        let releaseMeter = CoordinatorRealtimeGate()
        fixture.coordinator.beforeCaptureStart = {
            await entered.open()
            await releaseMeter.wait()
        }
        fixture.coordinator.startRecording()
        await entered.wait()
        XCTAssertTrue(fixture.recorder.retainFullAudioArguments.isEmpty)
        fixture.coordinator.cancel()
        await releaseMeter.open()
        await waitUntil { fixture.recorder.stops == 1 }
        XCTAssertEqual(fixture.coordinator.state, .cancelled)
        XCTAssertTrue(fixture.recorder.retainFullAudioArguments.isEmpty)
        fixture.coordinator.beforeCaptureStart = nil
        fixture.coordinator.startRecording()
        await fixture.recorder.started.wait()
        XCTAssertEqual(fixture.recorder.retainFullAudioArguments.count, 1)
    }

    func testRealtimeRecordingDisablesFullAudioAndShortCaptureNeverConnects() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.coordinator.startRecording()
        await fixture.recorder.started.wait()
        XCTAssertEqual(fixture.recorder.retainFullAudioArguments, [false])
        fixture.recorder.emit(samples: 7_984) // 499 ms
        fixture.coordinator.finishRecording()
        await waitUntil { fixture.coordinator.state == .idle }
        XCTAssertEqual(fixture.coordinator.state, .idle)
        XCTAssertEqual(fixture.recorder.stops, 1)
        XCTAssertEqual(fixture.factory.creationCount, 0)
        XCTAssertEqual(fixture.probe.polishCalls, 0)
        XCTAssertNil(fixture.coordinator.recovery)
        XCTAssertEqual(fixture.driver.pastes, 0)
    }

    func testSendsWhileRecordingAndWaitsForExplicitFinalBeforePolish() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.coordinator.startRecording()
        await fixture.recorder.started.wait()
        fixture.recorder.emit(samples: 8_000)
        await fixture.service.sent.wait()
        XCTAssertEqual(fixture.coordinator.state, .recording)
        XCTAssertEqual(fixture.probe.polishCalls, 0)
        fixture.coordinator.finishRecording()
        await fixture.service.finishEntered.wait()
        XCTAssertEqual(fixture.coordinator.state, .transcribing)
        XCTAssertEqual(fixture.probe.polishCalls, 0)
        XCTAssertEqual(fixture.driver.pastes, 0)
        fixture.service.emitPartial("不能提前润色")
        await fixture.service.releaseFinal.open()
        await waitUntil { fixture.probe.polishCalls == 2 && fixture.coordinator.state == .error }
        XCTAssertEqual(fixture.probe.transcripts, [["合成最终转写"], ["合成最终转写"]])
        XCTAssertEqual(fixture.coordinator.currentError, .llmNetworkFailure(message: "synthetic_polish_failure"))
        XCTAssertEqual(fixture.coordinator.recovery?.stage, .polish)
        XCTAssertTrue(fixture.coordinator.recovery?.pendingSegments.isEmpty == true)
        XCTAssertNil(fixture.coordinator.recovery?.realtimeAudio)
        let sentBytes = await fixture.service.sentByteCount
        XCTAssertEqual(sentBytes, 16_000)
        XCTAssertEqual(fixture.recorder.stops, 1)
        XCTAssertEqual(fixture.driver.pastes, 0)
    }

    func testStopCallbackTailIsFullySentBeforeProtocolFinish() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.coordinator.startRecording()
        await fixture.recorder.started.wait()
        fixture.recorder.emit(samples: 8_000)
        await fixture.service.sent.wait()
        // Model a last callback that completes inside stopRecording, before its
        // return barrier. This checks coordinator ordering, not AVCapture itself.
        fixture.recorder.finalSamplesOnStop = 777
        fixture.coordinator.finishRecording()
        await fixture.service.finishEntered.wait()
        let bytesAtFinish = await fixture.service.bytesAtFinish
        let sentBytes = await fixture.service.sentByteCount
        let lastFrameBytes = await fixture.service.frameByteCounts.last
        XCTAssertEqual(bytesAtFinish, (8_000 + 777) * 2)
        XCTAssertEqual(sentBytes, (8_000 + 777) * 2)
        XCTAssertEqual(lastFrameBytes, 1554)
        XCTAssertEqual(fixture.recorder.stops, 1)
        XCTAssertEqual(fixture.coordinator.state, .transcribing)
        XCTAssertEqual(fixture.probe.polishCalls, 0)
        await fixture.service.releaseFinal.open()
        await waitUntil { fixture.probe.polishCalls == 2 && fixture.coordinator.state == .error }
        XCTAssertEqual(fixture.probe.transcripts, [["合成最终转写"], ["合成最终转写"]])
        XCTAssertEqual(fixture.driver.pastes, 0)
    }

    func testRealtimeFailureKeepsRealtimeRecoveryInsteadOfSealedSegments() async throws {
        let fixture = try makeFixture(sendError: .serviceRejected)
        defer { fixture.cleanup() }
        fixture.coordinator.startRecording()
        await fixture.recorder.started.wait()
        fixture.recorder.emit(samples: 16_000)
        await waitUntil { fixture.coordinator.recovery != nil && fixture.coordinator.state == .error }
        let recovery = try XCTUnwrap(fixture.coordinator.recovery)
        let audio = try XCTUnwrap(recovery.realtimeAudio)
        XCTAssertEqual(fixture.coordinator.state, .error)
        XCTAssertEqual(recovery.stage, .recognition)
        XCTAssertEqual(recovery.asrPlatform, .volcengineRealtime)
        XCTAssertTrue(recovery.pendingSegments.isEmpty)
        XCTAssertTrue(recovery.transcripts.isEmpty)
        XCTAssertTrue(recovery.isPartialRecording)
        XCTAssertEqual(audio.processedPCM.count + audio.rawPCM.count, 32_000)
        XCTAssertEqual(fixture.recorder.stops, 1)
        XCTAssertEqual(fixture.probe.polishCalls, 0)
        XCTAssertEqual(fixture.driver.pastes, 0)
        XCTAssertNil(fixture.coordinator.lastResult)
    }

    func testRealtimeDisconnectAutomaticallyReplaysUnconfirmedAudioOnce() async throws {
        let fixture = try makeFixture(sendError: .connectionClosed)
        defer { fixture.cleanup() }
        var failedEvents = 0
        fixture.coordinator.onFeedbackEvent = { if case .processingFailed = $0 { failedEvents += 1 } }
        fixture.coordinator.startRecording()
        await fixture.recorder.started.wait()
        fixture.recorder.emit(samples: 16_000)
        await waitUntil { fixture.recorder.stops == 1 }
        XCTAssertEqual(fixture.coordinator.state, .transcribing)
        XCTAssertNil(fixture.coordinator.currentError)
        XCTAssertEqual(failedEvents, 0)
        await waitUntil { fixture.coordinator.state == .error }
        XCTAssertEqual(fixture.probe.replayCalls, 1)
        let audio = try XCTUnwrap(fixture.probe.replayedAudio)
        XCTAssertEqual(audio.processedPCM.count + audio.rawPCM.count, 32_000)
        XCTAssertEqual(fixture.probe.transcripts, [["合成恢复转写"], ["合成恢复转写"]])
        XCTAssertEqual(fixture.coordinator.recovery?.stage, .polish)
        XCTAssertNil(fixture.coordinator.recovery?.realtimeAudio)
        XCTAssertEqual(failedEvents, 1, "Only the exhausted LLM stage reports a failure")
        XCTAssertEqual(fixture.recorder.retainFullAudioArguments.count, 1)
        XCTAssertEqual(fixture.driver.pastes, 0)
    }

    func testSecondRealtimeFailureOffersManualRecoveryWithoutThirdAttempt() async throws {
        let fixture = try makeFixture(sendError: .connectionClosed, replayError: .connectionClosed)
        defer { fixture.cleanup() }
        fixture.coordinator.startRecording()
        await fixture.recorder.started.wait()
        fixture.recorder.emit(samples: 16_000)
        await waitUntil { fixture.coordinator.state == .error }
        XCTAssertEqual(fixture.probe.replayCalls, 1)
        XCTAssertEqual(fixture.probe.polishCalls, 0)
        XCTAssertEqual(fixture.recorder.stops, 1)
        XCTAssertEqual(fixture.coordinator.recovery?.stage, .recognition)
        XCTAssertNotNil(fixture.coordinator.recovery?.realtimeAudio)
        XCTAssertTrue(fixture.coordinator.canRetryRecovery)
        XCTAssertEqual(fixture.driver.pastes, 0)
    }

    func testCancelDuringRealtimeRetryDelayNeverReplaysOrPublishesRecovery() async throws {
        let fixture = try makeFixture(sendError: .connectionClosed)
        defer { fixture.cleanup() }
        fixture.coordinator.startRecording()
        await fixture.recorder.started.wait()
        fixture.recorder.emit(samples: 16_000)
        await waitUntil { fixture.recorder.stops == 1 }
        fixture.coordinator.cancel()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(fixture.probe.replayCalls, 0)
        XCTAssertEqual(fixture.probe.polishCalls, 0)
        XCTAssertNil(fixture.coordinator.recovery)
        XCTAssertEqual(fixture.coordinator.state, .cancelled)
    }

    func testCancelIgnoresLateFinalWithoutPolishOrInjection() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.coordinator.startRecording()
        await fixture.recorder.started.wait()
        fixture.recorder.emit(samples: 8_000)
        await fixture.service.sent.wait()
        fixture.coordinator.finishRecording()
        await fixture.service.finishEntered.wait()
        fixture.coordinator.cancel()
        await fixture.service.cancelEntered.wait()
        // The fake deliberately returns a successful final after cancel. Generation
        // guards must reject it even when the provider ignores task cancellation.
        await fixture.service.releaseFinal.open()
        await fixture.service.finishReturned.wait()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(fixture.coordinator.state, .cancelled)
        XCTAssertEqual(fixture.probe.polishCalls, 0)
        XCTAssertNil(fixture.coordinator.recovery)
        XCTAssertNil(fixture.coordinator.lastResult)
        XCTAssertNil(fixture.coordinator.lastInjectionFailureText)
        XCTAssertEqual(fixture.driver.pastes, 0)
    }

    func testReleaseBeforeAsynchronousCaptureStartsLeavesNoRecordingOrRequests() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.coordinator.startRecording()
        XCTAssertEqual(fixture.coordinator.state, .recording)
        fixture.coordinator.finishRecording()
        await waitUntil { fixture.coordinator.state == .idle }
        XCTAssertEqual(fixture.coordinator.state, .idle)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(fixture.recorder.retainFullAudioArguments.isEmpty)
        XCTAssertEqual(fixture.factory.creationCount, 0)
        XCTAssertEqual(fixture.probe.polishCalls, 0)
        XCTAssertEqual(fixture.driver.pastes, 0)
        XCTAssertNil(fixture.coordinator.recovery)
    }

    func testReleaseDuringCaptureStartupCancelsPendingStartAndIgnoresLateReturn() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.recorder.pauseStartup = true
        fixture.coordinator.startRecording()
        await fixture.recorder.started.wait()
        fixture.coordinator.finishRecording()
        await waitUntil { fixture.coordinator.state == .idle }
        XCTAssertEqual(fixture.coordinator.state, .idle)
        await fixture.recorder.releaseStartup.open()
        await fixture.recorder.startReturned.wait()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(fixture.recorder.completedStarts, 0)
        XCTAssertEqual(fixture.coordinator.state, .idle)
        XCTAssertEqual(fixture.factory.creationCount, 0)
        XCTAssertEqual(fixture.probe.polishCalls, 0)
        XCTAssertEqual(fixture.driver.pastes, 0)
        XCTAssertNil(fixture.coordinator.currentError)
    }

    func testHoldReleaseUsesExistingFiveHundredMillisecondSubmissionBoundary() async throws {
        for samples in [7_984, 8_000] {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }
            fixture.recorder.pauseStartup = true
            let manager = HotkeyManager()
            manager.testInstallHandler = { _ in .success }
            _ = manager.register(hotkey: .default.withTriggerMode(.hold))
            let binding = CoordinatorHoldBinding(coordinator: fixture.coordinator)
            manager.onGestureAction = { binding.handle($0) }
            manager.consumeEvent(.modifiersChanged([.rightCommand]), at: 0)
            await fixture.recorder.started.wait()
            fixture.recorder.emit(samples: samples)
            manager.consumeEvent(.modifiersChanged([]), at: 1)
            await fixture.recorder.releaseStartup.open()
            if samples < 8_000 {
                await waitUntil { fixture.coordinator.state == .idle }
                XCTAssertEqual(fixture.coordinator.state, .idle)
                XCTAssertEqual(fixture.factory.creationCount, 0)
            } else {
                await fixture.service.finishEntered.wait()
                XCTAssertEqual(fixture.coordinator.state, .transcribing)
            }
            XCTAssertEqual(fixture.probe.polishCalls, 0)
            XCTAssertEqual(fixture.driver.pastes, 0)
            fixture.coordinator.cancel()
            await fixture.service.releaseFinal.open()
        }
    }

    func testRecordingFreezesDictionaryBeforeAsyncStartupAndNextRecordingRefreshesIt() async throws {
        for platform in [ASRPlatform.volcengineRealtime, .aliyunBailianASR, .tencentCloudRealtime] {
            let fixture = try makeFixture(platform: platform)
            defer { fixture.cleanup() }
            try fixture.dictionary.addEntry(.init(term: "MemoEcho", pronunciationHint: "must-not-send"))
            fixture.coordinator.startRecording()
            // No await: update before beginRecording's delayed task starts.
            try fixture.dictionary.addEntry(.init(term: "新词"))
            await fixture.recorder.started.wait()
            fixture.recorder.emit(samples: 8_000)
            await fixture.service.sent.wait()
            XCTAssertEqual(fixture.factory.snapshots.first?.terms, ["MemoEcho"])
            fixture.coordinator.finishRecording()
            await fixture.service.finishEntered.wait()
            await fixture.service.releaseFinal.open()
            await waitUntil { fixture.coordinator.recovery != nil }
            XCTAssertEqual(fixture.coordinator.recovery?.hotwords.terms, ["MemoEcho"])
            fixture.coordinator.startRecording()
            await waitUntil { fixture.recorder.completedStarts == 2 }
            fixture.recorder.emit(samples: 8_000)
            await waitUntil { fixture.factory.creationCount >= 2 }
            XCTAssertEqual(fixture.factory.snapshots.last?.terms, ["MemoEcho", "新词"])
        }
    }

    private func makeFixture(sendError: RealtimeASRError? = nil, platform: ASRPlatform = .volcengineRealtime,
                             replayError: RealtimeASRError? = nil) throws -> CoordinatorRealtimeFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ConfigStore(configDirectory: directory)
        var config = ASRConfig()
        config.selectedPlatform = platform
        config.aliyunBailian = .init(apiKey: "synthetic", model: "qwen-audio-3.1-asr-flash-streaming")
        config.tencentCloud.appID = "123"
        config.tencentCloud.secretId = "synthetic"
        config.tencentCloud.secretKey = "synthetic"
        config.volcengine.apiKey = "synthetic-test-key"
        try store.saveASRConfig(config)
        try store.updateCloudValidationState(for: platform, status: .verified)
        try store.saveWindowContextEnabled(false)
        let dictionary = PersonalDictionaryStore(directoryURL: directory)
        let recorder = CoordinatorRealtimeRecorder()
        let service = CoordinatorRealtimeSession(sendError: sendError)
        let factory = CoordinatorRealtimeFactory(session: service)
        let probe = CoordinatorRealtimeProbe()
        let driver = FakeInjectionDriver()
        let worker = SessionRecoveryProcessor(recognize: { _ in
            XCTFail("Realtime capture must not enter sealed-segment recognition")
            throw MemoEchoError.cloudASRInvalidResponse(detail: "synthetic_wrong_path")
        }, polish: { transcripts, _ in
            probe.polishCalls += 1
            probe.transcripts.append(transcripts)
            throw MemoEchoError.llmNetworkFailure(message: "synthetic_polish_failure")
        }, translate: { _, _, _ in
            XCTFail("Synthetic polish failure cannot reach translation")
            throw MemoEchoError.llmEmptyResponse
        }, recognizeRealtime: { audio in
            probe.replayCalls += 1
            probe.replayedAudio = audio
            if let replayError { throw replayError }
            return ["合成恢复转写"]
        })
        let coordinator = SessionCoordinator(permissionsManager: PermissionsManager(), configStore: store,
            audioDeviceManager: AudioDeviceManager(configStore: store), audioRecorder: recorder, dictionaryStore: dictionary,
            ensureMicrophoneAuthorized: {}, ensureAccessibilityAuthorized: {},
            textInjector: TextInjector(driver: driver), recoveryProcessorFactory: { _ in worker },
            realtimeSessionFactory: { config, hotwords in
                guard config.selectedPlatform == platform else { throw RealtimeASRError.configuration }
                return factory.makeSession(hotwords: hotwords)
            })
        return .init(coordinator: coordinator, recorder: recorder, service: service, factory: factory,
                     probe: probe, driver: driver, directory: directory, dictionary: dictionary)
    }

    private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for the synthetic coordinator transition")
    }
}

@MainActor
private struct CoordinatorRealtimeFixture {
    let coordinator: SessionCoordinator
    let recorder: CoordinatorRealtimeRecorder
    let service: CoordinatorRealtimeSession
    let factory: CoordinatorRealtimeFactory
    let probe: CoordinatorRealtimeProbe
    let driver: FakeInjectionDriver
    let directory: URL
    let dictionary: PersonalDictionaryStore

    func cleanup() {
        coordinator.cancel()
        coordinator.discardRecovery()
        Task { await service.releaseFinal.open() }
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class CoordinatorRealtimeProbe {
    var polishCalls = 0
    var transcripts: [[String]] = []
    var replayCalls = 0
    var replayedAudio: RealtimeRecoveryAudio?
}

@MainActor
private final class HandoffMeterRecorder: AudioRecording {
    var onCaptureEvent: (@MainActor @Sendable (AudioCaptureEvent) -> Void)?
    var currentDurationMs: Int { 0 }
    var starts = 0
    func startRecording(device: AVCaptureDevice?, onPCMChunk: (@Sendable (Data) -> Void)?) async throws { starts += 1 }
    func stopRecording() async -> AudioRecordingResult { .init(data: Data(), durationMs: 0) }
    func currentLevel() -> Float { 0 }
}

@MainActor
private final class CoordinatorRealtimeRecorder: AudioRecording {
    var onCaptureEvent: (@MainActor @Sendable (AudioCaptureEvent) -> Void)?
    let started = CoordinatorRealtimeGate()
    let releaseStartup = CoordinatorRealtimeGate()
    let startReturned = CoordinatorRealtimeGate()
    let stopEntered = CoordinatorRealtimeGate()
    let releaseStop = CoordinatorRealtimeGate()
    var pauseStop = false
    var onStart: (() -> Void)?
    var pauseStartup = false
    private(set) var completedStarts = 0
    private var callback: (@Sendable (Data) -> Void)?
    private var sampleCount = 0
    private(set) var retainFullAudioArguments: [Bool] = []
    private(set) var stops = 0
    var finalSamplesOnStop = 0
    var currentDurationMs: Int { sampleCount * 1000 / 16_000 }

    func startRecording(device: AVCaptureDevice?, onPCMChunk: (@Sendable (Data) -> Void)?) async throws {
        XCTFail("Coordinator must call the overload that selects audio retention")
        try await startRecording(device: device, retainFullAudio: true, onPCMChunk: onPCMChunk)
    }
    func startRecording(device: AVCaptureDevice?, retainFullAudio: Bool,
                        onPCMChunk: (@Sendable (Data) -> Void)?) async throws {
        retainFullAudioArguments.append(retainFullAudio)
        sampleCount = 0
        onStart?()
        callback = onPCMChunk
        await started.open()
        if pauseStartup { await releaseStartup.wait() }
        do {
            try Task.checkCancellation()
            completedStarts += 1
            await startReturned.open()
        } catch {
            await startReturned.open()
            throw error
        }
    }
    func emit(samples: Int) {
        sampleCount += samples
        callback?(Data(Array(repeating: [UInt8(100), 0], count: samples).joined()))
    }
    func stopRecording() async -> AudioRecordingResult {
        stops += 1
        await stopEntered.open()
        if pauseStop { await releaseStop.wait() }
        let tail = finalSamplesOnStop
        finalSamplesOnStop = 0
        if tail > 0 { emit(samples: tail) }
        callback = nil
        return .init(data: Data(), durationMs: currentDurationMs, sampleCount: sampleCount)
    }
    func currentLevel() -> Float { 0 }
}

private actor CoordinatorRealtimeGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor CoordinatorRealtimeSession: RealtimeASRSession {
    nonisolated let capabilities = RealtimeASRCapabilities(preferredFrameBytes: 3200,
        requiresRealtimePacing: false, maximumSessionSeconds: 90)
    nonisolated let events: AsyncThrowingStream<RealtimeASREvent, Error>
    private nonisolated let continuation: AsyncThrowingStream<RealtimeASREvent, Error>.Continuation
    nonisolated let sent = CoordinatorRealtimeGate()
    nonisolated let finishEntered = CoordinatorRealtimeGate()
    nonisolated let releaseFinal = CoordinatorRealtimeGate()
    nonisolated let finishReturned = CoordinatorRealtimeGate()
    nonisolated let cancelEntered = CoordinatorRealtimeGate()
    private let sendError: RealtimeASRError?
    private(set) var sentByteCount = 0
    private(set) var frameByteCounts: [Int] = []
    private(set) var bytesAtFinish: Int?

    init(sendError: RealtimeASRError?) {
        self.sendError = sendError
        (events, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }
    func connect() async throws {}
    func send(_ pcm: Data) async throws {
        await sent.open()
        if let sendError { throw sendError }
        sentByteCount += pcm.count
        frameByteCounts.append(pcm.count)
    }
    func finish() async throws -> String {
        bytesAtFinish = sentByteCount
        await finishEntered.open()
        await releaseFinal.wait()
        await finishReturned.open()
        return "合成最终转写"
    }
    func cancel() async {
        continuation.finish()
        await cancelEntered.open()
    }
    nonisolated func emitPartial(_ text: String) { continuation.yield(.partial(text: text)) }
}

private final class CoordinatorRealtimeFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var captured: [ASRHotwords] = []
    var snapshots: [ASRHotwords] { lock.withLock { captured } }
    private let session: CoordinatorRealtimeSession
    init(session: CoordinatorRealtimeSession) { self.session = session }
    var creationCount: Int { lock.withLock { count } }
    func makeSession(hotwords: ASRHotwords) -> any RealtimeASRSession {
        lock.withLock { count += 1; captured.append(hotwords) }
        return session
    }
}

@MainActor
private final class CoordinatorHoldBinding {
    let coordinator: SessionCoordinator
    private var ownership = HoldHotkeyInteraction()
    init(coordinator: SessionCoordinator) { self.coordinator = coordinator }
    func handle(_ action: HotkeyGestureAction) {
        switch action {
        case .holdBegan(let id):
            guard coordinator.state.allowsRecordingStart else { return }
            coordinator.startRecording()
            if coordinator.state == .recording { ownership.began(gesture: id, session: coordinator.currentSessionID) }
        case .holdEnded(let id), .holdCancelled(let id):
            if ownership.consume(gesture: id, session: coordinator.currentSessionID, state: coordinator.state) {
                if case .holdEnded = action { coordinator.finishRecording() }
                else { coordinator.cancel() }
            }
        case .toggle: break
        }
    }
}
