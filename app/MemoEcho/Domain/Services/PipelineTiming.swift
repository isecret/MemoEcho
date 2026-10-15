import Foundation

/// Durations use monotonic instants; wall-clock dates remain reserved for expiry and IDs.
struct PipelineClock: Sendable {
    var now: @Sendable () -> ContinuousClock.Instant = { .now }
    static let live = PipelineClock()

    func milliseconds(since start: ContinuousClock.Instant) -> Int {
        Self.milliseconds(from: start, to: now())
    }

    static func milliseconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Int {
        let duration = start.duration(to: end).components
        return max(0, Int(duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000))
    }
}

struct SessionLatencySnapshot: Sendable, Equatable {
    enum Origin: String, Sendable { case recordingStop = "recording_stop", recoveryAttempt = "recovery_attempt" }
    enum Path: String, Sendable { case realtime, segmented, recovery }
    let origin: Origin
    let path: Path
    let elapsedMs: Int
    let captureClosedMs: Int?
    let asrFinalMs: Int?
    let contextReadyMs: Int?
    let contextWaitMs: Int
    let llmCompleteMs: Int?
    let dispatchMs: Int?
    let cleanupCompleteMs: Int?

    var asrWaitMs: Int? {
        guard let asrFinalMs else { return nil }
        if origin == .recoveryAttempt { return asrFinalMs }
        return captureClosedMs.map { max(0, asrFinalMs - $0) }
    }
    var dispatchToCleanupMs: Int? {
        guard let dispatchMs, let cleanupCompleteMs else { return nil }
        return max(0, cleanupCompleteMs - dispatchMs)
    }
}

/// One attempt owns one origin. Cached stages in recovery never receive fresh completion marks.
@MainActor
final class SessionLatencyTimeline {
    enum Milestone: String, Sendable {
        case captureClosed = "capture_closed", asrFinal = "asr_final", contextReady = "context_ready"
        case llmComplete = "llm_complete", dispatched = "output_dispatched", cleanupComplete = "cleanup_complete"
    }
    let origin: SessionLatencySnapshot.Origin
    let path: SessionLatencySnapshot.Path
    let startedAt: ContinuousClock.Instant
    private var marks: [Milestone: ContinuousClock.Instant] = [:]
    var contextWaitMs = 0

    init(origin: SessionLatencySnapshot.Origin, path: SessionLatencySnapshot.Path, startedAt: ContinuousClock.Instant) {
        self.origin = origin
        self.path = path
        self.startedAt = startedAt
    }

    func mark(_ milestone: Milestone, at instant: ContinuousClock.Instant) {
        if marks[milestone] == nil { marks[milestone] = instant }
    }

    func snapshot(at instant: ContinuousClock.Instant) -> SessionLatencySnapshot {
        func elapsed(_ milestone: Milestone) -> Int? {
            marks[milestone].map { PipelineClock.milliseconds(from: startedAt, to: $0) }
        }
        return .init(origin: origin, path: path,
            elapsedMs: PipelineClock.milliseconds(from: startedAt, to: instant),
            captureClosedMs: elapsed(.captureClosed), asrFinalMs: elapsed(.asrFinal),
            contextReadyMs: elapsed(.contextReady), contextWaitMs: contextWaitMs,
            llmCompleteMs: elapsed(.llmComplete), dispatchMs: elapsed(.dispatched),
            cleanupCompleteMs: elapsed(.cleanupComplete))
    }
}

/// Numeric metadata for the exact request being sent. No content, keys, URLs or model names.
struct LLMRequestMetrics: Sendable, Equatable {
    enum Purpose: String, Sendable { case polish, translation, validation, dictionaryLearning = "dictionary_learning" }
    let purpose: Purpose
    let systemCharacters: Int
    let inputCharacters: Int
    let dictionaryTerms: Int
    let dictionaryCharacters: Int
    let contextCharacters: Int
    let auxiliaryUTF8Bytes: Int
    let requestBodyBytes: Int
    let thinkingDisabled: Bool
}
