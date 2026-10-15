import AVFoundation
import XCTest
@testable import MemoEcho

@MainActor
final class PipelineTimingTests: XCTestCase {
    func testRealtimeAndSegmentedUseStopOriginWithoutRecordingDuration() async throws {
        for realtime in [false, true] {
            let timer = ManualPipelineClock()
            let fixture = try fixture(timer: timer, realtime: realtime)
            defer { fixture.cleanup() }
            fixture.coordinator.startRecording(output: .onboardingTrial { _ in true })
            await waitUntil { fixture.recorder.starts == 1 }
            timer.advance(milliseconds: 10_000) // Time spent recording is outside the stop-to-result measurement.
            fixture.coordinator.finishRecording()
            await waitUntil { fixture.coordinator.state == .done }
            let metrics = try XCTUnwrap(fixture.coordinator.lastLatencyDiagnostics)
            XCTAssertEqual(metrics.origin, .recordingStop)
            XCTAssertEqual(metrics.path, realtime ? .realtime : .segmented)
            XCTAssertEqual(metrics.captureClosedMs, 120)
            XCTAssertEqual(metrics.asrFinalMs, 400)
            XCTAssertEqual(metrics.asrWaitMs, 280)
            XCTAssertEqual(metrics.contextWaitMs, 0)
            XCTAssertEqual(metrics.contextReadyMs, 0)
            XCTAssertEqual(metrics.llmCompleteMs, 700)
            XCTAssertEqual(metrics.dispatchMs, 700)
            XCTAssertEqual(metrics.elapsedMs, 700)
        }
    }

    func testWaitingForContextDoesNotIncreaseASRLatency() async throws {
        let timer = ManualPipelineClock()
        let contextGate = TimingGate()
        let context = WindowContextService(candidateProvider: { _, _, _, phase in
            if phase == .extended { await contextGate.wait() }
            return .init(appName: "synthetic", visibleText: "synthetic")
        })
        let fixture = try fixture(timer: timer, realtime: true, context: context, contextEnabled: true)
        defer { fixture.cleanup() }
        fixture.coordinator.onLatencyMilestone = { _, milestone, snapshot in
            if milestone == .asrFinal {
                XCTAssertEqual(snapshot.asrFinalMs, 400)
                XCTAssertNil(snapshot.contextReadyMs)
                Task {
                    await Task.yield()
                    timer.advance(milliseconds: 300)
                    await contextGate.open()
                }
            }
        }
        // The focused-app path starts the independent context task. Output can fail after timing is recorded.
        fixture.coordinator.startRecording()
        await waitUntil { fixture.recorder.starts == 1 }
        timer.advance(milliseconds: 10_000)
        fixture.coordinator.finishRecording()
        await waitUntil { fixture.coordinator.lastLatencyDiagnostics?.llmCompleteMs != nil }
        let metrics = try XCTUnwrap(fixture.coordinator.lastLatencyDiagnostics)
        XCTAssertEqual(metrics.asrFinalMs, 400)
        XCTAssertEqual(metrics.asrWaitMs, 280)
        XCTAssertEqual(metrics.contextReadyMs, 700)
        XCTAssertEqual(metrics.contextWaitMs, 300)
        XCTAssertEqual(metrics.llmCompleteMs, 1_000)
    }

    func testRecoveryStartsFreshAndCachedStagesRemainAbsent() async throws {
        let timer = ManualPipelineClock()
        let fixture = try fixture(timer: timer, realtime: false)
        defer { fixture.cleanup() }
        fixture.coordinator.startRecording(output: .onboardingTrial { _ in true })
        await waitUntil { fixture.recorder.starts == 1 }
        fixture.coordinator.finishRecording()
        await waitUntil { fixture.coordinator.state == .done }
        let checkpoint = SessionRecoveryCheckpoint(transcripts: [], mode: .polish, language: .english,
            asrPlatform: .openAICompatibleASR, target: fixture.driver.current, context: nil)
        checkpoint.polished = .init(text: "synthetic", source: .llm,
            structured: .init(mode: .plainText, intro: nil, items: nil, outro: nil, correctionApplied: false))
        checkpoint.finalText = "synthetic"
        fixture.coordinator.retainRecovery(checkpoint)
        timer.advance(milliseconds: 50_000)
        var events: [(SessionLatencyTimeline.Milestone, SessionLatencySnapshot)] = []
        fixture.coordinator.onLatencyMilestone = { _, milestone, snapshot in events.append((milestone, snapshot)) }
        fixture.driver.onWait = { tick in timer.advance(milliseconds: tick == 1 ? 30 : 500) }
        fixture.coordinator.retryRecovery()
        await waitUntil { fixture.coordinator.state == .done && !fixture.coordinator.isRecovering }
        let metrics = try XCTUnwrap(fixture.coordinator.lastLatencyDiagnostics)
        XCTAssertEqual(metrics.origin, .recoveryAttempt)
        XCTAssertEqual(metrics.path, .recovery)
        XCTAssertNil(metrics.captureClosedMs)
        XCTAssertNil(metrics.asrFinalMs)
        XCTAssertNil(metrics.llmCompleteMs)
        XCTAssertEqual(metrics.dispatchMs, 30)
        XCTAssertEqual(metrics.cleanupCompleteMs, 530)
        XCTAssertEqual(metrics.dispatchToCleanupMs, 500)
        let dispatch = try XCTUnwrap(events.first { $0.0 == .dispatched }?.1)
        XCTAssertNil(dispatch.cleanupCompleteMs)
        XCTAssertEqual(fixture.driver.pastes, 1)
    }

    func testLateCleanupRemainsOnOldAttemptAfterCancelAndRestart() async throws {
        let timer = ManualPipelineClock()
        let fixture = try fixture(timer: timer, realtime: false)
        defer { fixture.cleanup() }
        let cleanupGate = TimingGate()
        var events: [(String, SessionLatencyTimeline.Milestone, SessionLatencySnapshot)] = []
        fixture.coordinator.onLatencyMilestone = { id, milestone, snapshot in
            events.append((id, milestone, snapshot))
        }
        fixture.driver.onWait = { tick in if tick == 1 { timer.advance(milliseconds: 30) } }
        fixture.driver.onAsyncWait = { tick in if tick == 2 { await cleanupGate.wait() } }
        let checkpoint = SessionRecoveryCheckpoint(transcripts: [], mode: .polish, language: .english,
            asrPlatform: .openAICompatibleASR, target: fixture.driver.current, context: nil)
        checkpoint.polished = .init(text: "synthetic", source: .llm,
            structured: .init(mode: .plainText, intro: nil, items: nil, outro: nil, correctionApplied: false))
        checkpoint.finalText = "synthetic"
        fixture.coordinator.retainRecovery(checkpoint)
        fixture.coordinator.retryRecovery()
        await waitUntil { fixture.driver.waits == 2 }
        let oldID = try XCTUnwrap(events.first { $0.1 == .dispatched }?.0)
        XCTAssertEqual(fixture.driver.pastes, 1)
        XCTAssertFalse(events.contains { $0.1 == .cleanupComplete })

        fixture.coordinator.cancel()
        fixture.coordinator.startRecording(output: .onboardingTrial { _ in true })
        XCTAssertNil(fixture.coordinator.lastLatencyDiagnostics)
        await waitUntil { fixture.recorder.starts == 1 }
        fixture.coordinator.finishRecording()
        await waitUntil { fixture.coordinator.state == .done }
        let currentMetrics = try XCTUnwrap(fixture.coordinator.lastLatencyDiagnostics)
        let newID = try XCTUnwrap(events.last { $0.1 == .dispatched }?.0)
        XCTAssertNotEqual(oldID, newID)
        XCTAssertEqual(currentMetrics.origin, .recordingStop)

        timer.advance(milliseconds: 500)
        await cleanupGate.open()
        await waitUntil { events.contains { $0.0 == oldID && $0.1 == .cleanupComplete } }
        XCTAssertEqual(events.last?.0, oldID)
        XCTAssertEqual(events.last?.2.origin, .recoveryAttempt)
        XCTAssertEqual(fixture.coordinator.lastLatencyDiagnostics, currentMetrics)
        XCTAssertEqual(fixture.coordinator.state, .done)
        XCTAssertEqual(fixture.driver.pastes, 1)
        XCTAssertEqual(fixture.driver.board.restores, 1)
    }

    func testTimelinePreservesPreStopContextAndFirstDispatch() {
        let timer = ManualPipelineClock()
        let beforeStop = timer.clock.now()
        timer.advance(milliseconds: 5_000)
        let timeline = SessionLatencyTimeline(origin: .recordingStop, path: .realtime, startedAt: timer.clock.now())
        timeline.mark(.contextReady, at: beforeStop)
        timer.advance(milliseconds: 200)
        timeline.mark(.dispatched, at: timer.clock.now())
        timer.advance(milliseconds: 500)
        timeline.mark(.dispatched, at: timer.clock.now())
        timeline.mark(.cleanupComplete, at: timer.clock.now())
        let metrics = timeline.snapshot(at: timer.clock.now())
        XCTAssertEqual(metrics.contextReadyMs, 0)
        XCTAssertEqual(metrics.dispatchMs, 200)
        XCTAssertEqual(metrics.cleanupCompleteMs, 700)
    }

    private func fixture(timer: ManualPipelineClock, realtime: Bool,
                         context: WindowContextService = WindowContextService(),
                         contextEnabled: Bool = false) throws -> TimingFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ConfigStore(configDirectory: directory)
        var config = ASRConfig()
        config.selectedPlatform = realtime ? .volcengineRealtime : .openAICompatibleASR
        config.volcengine.apiKey = "synthetic"
        config.openAICompatible = .init(baseURL: "https://example.invalid", apiKey: "synthetic", model: "synthetic")
        try store.saveASRConfig(config)
        try store.updateCloudValidationState(for: config.selectedPlatform, status: .verified)
        try store.saveWindowContextEnabled(contextEnabled)
        let recorder = TimingRecorder(timer: timer)
        let driver = FakeInjectionDriver()
        let worker = SessionRecoveryProcessor(recognize: { _ in "synthetic" }, polish: { _, _ in
            timer.advance(milliseconds: 300)
            return .init(text: "synthetic", source: .llm,
            structured: .init(mode: .plainText, intro: nil, items: nil, outro: nil, correctionApplied: false))
        }, translate: { text, _, _ in text })
        let coordinator = SessionCoordinator(permissionsManager: PermissionsManager(), configStore: store,
            audioDeviceManager: AudioDeviceManager(configStore: store), audioRecorder: recorder,
            ensureMicrophoneAuthorized: {}, ensureAccessibilityAuthorized: {},
            textInjector: TextInjector(driver: driver, clock: timer.clock), recoveryProcessorFactory: { _ in worker },
            asrProviderOverride: { _, _ in TimingASR(timer: timer) },
            realtimeSessionFactory: { _, _ in TimingRealtimeASR(timer: timer) },
            clock: timer.clock, windowContextService: context)
        return .init(coordinator: coordinator, recorder: recorder, driver: driver, directory: directory)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), .now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(condition())
    }
}

final class ManualPipelineClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    var clock: PipelineClock { PipelineClock(now: { self.lock.withLock { self.instant } }) }
    func advance(milliseconds: Int) { lock.withLock { instant = instant.advanced(by: .milliseconds(milliseconds)) } }
}

@MainActor
private struct TimingFixture {
    let coordinator: SessionCoordinator
    let recorder: TimingRecorder
    let driver: FakeInjectionDriver
    let directory: URL
    func cleanup() { coordinator.cancel(); coordinator.discardRecovery(); try? FileManager.default.removeItem(at: directory) }
}

@MainActor
private final class TimingRecorder: AudioRecording {
    let timer: ManualPipelineClock
    var onCaptureEvent: (@MainActor @Sendable (AudioCaptureEvent) -> Void)?
    var starts = 0
    var currentDurationMs: Int { starts > 0 ? 1_000 : 0 }
    init(timer: ManualPipelineClock) { self.timer = timer }
    func startRecording(device: AVCaptureDevice?, onPCMChunk: (@Sendable (Data) -> Void)?) async throws {
        starts += 1
        let samples = (0..<16_000).map { Int16(sin(Double($0) * 0.17) * 12_000) }
        onPCMChunk?(samples.withUnsafeBytes { Data($0) })
    }
    func stopRecording() async -> AudioRecordingResult {
        timer.advance(milliseconds: 120)
        return .init(data: Data([1, 2]), durationMs: 1_000)
    }
    func currentLevel() -> Float { 0 }
}

private struct TimingASR: ASRProvider {
    let timer: ManualPipelineClock
    func recognize(audioData: Data, timeout: TimeInterval?) async throws -> TranscriptResult {
        timer.advance(milliseconds: 280)
        return .init(text: "synthetic", requestId: nil, durationMs: 280)
    }
}

private actor TimingRealtimeASR: RealtimeASRSession {
    let timer: ManualPipelineClock
    nonisolated let capabilities = RealtimeASRCapabilities(preferredFrameBytes: 3200,
        requiresRealtimePacing: false, maximumSessionSeconds: 90)
    nonisolated let events: AsyncThrowingStream<RealtimeASREvent, Error>
    private nonisolated let continuation: AsyncThrowingStream<RealtimeASREvent, Error>.Continuation
    init(timer: ManualPipelineClock) {
        self.timer = timer
        (events, continuation) = AsyncThrowingStream.makeStream()
    }
    func connect() async throws {}
    func send(_ pcm: Data) async throws {}
    func finish() async throws -> String { timer.advance(milliseconds: 280); continuation.finish(); return "synthetic" }
    func cancel() async { continuation.finish() }
}

private actor TimingGate {
    private var openState = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !openState { await withCheckedContinuation { waiters.append($0) } } }
    func open() { openState = true; let pending = waiters; waiters.removeAll(); pending.forEach { $0.resume() } }
}
