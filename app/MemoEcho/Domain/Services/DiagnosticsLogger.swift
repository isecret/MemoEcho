import Foundation
import os

/// 主链路诊断日志器，使用 macOS Unified Logging 记录各阶段耗时与结果摘要
///
/// All builds record only durations, sizes and classification; never user text or audio.
final class DiagnosticsLogger: Sendable {

    static let shared = DiagnosticsLogger()

    private let logger = Logger(
        subsystem: "me.wangmao.memoecho",
        category: "Session"
    )

    private init() {}

    // MARK: - Session Lifecycle

    func sessionStarted(sessionID: String, targetBundleID: String?) {
        logger.info(
            "[\(sessionID)] session_started | target=\(targetBundleID ?? "unknown", privacy: .public)"
        )
    }

    func sessionEnded(
        sessionID: String,
        result: SessionDiagnostics
    ) {
        let source = result.resultSource ?? "none"
        let errorType = result.errorClassification ?? "none"

        logger.info(
            """
            [\(sessionID)] session_ended \
            | recording=\(result.recordingMs)ms \
            | denoise=\(result.denoiseMs ?? -1)ms \
            | asr_wait=\(result.asrWaitMs ?? -1)ms \
            | asr_work=\(result.asrWorkMs ?? -1)ms \
            | context_wait=\(result.latency?.contextWaitMs ?? -1)ms \
            | llm=\(result.llmMs ?? -1)ms \
            | injection=\(result.injectionMs ?? -1)ms \
            | total=\(result.totalMs)ms \
            | origin=\(result.latency?.origin.rawValue ?? "unavailable", privacy: .public) \
            | dispatch=\(result.latency?.dispatchMs ?? -1)ms \
            | dispatch_to_cleanup=\(result.latency?.dispatchToCleanupMs ?? -1)ms \
            | source=\(source, privacy: .public) \
            | error=\(errorType, privacy: .public) \
            | target=\(result.targetBundleID ?? "unknown", privacy: .public)
            """
        )
    }

    // MARK: - Short Recording Cancelled

    func shortRecordingCancelled(sessionID: String, durationMs: Int) {
        logger.info(
            "[\(sessionID)] short_recording_cancelled | duration=\(durationMs)ms"
        )
    }

    // MARK: - ASR/LLM Comparison

    func asrCompleted(sessionID: String, text: String, durationMs: Int, coldStart: Bool = false, warmupWaitMs: Int = 0) {
        let hash = Self.textHash(text)
        logger.info(
            "[\(sessionID)] asr_completed | length=\(text.count) | hash=\(hash, privacy: .public) | duration=\(durationMs)ms | cold_start=\(coldStart) | warmup_wait=\(warmupWaitMs)ms"
        )
    }

    func llmCompleted(sessionID: String, text: String, source: String, durationMs: Int) {
        let hash = Self.textHash(text)
        logger.info(
            "[\(sessionID)] llm_completed | length=\(text.count) | hash=\(hash, privacy: .public) | source=\(source, privacy: .public) | duration=\(durationMs)ms"
        )
    }

    // MARK: - Structured Processing Diagnostics

    /// 记录结构化处理结果，供调试判断本次请求走了哪条路径
    func structuredProcessingCompleted(
        sessionID: String,
        mode: String,
        correctionApplied: Bool
    ) {
        #if DEBUG
        logger.debug(
            """
            [\(sessionID)] structured_processing \
            | mode=\(mode, privacy: .public) \
            | correction=\(correctionApplied)
            """
        )
        #else
        logger.info(
            """
            [\(sessionID)] structured_processing \
            | mode=\(mode, privacy: .public) \
            | correction=\(correctionApplied)
            """
        )
        #endif
    }

    // MARK: - Error Logging

    func sessionError(sessionID: String, error: MemoEchoError) {
        logger.error(
            "[\(sessionID)] session_error | type=\(error.diagnosticClassification, privacy: .public)"
        )
    }

    func sessionCancelled(sessionID: String) {
        logger.info("[\(sessionID)] session_cancelled")
    }

    // MARK: - Denoising

    func denoiseCompleted(sessionID: String, durationMs: Int) {
        logger.info(
            "[\(sessionID)] denoise_completed | duration=\(durationMs)ms"
        )
    }

    func denoiseFailed(sessionID: String, reason: String) {
        logger.error(
            "[\(sessionID)] denoise_failed | reason=\(reason, privacy: .public)"
        )
    }

    // MARK: - Segment Diagnostics

    func segmentSealed(sessionID: String, index: Int, sampleCount: Int, reason: String) {
        let durationMs = Int(Double(sampleCount) / 16.0)
        logger.info(
            "[\(sessionID)] segment_sealed | index=\(index) | samples=\(sampleCount) | duration=\(durationMs)ms | reason=\(reason, privacy: .public)"
        )
    }

    func segmentASRCompleted(sessionID: String, segment: SegmentDiagnostics) {
        logger.info(
            """
            [\(sessionID)] segment_asr_completed \
            | index=\(segment.index) \
            | audio=\(segment.audioDurationMs)ms \
            | denoise=\(segment.denoiseMs)ms \
            | asr=\(segment.asrMs)ms \
            | chars=\(segment.charCount) \
            | reason=\(segment.sealReason, privacy: .public)
            """
        )
    }

    // MARK: - Injection Diagnostics

    func injectionCompleted(
        sessionID: String,
        path: TextInjector.InjectionPath,
        breakdown: TextInjector.InjectionBreakdown
    ) {
        logger.info(
            """
            [\(sessionID)] injection_breakdown \
            | path=\(path.rawValue, privacy: .public) \
            | activate_target=\(breakdown.activateTargetMs)ms \
            | focus_before=\(breakdown.focusBeforeMs)ms \
            | pasteboard_backup=\(breakdown.pasteboardBackupMs)ms \
            | pasteboard_write=\(breakdown.pasteboardWriteMs)ms \
            | pasteboard_propagation=\(breakdown.pasteboardPropagationMs)ms \
            | post_paste_shortcut=\(breakdown.postPasteShortcutMs)ms \
            | paste_consumption=\(breakdown.pasteConsumptionMs)ms \
            | pasteboard_restore=\(breakdown.pasteboardRestoreMs)ms \
            | dispatch=\(breakdown.dispatchMs)ms \
            | cleanup=\(breakdown.cleanupMs)ms \
            | total=\(breakdown.totalMs)ms
            """
        )
    }

    func latencyMilestone(sessionID: String, milestone: SessionLatencyTimeline.Milestone,
                          snapshot: SessionLatencySnapshot) {
        log(sessionID: sessionID, event: "pipeline_latency", detail:
            "origin=\(snapshot.origin.rawValue) path=\(snapshot.path.rawValue) milestone=\(milestone.rawValue) "
            + "elapsed_ms=\(snapshot.elapsedMs) capture_closed_ms=\(snapshot.captureClosedMs ?? -1) "
            + "asr_final_ms=\(snapshot.asrFinalMs ?? -1) context_ready_ms=\(snapshot.contextReadyMs ?? -1) "
            + "context_wait_ms=\(snapshot.contextWaitMs) llm_complete_ms=\(snapshot.llmCompleteMs ?? -1) "
            + "dispatch_ms=\(snapshot.dispatchMs ?? -1) cleanup_complete_ms=\(snapshot.cleanupCompleteMs ?? -1)")
        if milestone == .dispatched, let dispatchMs = snapshot.dispatchMs {
            let event = snapshot.origin == .recordingStop ? "stop_to_dispatch" : "recovery_to_dispatch"
            log(sessionID: sessionID, event: event, detail: "ms=\(dispatchMs)")
        }
    }

    func llmRequest(sessionID: String, metrics: LLMRequestMetrics) {
        log(sessionID: sessionID, event: "llm_request_size", detail:
            "purpose=\(metrics.purpose.rawValue) system_chars=\(metrics.systemCharacters) input_chars=\(metrics.inputCharacters) "
            + "dictionary_terms=\(metrics.dictionaryTerms) dictionary_chars=\(metrics.dictionaryCharacters) "
            + "context_chars=\(metrics.contextCharacters) auxiliary_utf8_bytes=\(metrics.auxiliaryUTF8Bytes) "
            + "request_body_bytes=\(metrics.requestBodyBytes) thinking_disabled=\(metrics.thinkingDisabled ? 1 : 0)")
    }

    // MARK: - General Events

    func log(sessionID: String, event: String, detail: String? = nil) {
        if let detail {
            logger.info("[\(sessionID)] \(event, privacy: .public) | detail=\(detail, privacy: .public)")
        } else {
            logger.info("[\(sessionID)] \(event, privacy: .public)")
        }
    }

    // MARK: - Helpers

    private static func textHash(_ text: String) -> String {
        var hasher = Hasher()
        hasher.combine(text)
        let hash = hasher.finalize()
        return String(format: "%08x", abs(hash))
    }
}

// MARK: - Session Diagnostics Data

struct SessionDiagnostics: Sendable {
    var recordingMs: Int = 0
    var denoiseMs: Int?
    var asrWaitMs: Int?
    var asrWorkMs: Int?
    var llmMs: Int?
    var injectionMs: Int?
    var totalMs: Int = 0
    var latency: SessionLatencySnapshot?
    var resultSource: String?
    var errorClassification: String?
    var targetBundleID: String?
    // 分段相关
    var segmentCount: Int = 0
    var segmentDiagnostics: [SegmentDiagnostics] = []
}

/// 单段 ASR 诊断数据
struct SegmentDiagnostics: Sendable {
    let index: Int
    let audioDurationMs: Int
    let denoiseMs: Int
    let asrMs: Int
    let charCount: Int
    let sealReason: String
}

// MARK: - MemoEchoError Diagnostic Classification

extension MemoEchoError {
    /// 用于诊断日志的错误分类标识，不含用户文本或敏感信息
    var diagnosticClassification: String {
        switch self {
        case .audioCaptureInterrupted: "audio_capture_interrupted"
        case .microphonePermissionDenied: "microphone_permission_denied"
        case .audioRecordingUnavailable: "audio_recording_unavailable"
        case .accessibilityPermissionDenied: "accessibility_permission_denied"
        case .asrEmptyAudio: "asr_empty_audio"
        case .asrEmptyTranscript: "asr_empty_transcript"
        case .asrPlatformNotReady: "asr_platform_not_ready"
        case .asrBinaryNotFound: "asr_binary_not_found"
        case .asrModelMissing: "asr_model_missing"
        case .asrRuntimeMissing: "asr_runtime_missing"
        case .asrProcessFailure: "asr_process_failure"
        case .audioPreprocessFailure: "audio_preprocess_failure"
        case .cloudASRConfigurationIncomplete: "cloud_asr_configuration_incomplete"
        case .cloudASRAuthenticationFailure: "cloud_asr_authentication_failure"
        case .cloudASRNetworkFailure: "cloud_asr_network_failure"
        case .cloudASREmptyResponse: "cloud_asr_empty_response"
        case .cloudASRInvalidResponse: "cloud_asr_invalid_response"
        case .llmConfigurationIncomplete: "llm_configuration_incomplete"
        case .invalidLLMConfiguration: "invalid_llm_configuration"
        case .llmNetworkFailure: "llm_network_failure"
        case .llmEmptyResponse: "llm_empty_response"
        case .llmInvalidResponse: "llm_invalid_response"
        case .textInjectionFailure: "text_injection_failure"
        case .sessionCancelled: "session_cancelled"
        case .transcriptTooLong: "transcript_too_long"
        }
    }
}
