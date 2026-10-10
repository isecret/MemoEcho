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
    private(set) var hotwords: VolcengineHotwords
    var target: TextInjectionFocus?
    var context: WindowContextSnapshot?
    var realtimeAudio: RealtimeRecoveryAudio?
    var pendingSegments: [SealedSegment]
    var transcripts: [String]
    var polished: PolishResult?
    var finalText: String?
    var failure: MemoEchoError?
    var failureReason: HUDFailureReason?
    var outputAttempted = false
    var isPartialRecording = false
    private(set) var expiresAt: Date?
    private(set) var discarded = false

    init(segments: [SealedSegment] = [], transcripts: [String], mode: TextProcessingMode,
         language: TranslationTargetLanguage, asrPlatform: ASRPlatform,
         target: TextInjectionFocus?, context: WindowContextSnapshot?, hotwords: VolcengineHotwords = .empty) {
        pendingSegments = segments.sorted { $0.index < $1.index }
        self.transcripts = transcripts
        self.mode = mode
        self.language = language
        self.asrPlatform = asrPlatform
        self.hotwords = hotwords
        self.target = target
        self.context = context
    }

    var stage: Stage {
        if realtimeAudio != nil || !pendingSegments.isEmpty { return .recognition }
        if polished == nil { return .polish }
        if finalText == nil { return .translation }
        return .output
    }

    var canRetry: Bool {
        guard !discarded else { return false }
        guard stage == .output else { return true }
        guard !outputAttempted, let target else { return false }
        return target.scope != .window || (target.continuity != nil && target.continuity?.isInvalidated == false)
    }

    func retainUntilExpiration(now: Date, lifetime: TimeInterval) {
        // A failed retry must not extend the original privacy deadline.
        if expiresAt == nil { expiresAt = now.addingTimeInterval(lifetime) }
    }

    func isValid(at now: Date) -> Bool { !discarded && (expiresAt.map { now < $0 } ?? true) }

    func discard() {
        discarded = true
        hotwords = .empty
        failure = nil
        failureReason = nil
        realtimeAudio = nil
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
    var recognizeRealtime: ((RealtimeRecoveryAudio) async throws -> [String])? = nil

    func process(_ checkpoint: SessionRecoveryCheckpoint,
                 shouldContinue: () -> Bool,
                 onStage: (SessionRecoveryCheckpoint.Stage) -> Void) async throws -> String {
        func check() throws {
            guard !Task.isCancelled, shouldContinue(), checkpoint.isValid(at: Date()) else { throw CancellationError() }
        }
        try check()
        if let audio = checkpoint.realtimeAudio {
            guard let recognizeRealtime else { throw RealtimeASRError.configuration }
            onStage(.recognition)
            let texts = try await recognizeRealtime(audio)
            try check()
            checkpoint.transcripts.append(contentsOf: texts)
            checkpoint.realtimeAudio = nil
        }
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

/// Immutable action identity shared by the native menu and failure HUD.
struct RecoveryPresentation {
    let id: UUID
    let reason: String
    let detail: String
    let retryTitle: String?
    let hudRetryTitle: String?
    let settingsTab: SettingsTab?
    let canCopy: Bool
    let outputAttempted: Bool

    @MainActor
    init(checkpoint: SessionRecoveryCheckpoint, readiness: VoiceInputReadiness) {
        id = checkpoint.id
        reason = checkpoint.failureReason?.shortLabel ?? (checkpoint.isPartialRecording ? "录音中断" : "处理未完成")
        detail = checkpoint.failure?.recoveryUserMessage ?? "上次输入尚未完成，可以继续处理或丢弃。"
        let requiredTab: SettingsTab?
        switch checkpoint.failure {
        case .llmConfigurationIncomplete, .invalidLLMConfiguration:
            requiredTab = readiness.llm.isReady ? nil : .ai
        case .cloudASRConfigurationIncomplete, .cloudASRAuthenticationFailure,
             .asrModelMissing, .asrBinaryNotFound, .asrRuntimeMissing, .asrPlatformNotReady:
            requiredTab = readiness.asr.isReady ? nil : .asr
        case .accessibilityPermissionDenied:
            requiredTab = readiness.accessibility.isReady ? nil : .permissions
        case .microphonePermissionDenied:
            requiredTab = readiness.microphone.isReady ? nil : .permissions
        default: requiredTab = nil
        }
        settingsTab = requiredTab
        retryTitle = checkpoint.canRetry && requiredTab == nil
            ? (checkpoint.isPartialRecording ? "继续处理已录内容" : checkpoint.stage.retryTitle) : nil
        hudRetryTitle = retryTitle == nil ? nil : (checkpoint.isPartialRecording ? "继续" : "重试")
        canCopy = checkpoint.finalText.map { !$0.isEmpty } ?? false
        outputAttempted = checkpoint.outputAttempted
    }
}

private extension MemoEchoError {
    /// Details may contain provider payloads or diagnostics; recovery UI never echoes those fields.
    var recoveryUserMessage: String {
        switch self {
        case .asrPlatformNotReady: "语音识别未就绪，请检查语音设置。"
        case .asrProcessFailure: "本地语音识别失败，请检查模型后重试。"
        case .audioPreprocessFailure: "音频预处理失败，请重试处理已录内容。"
        case .cloudASRInvalidResponse: "云端识别响应异常，请重试或检查语音服务配置。"
        case .invalidLLMConfiguration: "AI 模型配置异常，请检查模型设置。"
        case .textInjectionFailure: "未能确认文字已写入原输入框，请先检查原输入框。可复制结果后手动粘贴。"
        default: userMessage
        }
    }
}
