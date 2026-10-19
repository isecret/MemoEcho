import Foundation
import os

/// Runs only synthetic validation work. Never owns a recording or recovery checkpoint.
@MainActor
@Observable
final class ServiceHealthMonitor {
    enum State { case idle, checking, ready, temporaryFailure, blocked }
    struct Policy: Sendable {
        var delays: [TimeInterval] = [2, 5]
        var cooldown: TimeInterval = 60
        var episodeTimeout: TimeInterval = 100
        var jitter: @Sendable () -> TimeInterval = { Double.random(in: 0...0.25) }
        var sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
        var waitForNetwork: @Sendable () async throws -> Void = { try await ServiceProbeNetworkRecovery.waitUntilAvailable() }
    }

    private(set) var fingerprint: String?
    private(set) var state: State = .idle
    private(set) var failure: ServiceProbeFailure?
    private(set) var previouslyVerified = false
    private(set) var businessActive = false
    private(set) var retryNotBefore: ContinuousClock.Instant?
    private var nextAutomaticCheck: ContinuousClock.Instant?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var closingTask: Task<Void, Never>?
    private var cooldownTask: Task<Void, Never>?
    private let policy: Policy
    private let logger = Logger(subsystem: "me.wangmao.memoecho", category: "ServiceProbe")

    init(policy: Policy = .init()) { self.policy = policy }

    var isChecking: Bool { state == .checking }
    var isCoolingDown: Bool { retryNotBefore.map { .now < $0 } ?? false }
    var canStart: Bool { !businessActive && !isChecking && !isCoolingDown }
    var preservesReadiness: Bool {
        previouslyVerified && state != .blocked && !isCoolingDown
    }

    func reset(ifDifferent key: String) {
        guard fingerprint != key else { return }
        cancel()
        fingerprint = key
        state = .idle
        failure = nil
        previouslyVerified = false
        retryNotBefore = nil
        nextAutomaticCheck = nil
        cooldownTask?.cancel()
    }

    func setBusinessActive(_ active: Bool) {
        businessActive = active
        if active, isChecking {
            cancel()
            state = .temporaryFailure
        }
    }

    func waitForClose() async { await closingTask?.value }

    func cancel() {
        generation = UUID()
        let previous = closingTask
        let current = task
        current?.cancel()
        task = nil
        if current != nil {
            closingTask = Task { await previous?.value; await current?.value }
        }
    }

    func recordSuccess(for key: String, allPurposesHealthy: Bool = true) {
        reset(ifDifferent: key)
        cancel()
        state = allPurposesHealthy ? .ready : .temporaryFailure
        if allPurposesHealthy { failure = nil }
        previouslyVerified = true
        retryNotBefore = nil
        cooldownTask?.cancel()
    }

    func check(
        fingerprint key: String, verified: Bool, automatic: Bool, requestTimeout: TimeInterval,
        operation: @escaping @MainActor @Sendable () async throws -> Void,
        completion: @escaping @MainActor @Sendable (Result<Void, ServiceProbeFailure>) -> Void
    ) {
        reset(ifDifferent: key)
        guard canStart else { return }
        if automatic, let nextAutomaticCheck, .now < nextAutomaticCheck {
            if state != .blocked {
                state = .temporaryFailure
                failure = .init(kind: .transient, message: "服务请求失败，稍后可重试")
            }
            return
        }
        previouslyVerified = verified
        state = .checking
        failure = nil
        let id = UUID()
        generation = id
        let previous = closingTask
        let policy = policy
        let logger = logger
        let trigger = automatic ? "runtime" : "manual"
        task = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            let deadline = ContinuousClock.now + .seconds(policy.episodeTimeout)
            let budget = ServiceProbeBudget(maximumRequests: 3)
            let result: Result<Void, ServiceProbeFailure> = await ServiceProbeContext.$budget.withValue(budget) {
                var lastFailure = ServiceProbeFailure.classify(URLError(.timedOut))
                for attempt in 0..<3 {
                    do {
                        try Task.checkCancellation()
                        let remaining = Self.seconds(ContinuousClock.now.duration(to: deadline))
                        guard remaining > 0 else { break }
                        logger.info("probe_attempt | purpose=runtime_probe | fixture_version=\(ValidationFixture.version) | probe_trigger=\(trigger, privacy: .public) | probe_attempt=\(attempt + 1)")
                        try await Self.bounded(seconds: min(requestTimeout, remaining), operation: operation)
                        return .success(())
                    } catch {
                        if ServiceProbeFailure.isCancellation(error) || Task.isCancelled { return .failure(lastFailure) }
                        let classified = ServiceProbeFailure.classify(error)
                        if classified.kind != .budgetExhausted { lastFailure = classified }
                        if let delay = classified.retryAfter { self?.setRetryAfter(delay, generation: id) }
                        guard classified.kind == .transient, attempt < 2 else { break }
                        if classified.waitsForNetwork {
                            let remaining = Self.seconds(ContinuousClock.now.duration(to: deadline))
                            guard remaining > 0 else { break }
                            do {
                                try await Self.bounded(seconds: remaining) { try await policy.waitForNetwork() }
                            } catch { break }
                        }
                        let delay = max(classified.retryAfter ?? 0,
                                        (policy.delays.indices.contains(attempt) ? policy.delays[attempt] : 5) + policy.jitter())
                        guard delay < Self.seconds(ContinuousClock.now.duration(to: deadline)) else { break }
                        do { try await policy.sleep(delay) }
                        catch { return .failure(lastFailure) }
                    }
                }
                return .failure(lastFailure)
            }
            let requests = await budget.requestsUsed
            guard let self, self.generation == id, !Task.isCancelled else { return }
            self.task = nil
            self.nextAutomaticCheck = .now + .seconds(policy.cooldown)
            let outcome = (try? result.get()) != nil ? "success" : "failed"
            logger.info("probe_finished | purpose=runtime_probe | fixture_version=\(ValidationFixture.version) | probe_result=\(outcome, privacy: .public) | inference_requests=\(requests) | cooldown_ms=\(Int(policy.cooldown * 1000))")
            switch result {
            case .success:
                self.state = .ready
                self.previouslyVerified = true
                self.failure = nil
                self.retryNotBefore = nil
                self.cooldownTask?.cancel()
            case .failure(let error):
                self.failure = error
                self.state = error.kind == .confirmedBlocker ? .blocked : .temporaryFailure
                if self.state == .blocked { self.previouslyVerified = false }
            }
            completion(result)
        }
    }

    private func setRetryAfter(_ seconds: TimeInterval, generation id: UUID) {
        guard generation == id, seconds.isFinite, seconds > 0 else { return }
        let proposedEnd = ContinuousClock.now + .seconds(seconds)
        let end = max(retryNotBefore ?? proposedEnd, proposedEnd)
        retryNotBefore = end
        cooldownTask?.cancel()
        cooldownTask = Task { [weak self] in
            do { try await Task.sleep(until: end, clock: .continuous) } catch { return }
            guard let self, self.retryNotBefore == end else { return }
            self.retryNotBefore = nil
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static func bounded(seconds: TimeInterval,
                                operation: @escaping @MainActor @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }
}
