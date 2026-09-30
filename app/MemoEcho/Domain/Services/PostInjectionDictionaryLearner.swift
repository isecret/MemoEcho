import Foundation

@MainActor
protocol PostInjectionDictionaryLearning: Sendable {
    func observe(
        beforeInjection: FocusedElementTextSnapshot,
        insertedText: String,
        store: PersonalDictionaryStore,
        shouldContinue: @escaping @MainActor @Sendable () -> Bool,
        onObservation: @escaping @MainActor @Sendable (PostInjectionObservationEvent) -> Void,
        onDecision: @escaping @MainActor @Sendable (PostInjectionLearningDecision) -> Void
    ) async
}

/// Diagnostic stages only; never includes field text, candidates, or model responses.
enum PostInjectionObservationEvent: String, Sendable {
    case started, baselineVerified, evaluating, existingTerm
    case textChanged, selectionChanged, selectionActive, compositionActive
    case invalidInput, cancelled, targetUnavailable, targetChanged
    case baselineMismatch, baselineSelectionMismatch, baselineCompositionActive, baselineTimedOut
    case outsideInsertedRange, fieldCleared, editTooLarge
    case evaluationLimit, evaluationInvalidated, observationTimedOut
}

struct LearnedTermReplacement: Equatable, Sendable {
    let oldSpan: String
    let newSpan: String
    let surroundingTextBefore: String
    let surroundingTextAfter: String
}

/// Only a bounded excerpt from the text inserted by this session reaches the model.
struct ProperNounLearningCandidate: Equatable, Sendable, Encodable {
    let originalText: String
    let updatedText: String
    let originalSpan: String
    let replacedSpan: String
    let changeStart: Int // Character offset in updatedText, not UTF-16.
}

enum ProperNounLearningDecision: Equatable, Sendable {
    case accept(term: String, start: Int)
    case reject
}

enum PostInjectionLearningDecision: Equatable, Sendable {
    case learned(String)
    case rejected(String)
    case failed(String, reason: String)
}

enum ProperNounLearningEvaluationError: Error {
    case unavailableProvider
    case invalidResponse
}

@MainActor
protocol ProperNounLearningEvaluating: Sendable {
    func evaluate(_ candidate: ProperNounLearningCandidate) async throws -> ProperNounLearningDecision
}

struct LLMProperNounTermEvaluator: ProperNounLearningEvaluating, Sendable {
    typealias ProviderFactory = @MainActor @Sendable () -> LLMProvider?
    private let providerFactory: ProviderFactory
    init(providerFactory: @escaping ProviderFactory) { self.providerFactory = providerFactory }

    func evaluate(_ candidate: ProperNounLearningCandidate) async throws -> ProperNounLearningDecision {
        guard let provider = providerFactory() else { throw ProperNounLearningEvaluationError.unavailableProvider }
        return try await provider.classifyProperNounLearningCandidate(candidate)
    }
}

@MainActor
struct PostInjectionDictionaryLearner: PostInjectionDictionaryLearning, Sendable {
    static let observationDuration: Duration = .seconds(30)
    static let pollInterval: Duration = .milliseconds(500)
    static let stabilizationDuration: Duration = .milliseconds(1500)
    nonisolated static let maxLearnedTermLength = 48

    typealias SnapshotProvider = @MainActor @Sendable (pid_t?, String?) -> FocusedElementTextSnapshot?
    typealias Sleep = @Sendable (Duration) async -> Void
    typealias Now = @MainActor @Sendable () -> Duration

    private let snapshotProvider: SnapshotProvider
    private let sleep: Sleep
    private let now: Now
    private let termEvaluator: any ProperNounLearningEvaluating

    init(
        snapshotProvider: @escaping SnapshotProvider = { pid, bundle in
            FocusedElementTextSnapshotReader().read(targetPID: pid, targetBundleID: bundle, onFailure: { reason in
                DiagnosticsLogger.shared.log(sessionID: "dictionary", event: "dictionary_snapshot_unavailable", detail: reason.rawValue)
            })
        },
        termEvaluator: any ProperNounLearningEvaluating,
        sleep: @escaping Sleep = { try? await Task.sleep(for: $0) },
        now: @escaping Now = { .seconds(ProcessInfo.processInfo.systemUptime) }
    ) {
        self.snapshotProvider = snapshotProvider
        self.termEvaluator = termEvaluator
        self.sleep = sleep
        self.now = now
    }

    func observe(
        beforeInjection: FocusedElementTextSnapshot,
        insertedText: String,
        store: PersonalDictionaryStore,
        shouldContinue: @escaping @MainActor @Sendable () -> Bool,
        onObservation: @escaping @MainActor @Sendable (PostInjectionObservationEvent) -> Void = { _ in },
        onDecision: @escaping @MainActor @Sendable (PostInjectionLearningDecision) -> Void
    ) async {
        onObservation(.started)
        guard !beforeInjection.isComposing, !insertedText.isEmpty,
              let selection = Range(beforeInjection.selection, in: beforeInjection.value) else {
            onObservation(.invalidInput)
            return
        }
        let prefix = String(beforeInjection.value[..<selection.lowerBound])
        let suffix = String(beforeInjection.value[selection.upperBound...])
        let expected = prefix + insertedText + suffix
        func current() -> FocusedElementTextSnapshot? {
            guard shouldContinue(), !Task.isCancelled else {
                onObservation(.cancelled)
                return nil
            }
            guard let snapshot = snapshotProvider(beforeInjection.pid, beforeInjection.bundleID) else {
                onObservation(.targetUnavailable)
                return nil
            }
            guard snapshot.belongsToSameField(as: beforeInjection) else {
                onObservation(.targetChanged)
                return nil
            }
            return snapshot
        }

        // A posted paste event is not proof that the original field received the text.
        let verificationDeadline = now() + .seconds(1)
        var baseline: FocusedElementTextSnapshot?
        while now() <= verificationDeadline {
            guard let snapshot = current() else { return }
            if snapshot.value == expected, !snapshot.isComposing,
               snapshot.selection == NSRange(location: prefix.utf16.count + insertedText.utf16.count, length: 0) {
                baseline = snapshot
                break
            }
            // Only the pre-insertion state may be retried. Other edits are ambiguous.
            guard snapshot.value == beforeInjection.value else {
                if snapshot.value == expected {
                    onObservation(snapshot.isComposing ? .baselineCompositionActive : .baselineSelectionMismatch)
                } else {
                    onObservation(.baselineMismatch)
                }
                return
            }
            await sleep(Self.pollInterval)
        }
        guard var previous = baseline else {
            onObservation(.baselineTimedOut)
            return
        }
        onObservation(.baselineVerified)
        let deadline = now() + Self.observationDuration
        var stableSince = now()
        var evaluatedVersions = Set<String>()

        while now() < deadline {
            await sleep(Self.pollInterval)
            guard now() < deadline else { break }
            guard let snapshot = current() else { return }
            guard snapshot.value.hasPrefix(prefix), snapshot.value.hasSuffix(suffix),
                  snapshot.value.count >= prefix.count + suffix.count else {
                onObservation(.outsideInsertedRange)
                return
            }
            let edited = String(snapshot.value.dropFirst(prefix.count).dropLast(suffix.count))
            guard !edited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                onObservation(.fieldCleared)
                return
            }
            // Limit the edit envelope without treating delete-then-retype as a final correction.
            if let change = Self.extractReplacement(from: insertedText, to: edited),
               change.oldSpan.count > 64 || change.newSpan.count > 64 {
                onObservation(.editTooLarge)
                return
            }
            if abs(edited.count - insertedText.count) > 64 {
                onObservation(.editTooLarge)
                return
            }

            if snapshot != previous || snapshot.isComposing || snapshot.selection.length != 0 {
                if snapshot.value != previous.value { onObservation(.textChanged) }
                if snapshot.selection != previous.selection { onObservation(.selectionChanged) }
                if snapshot.selection.length != 0, previous.selection.length == 0 { onObservation(.selectionActive) }
                if snapshot.isComposing, !previous.isComposing { onObservation(.compositionActive) }
                previous = snapshot
                stableSince = now()
                continue
            }
            guard now() - stableSince >= Self.stabilizationDuration,
                  edited != insertedText, !evaluatedVersions.contains(edited) else { continue }
            guard evaluatedVersions.count < 3 else {
                onObservation(.evaluationLimit)
                return
            }
            evaluatedVersions.insert(edited)
            guard let candidate = Self.makeCandidate(from: insertedText, to: edited) else { continue }
            onObservation(.evaluating)

            let validity = ObservationValidity()
            let monitor = Task { @MainActor in
                while !Task.isCancelled {
                    await sleep(Self.pollInterval)
                    guard !Task.isCancelled else { return }
                    guard now() < deadline, let latest = current(), latest == snapshot else {
                        validity.isValid = false
                        return
                    }
                }
            }
            defer { monitor.cancel() }
            do {
                let decision = try await termEvaluator.evaluate(candidate)
                // No store mutation or feedback from cancelled, expired, edited or refocused requests.
                guard validity.isValid, now() < deadline, let latest = current(), latest == snapshot else {
                    onObservation(.evaluationInvalidated)
                    return
                }
                switch decision {
                case .accept(let term, let start):
                    guard Self.validatedTerm(term, start: start, candidate: candidate) != nil else {
                        onDecision(.rejected(candidate.replacedSpan))
                        continue
                    }
                    if try store.addLearnedTermIfNeeded(term) { onDecision(.learned(term)) }
                    else { onObservation(.existingTerm) }
                case .reject:
                    onDecision(.rejected(candidate.replacedSpan))
                }
            } catch {
                guard validity.isValid, now() < deadline, let latest = current(), latest == snapshot else {
                    onObservation(.evaluationInvalidated)
                    return
                }
                onDecision(.failed(candidate.replacedSpan, reason: "learning_failed"))
            }
        }
        onObservation(.observationTimedOut)
    }

    private final class ObservationValidity { var isValid = true }

    nonisolated static func extractReplacement(from original: String, to updated: String) -> LearnedTermReplacement? {
        let old = Array(original), new = Array(updated)
        var prefix = 0, suffix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        while suffix < min(old.count, new.count) - prefix,
              old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
        let oldEnd = old.count - suffix, newEnd = new.count - suffix
        guard prefix < oldEnd, prefix < newEnd else { return nil }
        return .init(oldSpan: String(old[prefix..<oldEnd]), newSpan: String(new[prefix..<newEnd]),
                     surroundingTextBefore: String(new[..<prefix]), surroundingTextAfter: String(new[newEnd...]))
    }

    nonisolated static func makeCandidate(from original: String, to updated: String) -> ProperNounLearningCandidate? {
        guard let change = extractReplacement(from: original, to: updated),
              change.oldSpan.count <= 64, change.newSpan.count <= 64 else { return nil }
        let before = String(change.surroundingTextBefore.suffix(24))
        let after = String(change.surroundingTextAfter.prefix(24))
        return .init(originalText: before + change.oldSpan + after,
                     updatedText: before + change.newSpan + after,
                     originalSpan: change.oldSpan, replacedSpan: change.newSpan, changeStart: before.count)
    }

    nonisolated static func learnableTerm(from text: String) -> String? {
        guard text == text.trimmingCharacters(in: .whitespacesAndNewlines),
              (2...maxLearnedTermLength).contains(text.count),
              text.unicodeScalars.contains(where: CharacterSet.letters.contains),
              text.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0)
                  || CharacterSet.nonBaseCharacters.contains($0)
                  || CharacterSet.decimalDigits.contains($0)
                  || " +#.-_&'".unicodeScalars.contains($0) }),
              !text.hasSuffix(".") else { return nil }
        return text
    }

    nonisolated static func validatedTerm(_ term: String, start: Int, candidate: ProperNounLearningCandidate) -> String? {
        let text = Array(candidate.updatedText), glyphs = Array(term)
        guard learnableTerm(from: term) != nil, start >= 0, start <= text.count,
              glyphs.count <= text.count - start else { return nil }
        let end = start + glyphs.count
        guard start <= candidate.changeStart,
              end >= candidate.changeStart + candidate.replacedSpan.count,
              Array(text[start..<end]) == glyphs else { return nil }
        // Reject extraction of a fragment inside an English identifier (e.g. "Echo" in "MemoEcho").
        func identifier(_ c: Character) -> Bool {
            c.isASCII && (c.isLetter || c.isNumber || c == "_")
        }
        if start > 0, identifier(text[start - 1]), identifier(glyphs[0]) { return nil }
        if end < text.count, identifier(text[end]), identifier(glyphs[glyphs.count - 1]) { return nil }
        return term
    }
}
