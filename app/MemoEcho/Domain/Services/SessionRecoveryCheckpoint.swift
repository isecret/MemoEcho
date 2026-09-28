import Foundation

/// Only the inputs needed by the next unfinished stage. Never encoded or written to disk.
@MainActor
@Observable
final class SessionRecoveryCheckpoint {
    enum Stage: String, Sendable {
        case recognition, polish, translation, output
        var retryTitle: String {
            switch self {
            case .recognition: "重试识别"
            case .polish: "重试整理"
            case .translation: "重试翻译"
            case .output: "重试写入"
            }
        }
    }

    let id = UUID()
    let mode: TextProcessingMode
    let language: TranslationTargetLanguage
    let asrPlatform: ASRPlatform
    var target: TextInjectionFocus?
    var context: WindowContextSnapshot?
    var pendingSegments: [SealedSegment]
    var transcripts: [String]
    var polished: PolishResult?
    var finalText: String?
    var outputAttempted = false
    var isPartialRecording = false
    private(set) var expiresAt: Date?
    private(set) var discarded = false

    init(segments: [SealedSegment] = [], transcripts: [String], mode: TextProcessingMode,
         language: TranslationTargetLanguage, asrPlatform: ASRPlatform,
         target: TextInjectionFocus?, context: WindowContextSnapshot?) {
        pendingSegments = segments.sorted { $0.index < $1.index }
        self.transcripts = transcripts
        self.mode = mode
        self.language = language
        self.asrPlatform = asrPlatform
        self.target = target
        self.context = context
    }

    var stage: Stage {
        if !pendingSegments.isEmpty { return .recognition }
        if polished == nil { return .polish }
        if finalText == nil { return .translation }
        return .output
    }

    var canRetry: Bool { !discarded && (stage != .output || (!outputAttempted && target != nil)) }

    func retainUntilExpiration(now: Date, lifetime: TimeInterval) {
        // A failed retry must not extend the original privacy deadline.
        if expiresAt == nil { expiresAt = now.addingTimeInterval(lifetime) }
    }

    func isValid(at now: Date) -> Bool { !discarded && (expiresAt.map { now < $0 } ?? true) }

    func discard() {
        discarded = true
        pendingSegments.removeAll()
        transcripts.removeAll()
        polished = nil
        finalText = nil
        target = nil
        context = nil
    }
}

/// Shared by the first attempt and recovery; completed stages are never rerun.
@MainActor
struct SessionRecoveryProcessor {
    var recognize: (SealedSegment) async throws -> String
    var polish: ([String], WindowContextSnapshot?) async throws -> PolishResult
    var translate: (String, TranslationTargetLanguage, WindowContextSnapshot?) async throws -> String

    func process(_ checkpoint: SessionRecoveryCheckpoint,
                 shouldContinue: () -> Bool,
                 onStage: (SessionRecoveryCheckpoint.Stage) -> Void) async throws -> String {
        func check() throws {
            guard !Task.isCancelled, shouldContinue(), checkpoint.isValid(at: Date()) else { throw CancellationError() }
        }
        try check()
        while let segment = checkpoint.pendingSegments.first {
            onStage(.recognition)
            if segment.voicedDetected {
                let text = try await recognize(segment)
                try check()
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw MemoEchoError.asrEmptyTranscript
                }
                checkpoint.transcripts.append(text)
            }
            checkpoint.pendingSegments.removeFirst()
            try validateTranscriptLength(checkpoint.transcripts)
        }
        try validateTranscriptLength(checkpoint.transcripts)
        if checkpoint.polished == nil {
            guard !checkpoint.transcripts.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MemoEchoError.asrEmptyTranscript
            }
            onStage(.polish)
            let result = try await polish(checkpoint.transcripts, checkpoint.context)
            try check()
            checkpoint.polished = result
            // The original transcript is no longer needed once polishing succeeded.
            checkpoint.transcripts.removeAll()
            if checkpoint.mode == .polish { checkpoint.finalText = result.text }
        }
        if checkpoint.finalText == nil, let polished = checkpoint.polished {
            onStage(.translation)
            let text = try await translate(polished.text, checkpoint.language, checkpoint.context)
            try check()
            checkpoint.finalText = text
        }
        try check()
        guard let text = checkpoint.finalText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MemoEchoError.llmEmptyResponse
        }
        onStage(.output)
        return text
    }

    private func validateTranscriptLength(_ transcripts: [String]) throws {
        let count = transcripts.reduce(0) { $0 + $1.count }
        if count > 8000 { throw MemoEchoError.transcriptTooLong(charCount: count) }
    }
}
