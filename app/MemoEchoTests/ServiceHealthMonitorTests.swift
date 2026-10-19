import Foundation
import XCTest
@testable import MemoEcho

@MainActor
final class ServiceHealthMonitorTests: XCTestCase {
    func testTransientFailureRetriesAndSuccessRestoresReady() async {
        let monitor = ServiceHealthMonitor(policy: immediatePolicy())
        var attempts = 0
        var completions = 0
        monitor.check(fingerprint: "service-a", verified: true, automatic: true, requestTimeout: 2) {
            attempts += 1
            if attempts == 1 { throw URLError(.networkConnectionLost) }
        } completion: { result in
            completions += 1
            if case .failure = result { XCTFail("The second independent probe should succeed") }
        }

        await waitUntil { completions == 1 }
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(monitor.state == .ready)
        XCTAssertTrue(monitor.preservesReadiness)
        XCTAssertNil(monitor.failure)
    }

    func testPersistentTransientFailureStopsAtThreeAndAutomaticChecksRespectCooldown() async {
        let monitor = ServiceHealthMonitor(policy: immediatePolicy(cooldown: 60))
        var attempts = 0
        let operation: @MainActor @Sendable () async throws -> Void = {
            attempts += 1
            throw URLError(.timedOut)
        }
        monitor.check(fingerprint: "service-a", verified: true, automatic: true,
                      requestTimeout: 2, operation: operation, completion: { _ in })
        await waitUntil { monitor.state == .temporaryFailure }

        XCTAssertEqual(attempts, 3)
        XCTAssertTrue(monitor.preservesReadiness)
        monitor.check(fingerprint: "service-a", verified: true, automatic: true,
                      requestTimeout: 2, operation: operation, completion: { _ in })
        XCTAssertFalse(monitor.isChecking)
        XCTAssertEqual(attempts, 3)

        // An explicit user check may bypass the automatic episode cooldown.
        monitor.check(fingerprint: "service-a", verified: true, automatic: false, requestTimeout: 2) {
            attempts += 1
        } completion: { _ in }
        await waitUntil { monitor.state == .ready }
        XCTAssertEqual(attempts, 4)
    }

    func testNewRuntimeFailureDuringCooldownUpdatesStatusWithoutAnotherRequest() async {
        let monitor = ServiceHealthMonitor(policy: immediatePolicy(cooldown: 60))
        var attempts = 0
        let operation: @MainActor @Sendable () async throws -> Void = { attempts += 1 }
        monitor.check(fingerprint: "service-a", verified: true, automatic: true,
                      requestTimeout: 2, operation: operation, completion: { _ in })
        await waitUntil { monitor.state == .ready }

        monitor.check(fingerprint: "service-a", verified: true, automatic: true,
                      requestTimeout: 2, operation: operation, completion: { _ in })
        XCTAssertTrue(monitor.state == .temporaryFailure)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(monitor.failure?.kind, .transient)
        XCTAssertTrue(monitor.preservesReadiness)
        XCTAssertFalse(monitor.isChecking)
    }

    func testOfflineProbeWaitsForNetworkWithoutOpeningConnectionsAndCancelsPromptly() async {
        let networkWait = CancellableNetworkWait()
        var policy = immediatePolicy()
        policy.waitForNetwork = { try await networkWait.wait() }
        let monitor = ServiceHealthMonitor(policy: policy)
        defer { monitor.reset(ifDifferent: "cleanup") }
        var attempts = 0
        var completions = 0
        let operation: @MainActor @Sendable () async throws -> Void = {
            attempts += 1
            throw URLError(.notConnectedToInternet)
        }
        monitor.check(fingerprint: "service-a", verified: true, automatic: true,
                      requestTimeout: 2, operation: operation, completion: { _ in completions += 1 })
        await waitUntil { await networkWait.started }
        monitor.check(fingerprint: "service-a", verified: true, automatic: false,
                      requestTimeout: 2, operation: operation, completion: { _ in completions += 1 })
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(monitor.isChecking)

        monitor.cancel()
        await monitor.waitForClose()
        let cancelled = await networkWait.cancelled
        XCTAssertTrue(cancelled)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(completions, 0, "Cancellation must not publish a false probe failure")
    }

    func testConfirmedBlockerStopsAfterOneProbeAndRevokesReadiness() async {
        let monitor = ServiceHealthMonitor(policy: immediatePolicy())
        var attempts = 0
        monitor.check(fingerprint: "service-a", verified: true, automatic: true, requestTimeout: 2) {
            attempts += 1
            throw ServiceProbeFailure(kind: .confirmedBlocker, message: "服务鉴权失败")
        } completion: { _ in }

        await waitUntil { monitor.state == .blocked }
        XCTAssertEqual(attempts, 1)
        XCTAssertFalse(monitor.preservesReadiness)
        XCTAssertFalse(monitor.previouslyVerified)
    }

    func testCheckingAndTemporaryFailurePreservePreviouslyVerifiedReadiness() async {
        let gate = ProbeGate()
        let monitor = ServiceHealthMonitor(policy: immediatePolicy())
        monitor.recordSuccess(for: "service-a")
        monitor.check(fingerprint: "service-a", verified: true, automatic: true, requestTimeout: 2) {
            await gate.wait()
            throw URLError(.networkConnectionLost)
        } completion: { _ in }

        XCTAssertTrue(monitor.isChecking)
        XCTAssertTrue(monitor.preservesReadiness)
        await gate.open()
        await waitUntil { monitor.state == .temporaryFailure }
        XCTAssertTrue(monitor.preservesReadiness)
    }

    func testRepeatedAutomaticAndManualRequestsShareTheRunningFlight() async {
        let gate = ProbeGate()
        let monitor = ServiceHealthMonitor(policy: immediatePolicy())
        var attempts = 0
        var completions = 0
        let operation: @MainActor @Sendable () async throws -> Void = {
            attempts += 1
            await gate.wait()
        }
        let completion: @MainActor @Sendable (Result<Void, ServiceProbeFailure>) -> Void = { _ in
            completions += 1
        }
        monitor.check(fingerprint: "service-a", verified: true, automatic: true,
                      requestTimeout: 2, operation: operation, completion: completion)
        await waitUntil { attempts == 1 }
        monitor.check(fingerprint: "service-a", verified: true, automatic: true,
                      requestTimeout: 2, operation: operation, completion: completion)
        monitor.check(fingerprint: "service-a", verified: true, automatic: false,
                      requestTimeout: 2, operation: operation, completion: completion)
        XCTAssertFalse(monitor.canStart)
        await gate.open()
        await waitUntil { completions == 1 }
        XCTAssertEqual(attempts, 1)
    }

    func testOldCancelledIdentityCannotOverwriteNewProbe() async {
        let oldGate = ProbeGate()
        let monitor = ServiceHealthMonitor(policy: immediatePolicy())
        var oldStarted = false
        var oldCompleted = false
        var newStarted = false
        monitor.check(fingerprint: "old-configuration", verified: true, automatic: true, requestTimeout: 2) {
            oldStarted = true
            // Deliberately ignore cancellation until teardown is complete.
            await oldGate.wait()
            throw ServiceProbeFailure(kind: .confirmedBlocker, message: "旧配置错误")
        } completion: { _ in oldCompleted = true }
        await waitUntil { oldStarted }

        monitor.check(fingerprint: "new-configuration", verified: false, automatic: false, requestTimeout: 2) {
            newStarted = true
        } completion: { _ in }
        XCTAssertEqual(monitor.fingerprint, "new-configuration")
        XCTAssertTrue(monitor.isChecking)
        XCTAssertFalse(newStarted, "The old probe must close before the replacement sends")

        await oldGate.open()
        await waitUntil { monitor.state == .ready }
        XCTAssertTrue(newStarted)
        XCTAssertFalse(oldCompleted)
        XCTAssertEqual(monitor.fingerprint, "new-configuration")
        XCTAssertNil(monitor.failure)
    }

    func testManualCheckCannotBypassServerRetryAfter() async {
        var policy = immediatePolicy()
        policy.episodeTimeout = 1
        let monitor = ServiceHealthMonitor(policy: policy)
        defer { monitor.reset(ifDifferent: "cleanup") }
        var attempts = 0
        let operation: @MainActor @Sendable () async throws -> Void = {
            attempts += 1
            throw ServiceProbeFailure(kind: .transient, message: "服务限流，请稍后重试",
                                      retryAfter: 60, httpStatus: 429)
        }
        monitor.check(fingerprint: "service-a", verified: true, automatic: true,
                      requestTimeout: 2, operation: operation, completion: { _ in })
        await waitUntil { monitor.state == .temporaryFailure }

        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(monitor.isCoolingDown)
        XCTAssertFalse(monitor.canStart)
        XCTAssertFalse(monitor.preservesReadiness, "A known server deadline also gates business sends")
        monitor.check(fingerprint: "service-a", verified: true, automatic: false,
                      requestTimeout: 2, operation: operation, completion: { _ in })
        XCTAssertEqual(attempts, 1)
        XCTAssertFalse(monitor.isChecking)
    }

    func testBusinessPreemptionWaitsForProbeTeardownWithoutPublishingCancellation() async {
        let gate = ProbeGate()
        let monitor = ServiceHealthMonitor(policy: immediatePolicy())
        var started = false
        var completions = 0
        var closed = false
        monitor.check(fingerprint: "service-a", verified: true, automatic: true, requestTimeout: 2) {
            started = true
            await gate.wait()
        } completion: { _ in completions += 1 }
        await waitUntil { started }

        monitor.setBusinessActive(true)
        let waiter = Task { await monitor.waitForClose(); closed = true }
        await Task.yield()
        XCTAssertFalse(closed)
        XCTAssertFalse(monitor.canStart)
        XCTAssertTrue(monitor.preservesReadiness)
        await gate.open()
        await waiter.value
        XCTAssertTrue(closed)
        XCTAssertEqual(completions, 0)
        monitor.setBusinessActive(false)
        XCTAssertTrue(monitor.canStart)
    }

    func testActualInferenceBudgetIncludesCompatibilityFallbackAcrossAttempts() async {
        let transport = ProbeTransport()
        let monitor = ServiceHealthMonitor(policy: immediatePolicy())
        let request = URLRequest(url: URL(string: "https://example.test/v1/chat/completions")!)
        var attempts = 0
        monitor.check(fingerprint: "service-a", verified: true, automatic: true, requestTimeout: 2) {
            attempts += 1
            // A provider's existing optional-field fallback performs two actual sends.
            _ = try await ServiceProbeContext.send(request, allowsThinkingFallback: true) { request in
                await transport.send(request)
            }
            _ = try await ServiceProbeContext.send(request) { request in
                await transport.send(request)
            }
        } completion: { _ in }

        await waitUntil { monitor.state == .temporaryFailure }
        let sends = await transport.sends
        XCTAssertEqual(sends, 3, "Three probe attempts must not each receive a fresh fallback budget")
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(monitor.failure?.kind, .transient)
    }

    func testLLMRuntimeProbePreservesReadinessAndManualRetryRecoversWithoutConfigChanges() async {
        let gate = ProbeGate()
        let script = ProbeScript(outcomes: [.transient, .transient, .transient, .success], gate: gate)
        let service = LLMValidationService(validator: { _, _ in try await script.run() },
                                           probePolicy: immediatePolicy())
        defer { service.shutdown() }
        let input = llmInput()
        service.recordSuccess(input)
        service.reportRuntimeFailure(input)
        XCTAssertEqual(service.status(for: input), .checking)
        XCTAssertEqual(service.readinessStatus(for: input), .ready)

        await gate.open()
        await waitUntil { service.status(for: input) == .failed }
        XCTAssertEqual(service.readinessStatus(for: input), .ready)
        XCTAssertTrue(service.isTransientRuntimeFailure)
        service.retry(input)
        await waitUntil { service.status(for: input) == .ready }
        XCTAssertFalse(service.isTransientRuntimeFailure)
        let count = await script.calls
        XCTAssertEqual(count, 4)
    }

    func testLLMManualRetryBypassesCachedInitialFailureWithoutEdits() async {
        let script = ProbeScript(outcomes: [.blocker, .success])
        let service = LLMValidationService(validator: { _, _ in try await script.run() },
                                           probePolicy: immediatePolicy())
        defer { service.shutdown() }
        let input = llmInput()
        service.validate(input)
        await waitUntil { service.status(for: input) == .failed }
        service.validate(input)
        let initialCalls = await script.calls
        XCTAssertEqual(initialCalls, 1)

        XCTAssertTrue(service.canRetry(input))
        service.retry(input)
        await waitUntil { service.status(for: input) == .ready }
        let retriedCalls = await script.calls
        XCTAssertEqual(retriedCalls, 2)
    }

    func testLLMBusinessSendCannotBypassRetryAfterReceivedByProbe() async {
        let script = ProbeScript(outcomes: [.rateLimited])
        let service = LLMValidationService(validator: { _, _ in try await script.run() },
                                           probePolicy: immediatePolicy())
        defer { service.health.reset(ifDifferent: "cleanup"); service.shutdown() }
        let input = llmInput()
        service.recordSuccess(input)
        service.reportRuntimeFailure(input)
        await waitUntil { service.status(for: input) == .failed }
        service.setBusinessActive(true)

        for _ in 0..<2 {
            do {
                try await service.prepareForBusinessRequest()
                XCTFail("The actual model send must honor the probe's Retry-After")
            } catch {
                XCTAssertEqual(error as? MemoEchoError, .llmNetworkFailure(message: "服务限流，请稍后重试"))
            }
        }
        XCTAssertTrue(service.health.isCoolingDown)
        let calls = await script.calls
        XCTAssertEqual(calls, 1)
    }

    func testCloudBusinessSendCannotBypassRetryAfterReceivedByProbe() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try cloudStore(directory: directory)
        let script = ProbeScript(outcomes: [.rateLimited])
        let service = CloudASRValidationService(configStore: store,
            validatorFactory: { _ in ScriptedCloudProbe(script: script) }, probePolicy: immediatePolicy())
        defer { service.health.reset(ifDifferent: "cleanup"); service.shutdown() }
        let input = CloudASRValidationInput(platform: .openAICompatibleASR, asrConfig: store.asrConfig)
        service.recordSuccess(input)
        service.reportRuntimeFailure(input)
        await waitUntil { service.status(for: input) == .failed }
        service.setBusinessActive(true)

        for _ in 0..<2 {
            do {
                try await service.prepareForBusinessRequest()
                XCTFail("The actual ASR send must honor the probe's Retry-After")
            } catch {
                XCTAssertEqual(error as? MemoEchoError, .cloudASRNetworkFailure(message: "服务限流，请稍后重试"))
            }
        }
        XCTAssertTrue(service.health.isCoolingDown)
        let calls = await script.calls
        XCTAssertEqual(calls, 1)
    }

    func testBusinessPreparationAllowsTransientFailuresWithoutRetryAfter() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try cloudStore(directory: directory)
        let cloudScript = ProbeScript(outcomes: [.transient])
        let llmScript = ProbeScript(outcomes: [.transient])
        let cloud = CloudASRValidationService(configStore: store,
            validatorFactory: { _ in ScriptedCloudProbe(script: cloudScript) }, probePolicy: immediatePolicy())
        let llm = LLMValidationService(validator: { _, _ in try await llmScript.run() },
                                      probePolicy: immediatePolicy())
        defer { cloud.shutdown(); llm.shutdown() }
        let asrInput = CloudASRValidationInput(platform: .openAICompatibleASR, asrConfig: store.asrConfig)
        let modelInput = llmInput()
        cloud.recordSuccess(asrInput)
        llm.recordSuccess(modelInput)
        cloud.reportRuntimeFailure(asrInput)
        llm.reportRuntimeFailure(modelInput)
        await waitUntil { cloud.status(for: asrInput) == .failed && llm.status(for: modelInput) == .failed }
        cloud.setBusinessActive(true)
        llm.setBusinessActive(true)

        try await cloud.prepareForBusinessRequest()
        try await llm.prepareForBusinessRequest()
        XCTAssertFalse(cloud.health.isCoolingDown)
        XCTAssertFalse(llm.health.isCoolingDown)
        let cloudCalls = await cloudScript.calls
        let llmCalls = await llmScript.calls
        XCTAssertEqual(cloudCalls, 3)
        XCTAssertEqual(llmCalls, 3)
    }

    func testConfirmedProbeBlockersPreventBothBusinessSends() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try cloudStore(directory: directory)
        let cloudScript = ProbeScript(outcomes: [.blocker])
        let llmScript = ProbeScript(outcomes: [.blocker])
        let cloud = CloudASRValidationService(configStore: store,
            validatorFactory: { _ in ScriptedCloudProbe(script: cloudScript) }, probePolicy: immediatePolicy())
        let llm = LLMValidationService(validator: { _, _ in try await llmScript.run() },
                                      probePolicy: immediatePolicy())
        defer { cloud.shutdown(); llm.shutdown() }
        let asrInput = CloudASRValidationInput(platform: .openAICompatibleASR, asrConfig: store.asrConfig)
        let modelInput = llmInput()
        cloud.recordSuccess(asrInput)
        llm.recordSuccess(modelInput)
        cloud.reportRuntimeFailure(asrInput)
        llm.reportRuntimeFailure(modelInput)
        await waitUntil { cloud.health.state == .blocked && llm.health.state == .blocked }
        cloud.setBusinessActive(true)
        llm.setBusinessActive(true)
        var businessSends = 0

        do {
            try await cloud.prepareForBusinessRequest()
            businessSends += 1
            XCTFail("A confirmed ASR blocker must prevent the business send")
        } catch {
            XCTAssertEqual(error as? MemoEchoError, .cloudASRAuthenticationFailure)
        }
        do {
            try await llm.prepareForBusinessRequest()
            businessSends += 1
            XCTFail("A confirmed model blocker must prevent the business send")
        } catch {
            XCTAssertEqual(error as? MemoEchoError,
                           .invalidLLMConfiguration(detail: "服务测试未通过，请在设置中重试"))
        }
        XCTAssertEqual(businessSends, 0)
        let cloudCalls = await cloudScript.calls
        let llmCalls = await llmScript.calls
        XCTAssertEqual(cloudCalls, 1)
        XCTAssertEqual(llmCalls, 1)
    }

    func testLLMInitialValidationIsCancelledAndClosedBeforeBusinessContinues() async {
        let gate = ProbeGate()
        let script = ProbeScript(outcomes: [.success], gate: gate)
        let service = LLMValidationService(validator: { _, _ in try await script.run() },
                                           probePolicy: immediatePolicy())
        defer { service.shutdown() }
        let input = llmInput()
        service.validate(input)
        await waitUntil { await script.calls == 1 }
        service.setBusinessActive(true)
        var closed = false
        let closeTask = Task { await service.waitForProbeClose(); closed = true }
        await Task.yield()
        XCTAssertFalse(closed)
        XCTAssertFalse(service.canRetry(input))
        service.validate(input)
        service.retry(input)

        await gate.open()
        await closeTask.value
        let cancelled = await script.cancellationObserved
        let calls = await script.calls
        XCTAssertTrue(cancelled)
        XCTAssertTrue(closed)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(service.status(for: input), .incomplete)
        service.setBusinessActive(false)
        XCTAssertTrue(service.canRetry(input))
    }

    func testLLMDoesNotClearAnotherPendingPurposeWhenOneBusinessStageSucceeds() async {
        let gate = ProbeGate()
        let script = ProbeScript(outcomes: [.success], gate: gate)
        let service = LLMValidationService(validator: { _, _ in try await script.run() },
                                           probePolicy: immediatePolicy())
        defer { service.shutdown() }
        let input = llmInput()
        service.recordSuccess(input)
        service.reportRuntimeFailure(input, purpose: .translation)
        await waitUntil { await script.calls == 1 }
        service.reportRuntimeFailure(input, purpose: .polish)
        service.recordSuccess(input, purpose: .polish)
        XCTAssertEqual(service.status(for: input), .failed)
        XCTAssertTrue(service.isTransientRuntimeFailure)
        XCTAssertEqual(service.readinessStatus(for: input), .ready)

        await gate.open()
        await service.waitForProbeClose()
        XCTAssertEqual(service.status(for: input), .failed, "A cancelled translation probe cannot clear pending health")
        service.recordSuccess(input, purpose: .translation)
        XCTAssertEqual(service.status(for: input), .ready)
        XCTAssertFalse(service.isTransientRuntimeFailure)
    }

    func testLLMChecksEveryDistinctPendingPurposeBeforePublishingReady() async {
        let firstGate = ProbeGate()
        let secondGate = ProbeGate()
        let sequence = PurposeProbeSequence(gates: [firstGate, secondGate])
        let service = LLMValidationService(validator: { _, _ in await sequence.run() },
                                           probePolicy: immediatePolicy())
        defer { service.shutdown() }
        let input = llmInput()
        service.recordSuccess(input)
        service.setBusinessActive(true)
        service.reportRuntimeFailure(input, purpose: .translation)
        service.reportRuntimeFailure(input, purpose: .polish)
        service.reportRuntimeFailure(input, purpose: .polish)
        service.setBusinessActive(false)
        service.retry(input)
        await waitUntil { await sequence.calls == 1 }

        await firstGate.open()
        await waitUntil { await sequence.calls == 2 }
        XCTAssertEqual(service.status(for: input), .checking)
        await secondGate.open()
        await waitUntil { service.status(for: input) == .ready }
        let calls = await sequence.calls
        XCTAssertEqual(calls, 2, "Repeated failures for one purpose must coalesce")
    }

    func testCloudRuntimeProbePreservesSavedEvidenceEvenForOlderInputSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try cloudStore(directory: directory)
        let input = CloudASRValidationInput(platform: .openAICompatibleASR, asrConfig: store.asrConfig)
        let gate = ProbeGate()
        let script = ProbeScript(outcomes: [.transient, .transient, .transient, .success], gate: gate)
        let service = CloudASRValidationService(configStore: store,
            validatorFactory: { _ in ScriptedCloudProbe(script: script) }, probePolicy: immediatePolicy())
        defer { service.shutdown() }
        service.recordSuccess(input)
        XCTAssertEqual(store.asrConfig.openAICompatible.validationStatus, .verified)
        service.reportRuntimeFailure(input)
        XCTAssertEqual(service.status(for: input), .checking)
        XCTAssertEqual(service.readinessStatus(for: input), .ready)

        await gate.open()
        await waitUntil { service.status(for: input) == .failed }
        XCTAssertEqual(service.readinessStatus(for: input), .ready)
        XCTAssertEqual(store.asrConfig.openAICompatible.validationStatus, .verified)
        service.retry(input)
        await waitUntil { service.status(for: input) == .ready }
        let count = await script.calls
        XCTAssertEqual(count, 4)
    }

    func testCloudManualRetryBypassesCachedInitialFailureWithoutEdits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try cloudStore(directory: directory)
        let script = ProbeScript(outcomes: [.blocker, .success])
        let service = CloudASRValidationService(configStore: store,
            validatorFactory: { _ in ScriptedCloudProbe(script: script) }, probePolicy: immediatePolicy())
        defer { service.shutdown() }
        let input = CloudASRValidationInput(platform: .openAICompatibleASR, asrConfig: store.asrConfig)
        service.validate(input)
        await waitUntil { service.status(for: input) == .failed }
        service.validate(input)
        let initialCalls = await script.calls
        XCTAssertEqual(initialCalls, 1)
        XCTAssertTrue(service.canRetry(input))

        service.retry(input)
        await waitUntil { service.status(for: input) == .ready }
        let retriedCalls = await script.calls
        XCTAssertEqual(retriedCalls, 2)
        XCTAssertEqual(store.asrConfig.openAICompatible.validationStatus, .verified)
    }

    private func immediatePolicy(cooldown: TimeInterval = 0) -> ServiceHealthMonitor.Policy {
        .init(delays: [0, 0], cooldown: cooldown, episodeTimeout: 5,
              jitter: { 0 }, sleep: { _ in try Task.checkCancellation() },
              waitForNetwork: { try Task.checkCancellation() })
    }

    private func llmInput() -> LLMValidationInput {
        .init(baseURL: "https://example.test/v1", apiKey: "synthetic-key", model: "synthetic-model",
              omitThinkingParameter: false)
    }

    private func cloudStore(directory: URL) throws -> ConfigStore {
        let store = ConfigStore(configDirectory: directory)
        var config = store.asrConfig
        config.selectedPlatform = .openAICompatibleASR
        config.openAICompatible = .init(baseURL: "https://example.test/v1", apiKey: "synthetic-key",
                                       model: "synthetic-asr")
        try store.saveASRConfig(config)
        return store
    }

    private func waitUntil(_ condition: @escaping @MainActor () async -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for independent probe state", file: file, line: line)
    }
}

private actor ProbeGate {
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

private actor ProbeScript {
    enum Outcome: Sendable { case success, transient, blocker, rateLimited }
    private let outcomes: [Outcome]
    private let gate: ProbeGate?
    private(set) var calls = 0
    private(set) var cancellationObserved = false

    init(outcomes: [Outcome], gate: ProbeGate? = nil) {
        self.outcomes = outcomes
        self.gate = gate
    }

    func run() async throws {
        let index = calls
        calls += 1
        await gate?.wait()
        cancellationObserved = cancellationObserved || Task.isCancelled
        switch outcomes[min(index, outcomes.count - 1)] {
        case .success: return
        case .transient: throw URLError(.networkConnectionLost)
        case .blocker: throw ServiceProbeFailure(kind: .confirmedBlocker, message: "服务鉴权失败")
        case .rateLimited:
            throw ServiceProbeFailure(kind: .transient, message: "服务限流，请稍后重试",
                                      retryAfter: 60, httpStatus: 429)
        }
    }
}

private actor CancellableNetworkWait {
    private(set) var started = false
    private(set) var cancelled = false

    func wait() async throws {
        started = true
        do { try await Task.sleep(for: .seconds(30)) }
        catch {
            cancelled = Task.isCancelled
            throw error
        }
    }
}

private actor PurposeProbeSequence {
    let gates: [ProbeGate]
    private(set) var calls = 0

    init(gates: [ProbeGate]) { self.gates = gates }

    func run() async {
        let index = calls
        calls += 1
        if gates.indices.contains(index) { await gates[index].wait() }
    }
}

private struct ScriptedCloudProbe: CloudASRValidating {
    let script: ProbeScript
    func validateCredentials() async throws { try await script.run() }
}

private actor ProbeTransport {
    private(set) var sends = 0

    func send(_ request: URLRequest) -> (Data, URLResponse) {
        sends += 1
        let status = sends.isMultiple(of: 2) ? 503 : 400
        let body = status == 400
            ? Data(#"{"error":{"message":"unsupported thinking parameter"}}"#.utf8)
            : Data()
        return (body, HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: nil)!)
    }
}
