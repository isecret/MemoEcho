import Foundation
import XCTest
@testable import MemoEcho

/// Exercises the real recovery processor and service callbacks without recording or network traffic.
@MainActor
final class ServiceRecoveryIntegrationTests: XCTestCase {
    func testConfirmedServiceBlockerRoutesNetworkFailureToSettingsUntilServiceRecovers() {
        let ready = VoiceInputReadiness(hotkey: .ready, microphone: .ready, accessibility: .ready,
                                        asr: .ready, llm: .ready)
        for tab: SettingsTab in [.asr, .ai] {
            let segments: [SealedSegment] = tab == .asr
                ? [.init(index: 0, pcmData: Data([0, 1]), sampleCount: 1,
                         sealReason: .finalize, voicedDetected: true)] : []
            let checkpoint = SessionRecoveryCheckpoint(segments: segments, transcripts: ["合成原文"],
                mode: .polish, language: .english, asrPlatform: .openAICompatibleASR, target: nil, context: nil)
            checkpoint.failure = tab == .asr ? .cloudASRNetworkFailure(message: "合成网络失败")
                : .llmNetworkFailure(message: "合成网络失败")
            var blocked = ready
            if tab == .asr { blocked.asr = .blocked("服务测试确认配置错误") }
            else { blocked.llm = .blocked("服务测试确认配置错误") }

            let unavailable = RecoveryPresentation(checkpoint: checkpoint, readiness: blocked,
                                                   confirmedServiceBlocker: tab)
            XCTAssertEqual(unavailable.settingsTab, tab)
            XCTAssertNil(unavailable.retryTitle)
            XCTAssertNil(unavailable.hudRetryTitle)

            let recovered = RecoveryPresentation(checkpoint: checkpoint, readiness: ready)
            XCTAssertNil(recovered.settingsTab)
            XCTAssertEqual(recovered.retryTitle, tab == .asr ? "重试识别" : "重试整理")
            XCTAssertEqual(recovered.hudRetryTitle, "重试")
        }
    }

    func testRecoveryPreemptsInitialValidationAndWaitsForItsPhysicalClose() async throws {
        let gate = IntegrationProbeGate()
        let fixture = try IntegrationFixture(probeGate: gate)
        defer { fixture.cleanup() }
        fixture.cloud.validate(fixture.input)
        await waitUntil { await fixture.probe.calls == 1 }
        var waiting = false
        fixture.session.beforeServiceRequest = { stage in
            guard stage == .recognition else { return }
            waiting = true
            await fixture.cloud.waitForProbeClose()
        }
        fixture.session.retainRecovery(fixture.checkpoint())
        fixture.session.retryRecovery()
        await waitUntil { waiting }
        let beforeClose = await fixture.business.calls
        XCTAssertEqual(beforeClose, 0)
        XCTAssertFalse(fixture.cloud.canRetry(fixture.input))
        fixture.cloud.validate(fixture.input)
        fixture.cloud.retry(fixture.input)

        await gate.open()
        await waitUntil { fixture.session.state == .error && !fixture.session.isRecovering }
        let cancellationObserved = await fixture.probe.cancellationObserved
        let validationCalls = await fixture.probe.calls
        let businessCalls = await fixture.business.calls
        XCTAssertTrue(cancellationObserved)
        XCTAssertEqual(validationCalls, 1)
        XCTAssertEqual(businessCalls, 1)
        XCTAssertEqual(fixture.cloud.status(for: fixture.input), .ready)
        XCTAssertEqual(fixture.session.currentError, .llmConfigurationIncomplete)
    }

    func testRecoveryWaitsForIndependentProbeTeardownBeforeSubmittingAudio() async throws {
        let gate = IntegrationProbeGate()
        let fixture = try IntegrationFixture(probeGate: gate)
        defer { fixture.cleanup() }
        fixture.cloud.recordSuccess(fixture.input)
        fixture.cloud.reportRuntimeFailure(fixture.input)
        await waitUntil { await fixture.probe.calls == 1 }
        var reachedServiceWait = false
        fixture.session.beforeServiceRequest = { stage in
            if stage == .recognition {
                reachedServiceWait = true
                await fixture.cloud.waitForProbeClose()
            }
        }
        let checkpoint = fixture.checkpoint()
        fixture.session.retainRecovery(checkpoint)
        fixture.session.retryRecovery()
        await waitUntil { reachedServiceWait }

        let beforeClose = await fixture.business.calls
        XCTAssertEqual(beforeClose, 0)
        XCTAssertTrue(fixture.cloud.health.businessActive)
        XCTAssertTrue(fixture.session.isRecovering)
        await gate.open()
        await waitUntil { fixture.session.state == .error && !fixture.session.isRecovering }

        let afterClose = await fixture.business.calls
        XCTAssertEqual(afterClose, 1)
        XCTAssertEqual(fixture.cloud.status(for: fixture.input), .ready)
        // LLM is deliberately unconfigured, so no model request or paste can occur.
        XCTAssertEqual(fixture.session.currentError, .llmConfigurationIncomplete)
        XCTAssertEqual(checkpoint.transcripts, ["合成识别结果"])
        XCTAssertTrue(checkpoint.pendingSegments.isEmpty)
        XCTAssertEqual(fixture.driver.pastes, 0)
    }

    func testBusinessSuccessReportsServiceReadyAfterTemporaryProbeFailure() async throws {
        let fixture = try IntegrationFixture(probeOutcome: .transient)
        defer { fixture.cleanup() }
        fixture.cloud.recordSuccess(fixture.input)
        fixture.cloud.reportRuntimeFailure(fixture.input)
        await waitUntil { fixture.cloud.health.state == .temporaryFailure }
        XCTAssertEqual(fixture.cloud.status(for: fixture.input), .failed)
        XCTAssertEqual(fixture.cloud.readinessStatus(for: fixture.input), .ready)
        let probeCalls = await fixture.probe.calls
        XCTAssertEqual(probeCalls, 3)

        fixture.session.retainRecovery(fixture.checkpoint())
        fixture.session.retryRecovery()
        await waitUntil { fixture.session.state == .error && !fixture.session.isRecovering }

        let businessCalls = await fixture.business.calls
        XCTAssertEqual(businessCalls, 1)
        XCTAssertEqual(fixture.cloud.status(for: fixture.input), .ready)
        XCTAssertFalse(fixture.cloud.isTransientRuntimeFailure)
        XCTAssertNil(fixture.cloud.health.failure)
        XCTAssertEqual(fixture.store.asrConfig.openAICompatible.validationStatus, .verified)
        XCTAssertEqual(fixture.session.currentError, .llmConfigurationIncomplete)
    }

    func testBusinessFailureStartsIndependentProbeWithoutReplayingOrAdvancingRecovery() async throws {
        let fixture = try IntegrationFixture(businessOutcome: .failure)
        defer { fixture.cleanup() }
        fixture.cloud.recordSuccess(fixture.input)
        var failedEvents = 0
        fixture.session.onFeedbackEvent = { event in
            guard case .processingFailed = event else { return }
            failedEvents += 1
            XCTAssertEqual(fixture.session.currentError, .cloudASRNetworkFailure(message: "合成业务请求失败"))
            fixture.cloud.reportRuntimeFailure(fixture.input)
        }
        let checkpoint = fixture.checkpoint()
        fixture.session.retainRecovery(checkpoint)
        let expiry = checkpoint.expiresAt
        let originalAudio = checkpoint.pendingSegments.map(\.pcmData)
        fixture.session.retryRecovery()
        await waitUntil {
            await fixture.probe.calls == 1 && fixture.cloud.status(for: fixture.input) == .ready
                && fixture.session.state == .error && !fixture.session.isRecovering
        }

        let businessCalls = await fixture.business.calls
        XCTAssertEqual(businessCalls, 2, "One business retry; probe success must not submit user audio again")
        XCTAssertEqual(failedEvents, 1)
        XCTAssertEqual(fixture.session.recovery?.id, checkpoint.id)
        XCTAssertEqual(checkpoint.stage, .recognition)
        XCTAssertEqual(checkpoint.pendingSegments.map(\.pcmData), originalAudio)
        XCTAssertTrue(checkpoint.transcripts.isEmpty)
        XCTAssertNil(checkpoint.polished)
        XCTAssertNil(checkpoint.finalText)
        XCTAssertEqual(checkpoint.expiresAt, expiry, "Health checks must not extend the retention deadline")
        XCTAssertTrue(fixture.session.canRetryRecovery)
        XCTAssertEqual(fixture.driver.pastes, 0)
    }

    func testCancellationWhileWaitingForProbeCloseDoesNotSubmitRetainedAudio() async throws {
        let gate = IntegrationProbeGate()
        let fixture = try IntegrationFixture(probeGate: gate)
        defer { fixture.cleanup() }
        fixture.cloud.recordSuccess(fixture.input)
        fixture.cloud.reportRuntimeFailure(fixture.input)
        await waitUntil { await fixture.probe.calls == 1 }
        var waiting = false
        fixture.session.beforeServiceRequest = { stage in
            guard stage == .recognition else { return }
            waiting = true
            await fixture.cloud.waitForProbeClose()
        }
        let checkpoint = fixture.checkpoint()
        fixture.session.retainRecovery(checkpoint)
        fixture.session.retryRecovery()
        await waitUntil { waiting }
        fixture.session.cancel()
        await gate.open()
        await fixture.cloud.waitForProbeClose()
        await waitUntil { !fixture.session.isRecovering }

        let calls = await fixture.business.calls
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(checkpoint.discarded)
        XCTAssertNil(fixture.session.recovery)
        XCTAssertEqual(fixture.driver.pastes, 0)
    }

    private func waitUntil(_ condition: @escaping @MainActor () async -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for recovery/health integration", file: file, line: line)
    }
}

@MainActor
private final class IntegrationFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store: ConfigStore
    let input: CloudASRValidationInput
    let cloud: CloudASRValidationService
    let session: SessionCoordinator
    let driver = FakeInjectionDriver()
    let business: IntegrationBusinessASR
    let probe: IntegrationIndependentProbe

    init(businessOutcome: IntegrationBusinessASR.Outcome = .success,
         probeOutcome: IntegrationIndependentProbe.Outcome = .success,
         probeGate: IntegrationProbeGate? = nil) throws {
        let store = ConfigStore(configDirectory: directory)
        self.store = store
        var config = store.asrConfig
        config.selectedPlatform = .openAICompatibleASR
        config.openAICompatible = .init(baseURL: "https://example.test/v1", apiKey: "synthetic-key",
                                       model: "synthetic-asr")
        try store.saveASRConfig(config)
        let input = CloudASRValidationInput(platform: .openAICompatibleASR, asrConfig: store.asrConfig)
        self.input = input
        let probe = IntegrationIndependentProbe(outcome: probeOutcome, gate: probeGate)
        self.probe = probe
        let cloud = CloudASRValidationService(configStore: store, validatorFactory: { _ in probe },
            probePolicy: .init(delays: [0, 0], cooldown: 0, episodeTimeout: 5,
                               jitter: { 0 }, sleep: { _ in try Task.checkCancellation() },
                               waitForNetwork: { try Task.checkCancellation() }))
        self.cloud = cloud
        let business = IntegrationBusinessASR(outcome: businessOutcome)
        self.business = business
        session = SessionCoordinator(permissionsManager: PermissionsManager(), configStore: store,
            audioDeviceManager: AudioDeviceManager(configStore: store), textInjector: TextInjector(driver: driver),
            asrProviderOverride: { _, _ in business })
        // Exercise the public wiring boundary used by AppCoordinator with actual session stages.
        session.onStateChanged = { _, state in
            cloud.setBusinessActive(state == .recording || state == .transcribing)
        }
        session.beforeServiceRequest = { stage in
            if stage == .recognition { await cloud.waitForProbeClose() }
        }
        session.onServiceSucceeded = { stage in
            if stage == .recognition { cloud.recordSuccess(input) }
        }
    }

    func checkpoint() -> SessionRecoveryCheckpoint {
        let segment = SealedSegment(index: 0, pcmData: Data(repeating: 0x31, count: 3_200),
                                    sampleCount: 1_600, sealReason: .finalize, voicedDetected: true)
        return .init(segments: [segment], transcripts: [], mode: .polish, language: .english,
                     asrPlatform: .openAICompatibleASR, target: driver.current, context: nil)
    }

    func cleanup() {
        session.cancel()
        session.discardRecovery()
        session.beforeServiceRequest = nil
        session.onServiceSucceeded = nil
        session.onStateChanged = nil
        session.onFeedbackEvent = nil
        cloud.shutdown()
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor IntegrationBusinessASR: ASRProvider {
    enum Outcome: Sendable { case success, failure }
    let outcome: Outcome
    private(set) var calls = 0

    init(outcome: Outcome) { self.outcome = outcome }

    func recognize(audioData: Data, timeout: TimeInterval?) async throws -> TranscriptResult {
        calls += 1
        if outcome == .failure { throw MemoEchoError.cloudASRNetworkFailure(message: "合成业务请求失败") }
        return .init(text: "合成识别结果", requestId: nil, durationMs: 100)
    }
}

private actor IntegrationIndependentProbe: CloudASRValidating {
    enum Outcome: Sendable { case success, transient }
    let outcome: Outcome
    let gate: IntegrationProbeGate?
    private(set) var calls = 0
    private(set) var cancellationObserved = false

    init(outcome: Outcome, gate: IntegrationProbeGate?) {
        self.outcome = outcome
        self.gate = gate
    }

    func validateCredentials() async throws {
        calls += 1
        await gate?.wait()
        cancellationObserved = cancellationObserved || Task.isCancelled
        if outcome == .transient { throw URLError(.networkConnectionLost) }
    }
}

private actor IntegrationProbeGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
