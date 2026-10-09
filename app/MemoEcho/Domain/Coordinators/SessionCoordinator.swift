import AppKit
import Foundation

/// 试用有独立且不可回退的输出目的地，避免焦点变化时把文字写到其它应用。
enum SessionTextOutput: Sendable {
    case focusedApplication
    case onboardingTrial(@MainActor @Sendable (String) -> Bool)

    var isOnboardingTrial: Bool {
        if case .onboardingTrial = self { return true }
        return false
    }

    @MainActor
    func deliver(_ text: String, inject: (String) async throws -> TextInjector.InjectionResult) async throws -> TextInjector.InjectionResult? {
        switch self {
        case .focusedApplication:
            return try await inject(text)
        case .onboardingTrial(let receive):
            guard receive(text) else { throw MemoEchoError.sessionCancelled }
            return nil
        }
    }
}

/// 主链路会话编排器，负责录音、识别、润色、注入的串行调度
@MainActor
@Observable
final class SessionCoordinator {
    private(set) var state: SessionState = .idle {
        didSet { if state != oldValue { onStateChanged?(oldValue, state) } }
    }
    var onStateChanged: (@MainActor @Sendable (SessionState, SessionState) -> Void)?
    private(set) var lastRecordedAudio: Data?
    private(set) var currentError: MemoEchoError?
    private(set) var lastResult: SessionResult?
    private(set) var targetApplicationPID: pid_t?
    private(set) var targetApplicationBundleID: String?

    /// 最近一次注入失败的文本，仅内存态，供菜单栏复制使用
    private(set) var lastInjectionFailureText: String?

    /// Invalidates only UI owned by the released checkpoint.
    var onRecoveryInvalidated: (@MainActor (UUID) -> Void)?
    private var recoveryOwnerGeneration: UInt64?
    private(set) var currentErrorRecoveryID: UUID?

    /// Revalidate captured menu/HUD actions, including when an open menu outlives its result.
    func actionableRecovery(id: UUID) -> SessionRecoveryCheckpoint? {
        guard state.allowsRecordingStart, !isRecovering, let recovery,
              recovery.id == id, recovery.isValid(at: Date()) else { return nil }
        return recovery
    }

    @discardableResult
    func copyRecovery(id: UUID, write: (String) -> Bool) -> Bool {
        guard let text = actionableRecovery(id: id)?.finalText, !text.isEmpty else { return false }
        return write(text)
    }

    private func invalidateRecoveryPresentation(_ id: UUID) {
        if currentErrorRecoveryID == id {
            currentError = nil
            currentErrorRecoveryID = nil
        }
        onRecoveryInvalidated?(id)
    }

    var onFeedbackEvent: (@MainActor @Sendable (SessionFeedbackEvent) -> Void)?

    /// 返回当前音频录制电平（0-1），供 HUD 声波动画使用
    func currentAudioLevel() -> Float {
        audioRecorder.currentLevel()
    }

    private let audioRecorder: any AudioRecording
    private let audioPreprocessor = AudioPreprocessor()
    private let permissionsManager: PermissionsManager
    private let configStore: ConfigStore
    private let audioDeviceManager: AudioDeviceManager
    private let textInjector: TextInjector
    private(set) var recovery: SessionRecoveryCheckpoint?
    private(set) var isRecovering = false
    private var recoveryExpiryTask: Task<Void, Never>?
    private let realtimeSessionFactory: (@Sendable (ASRConfig) throws -> any RealtimeASRSession)?
    private let asrProviderOverride: ((ASRConfig) -> any ASRProvider)?
    private let recoveryLifetime: TimeInterval
    private let recoveryProcessorFactory: ((SessionRecoveryCheckpoint) -> SessionRecoveryProcessor)?
    private var targetInput: TextInjectionFocus?
    private let windowContextService = WindowContextService()
    private let diagnostics = DiagnosticsLogger.shared

    /// SenseVoice 运行时管理器，跨 session 复用
    private let asrRuntimeManager = SenseVoiceRuntimeManager()

    private var processingTask: Task<Void, Never>?
    private var windowContextTask: Task<Void, Never>?
    private var postInjectionLearningTask: Task<Void, Never>?
    private var resetToIdleTask: Task<Void, Never>?
    private var recordingStartTask: Task<Void, Never>?
    private var soundCueTask: Task<Void, Never>?
    private var recordingStopTask: Task<Void, Never>?
    private var sessionGeneration: UInt64 = 0
    private(set) var currentSessionID: String = ""
    private var processingMode: TextProcessingMode = .polish
    private var textOutput: SessionTextOutput = .focusedApplication
    var isOnboardingTrial: Bool { textOutput.isOnboardingTrial }

    // 分段相关
    private let segmenter = AudioSegmenter()
    private var realtimePipeline: RealtimeRecognitionPipeline?
    private var recordingRecoveryBuffer: RecordingRecoveryBuffer?
    private var recordingASRPlatform: ASRPlatform = .localSenseVoice
    private(set) var recordingWarning: String?
    private var segmentStream: AsyncStream<SealedSegment>?
    private var segmentContinuation: AsyncStream<SealedSegment>.Continuation?
    /// 录音时长（毫秒），finishRecording 写入，processSegmentedAudio 读取
    private var recordingDurationMs: Int = 0
    private var recordingStoppedAt: Date?
    private var recordingStopRequestedAt: Date?
    private var capturedWindowContext: WindowContextSnapshot?
    private let ensureMicrophoneAuthorized: @MainActor @Sendable () throws -> Void
    private let ensureAccessibilityAuthorized: @MainActor @Sendable () throws -> Void

    init(
        permissionsManager: PermissionsManager,
        configStore: ConfigStore,
        audioDeviceManager: AudioDeviceManager,
        audioRecorder: any AudioRecording = AudioRecorder(),
        dictionaryStore: PersonalDictionaryStore? = nil,
        postInjectionLearner: (any PostInjectionDictionaryLearning)? = nil,
        ensureMicrophoneAuthorized: (@MainActor @Sendable () throws -> Void)? = nil,
        ensureAccessibilityAuthorized: (@MainActor @Sendable () throws -> Void)? = nil,
        textInjector: TextInjector = TextInjector(),
        recoveryLifetime: TimeInterval = 600,
        recoveryProcessorFactory: ((SessionRecoveryCheckpoint) -> SessionRecoveryProcessor)? = nil,
        asrProviderOverride: ((ASRConfig) -> any ASRProvider)? = nil,
        realtimeSessionFactory: (@Sendable (ASRConfig) throws -> any RealtimeASRSession)? = nil
    ) {
        self.realtimeSessionFactory = realtimeSessionFactory
        self.asrProviderOverride = asrProviderOverride
        self.textInjector = textInjector
        self.recoveryLifetime = recoveryLifetime
        self.recoveryProcessorFactory = recoveryProcessorFactory
        self.permissionsManager = permissionsManager
        self.configStore = configStore
        self.audioDeviceManager = audioDeviceManager
        self.audioRecorder = audioRecorder
        self.dictionaryStore = dictionaryStore
        self.ensureMicrophoneAuthorized = ensureMicrophoneAuthorized
            ?? { try permissionsManager.ensureMicrophoneAuthorized() }
        self.ensureAccessibilityAuthorized = ensureAccessibilityAuthorized
            ?? { try permissionsManager.ensureAccessibilityAuthorized() }
        self.postInjectionLearner = postInjectionLearner ?? PostInjectionDictionaryLearner(
            termEvaluator: LLMProperNounTermEvaluator(
                providerFactory: {
                    guard configStore.isLLMConfigured else { return nil }
                    let config = configStore.llmConfig
                    let apiKey = configStore.openAIAPIKey
                    return LLMProvider(
                        baseURL: config.baseURL,
                        apiKey: apiKey,
                        model: config.model,
                        omitThinkingParameter: configStore.omitThinkingParameter,
                        onThinkingUnsupported: {
                            try? configStore.markThinkingParameterUnsupported(for: config, apiKey: apiKey)
                        }
                    )
                }
            )
        )
    }

    private let dictionaryStore: PersonalDictionaryStore?
    private let postInjectionLearner: any PostInjectionDictionaryLearning

    /// 开始录音
    func startRecording(output: SessionTextOutput = .focusedApplication) {
        guard state.allowsRecordingStart else { return }

        if state != .idle {
            recordingStartTask?.cancel()
            recordingStartTask = nil
            resetToIdleTask?.cancel()
            resetToIdleTask = nil
            clearWindowContextCapture()
            cancelPostInjectionLearning()
            state = .idle
            targetApplicationPID = nil
            targetApplicationBundleID = nil
        }

        currentError = nil
        currentErrorRecoveryID = nil
        recordingStoppedAt = nil
        recordingStopRequestedAt = nil
        recordingWarning = nil
        lastRecordedAudio = nil
        targetInput = nil
        textOutput = output
        lastResult = nil
        clearWindowContextCapture()
        cancelPostInjectionLearning()
        targetApplicationPID = output.isOnboardingTrial ? nil : NSWorkspace.shared.frontmostApplication?.processIdentifier
        targetApplicationBundleID = output.isOnboardingTrial ? nil : NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        sessionGeneration &+= 1
        currentSessionID = Self.generateSessionID()
        let recordingConfig = configStore.asrConfig
        let selectedPlatform = recordingConfig.selectedPlatform
        let sessionID = currentSessionID
        let targetBundleID = targetApplicationBundleID

        do {
            configStore.refreshLocalModelStatusFromDisk()
            try ensureMicrophoneAuthorized()
            try ensureAccessibilityAuthorized()
            if !output.isOnboardingTrial {
                targetInput = textInjector.captureTarget(pid: targetApplicationPID, bundleID: targetApplicationBundleID)
            }
            if !selectedPlatform.isRealtime { try ResourceValidator.validateDenoiseResources() }
            // 录音前检查 ASR 平台可用性
            guard configStore.isASRReady else {
                throw MemoEchoError.asrPlatformNotReady(detail: configStore.asrNotReadyReason ?? "未知")
            }
            // 本地 SenseVoice 额外校验运行时资源
            if configStore.asrConfig.selectedPlatform == .localSenseVoice {
                try ResourceValidator.validateASRResources()
            }
            state = .recording
            processingMode = .polish
            onFeedbackEvent?(.recordingStarted)

            let generation = sessionGeneration
            if !output.isOnboardingTrial {
                beginWindowContextCapture(
                    generation: generation,
                    sessionID: sessionID,
                    targetPID: targetApplicationPID,
                    targetBundleID: targetBundleID
                )
            }
            recordingStartTask?.cancel()
            recordingStartTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled, let self else { return }
                await self.beginRecording(
                    generation: generation,
                    sessionID: sessionID,
                    targetBundleID: targetBundleID,
                    selectedPlatform: selectedPlatform,
                    asrConfig: recordingConfig
                )
                if !Task.isCancelled, self.sessionGeneration == generation {
                    self.recordingStartTask = nil
                }
            }
        } catch {
            handleError(mapError(error))
        }
    }

    private func beginRecording(
        generation: UInt64,
        sessionID: String,
        targetBundleID: String?,
        selectedPlatform: ASRPlatform,
        asrConfig: ASRConfig
    ) async {
        guard generation == sessionGeneration, state == .recording else { return }

        do {
            let realtimeFactory = realtimeSessionFactory
            let realtime: RealtimeRecognitionPipeline? = selectedPlatform.isRealtime
                ? RealtimeRecognitionPipeline(sessionID: sessionID) {
                    try realtimeFactory?(asrConfig) ?? ASRProviderFactory.makeRealtimeSession(for: asrConfig)
                } : nil
            realtimePipeline = realtime
            // 配置分段器和 AsyncStream
            segmenter.reset()
            let recoveryBuffer = RecordingRecoveryBuffer()
            recordingRecoveryBuffer = recoveryBuffer
            recordingASRPlatform = selectedPlatform
            let (stream, continuation) = AsyncStream.makeStream(of: SealedSegment.self)
            segmentStream = stream
            segmentContinuation = continuation
            segmenter.onSegmentSealed = { segment in
                recoveryBuffer.append(segment)
                continuation.yield(segment)
            }

            // 配置录音器 PCM chunk 回调并启动录音
            // onPCMChunk 在 startRecording 内部 cleanup 后、startRunning 前设置，保证不被清理
            let captureDevice = audioDeviceManager.captureDeviceForRecording()
            audioRecorder.onCaptureEvent = { [weak self] event in
                guard let self, self.sessionGeneration == generation, self.state == .recording else { return }
                self.handleCaptureEvent(event)
            }
            try await audioRecorder.startRecording(
                device: captureDevice,
                retainFullAudio: realtime == nil,
                onPCMChunk: { [segmenter, realtime] chunk in
                    if let realtime { realtime.input.append(chunk) }
                    else { segmenter.appendPCMChunk(chunk) }
                }
            )
            guard !Task.isCancelled, generation == sessionGeneration, state == .recording else {
                if generation == sessionGeneration {
                    _ = audioRecorder.stopRecording()
                    cleanupSegmenterState()
                }
                return
            }

            diagnostics.sessionStarted(
                sessionID: sessionID,
                targetBundleID: targetBundleID
            )
            diagnostics.log(
                sessionID: sessionID,
                event: "recording_device_selected",
                detail: "name=\(captureDevice?.localizedName ?? "system_default") id=\(captureDevice?.uniqueID ?? "system_default")"
            )

            diagnostics.log(sessionID: sessionID, event: "asr_engine_selected",
                            detail: "provider=\(selectedPlatform.rawValue) realtime=\(selectedPlatform.isRealtime)")

            // Typeless timing: only schedule after capture has opened the input.
            let startSoundDelay = audioDeviceManager.startSoundDelayMilliseconds(for: captureDevice)
            soundCueTask = Task { [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self, self.state == .recording,
                      self.sessionGeneration == generation, self.recordingStopRequestedAt == nil else { return }
                self.diagnostics.log(sessionID: sessionID, event: "start_sound_cue_requested")
                self.onFeedbackEvent?(.startSoundCue(delayMs: startSoundDelay))
            }

            // 本地 SenseVoice 模式下录音开始即后台预热 ASR runtime（不阻塞录音）
            if selectedPlatform == .localSenseVoice {
                asrRuntimeManager.warmup()
            }

            // 在录音开始时快照 ASR 配置（录音期间不变）
            // LLM / processingMode 配置在录音结束后读取，保证 toggleProcessingMode 生效
            // 立即启动处理任务，for await 循环会实时消费分段并提前 ASR
            diagnostics.log(sessionID: sessionID, event: "processing_task_started", detail: "concurrent ASR enabled")
            processingTask = Task { [weak self] in
                if let realtime {
                    await self?.processRealtimeAudio(realtime, generation: generation, sessionID: sessionID,
                                                     platform: selectedPlatform)
                } else {
                await self?.processSegmentedAudio(
                    generation: generation,
                    sessionID: sessionID,
                    asrConfig: asrConfig,
                    selectedPlatform: selectedPlatform,
                    recoveryBuffer: recoveryBuffer
                )
                }
                if self?.sessionGeneration == generation { self?.processingTask = nil }
            }
        } catch {
            guard !Task.isCancelled, generation == sessionGeneration else { return }
            handleError(mapError(error))
        }
    }

    private func handleCaptureEvent(_ event: AudioCaptureEvent) {
        switch event {
        case .signalMissing, .signalRestored:
            guard recordingStopTask == nil else { return }
            recordingWarning = event == .signalMissing ? "没收到声音，请检查麦克风" : nil
            onFeedbackEvent?(.recordingSignalChanged(missing: event == .signalMissing))
        case .interrupted(let reason):
            if let realtimePipeline {
                realtimePipeline.input.fail(.audioCaptureInterrupted(reason))
                return
            }
            // Invalidate in-flight ASR before snapshotting. Its late result must not
            // remove an unfinished segment or deliver an incomplete sentence.
            sessionGeneration &+= 1
            recordingStartTask?.cancel()
            recordingStartTask = nil
            recordingStopTask?.cancel()
            recordingStopTask = nil
            soundCueTask?.cancel()
            soundCueTask = nil
            processingTask?.cancel()
            processingTask = nil
            let stopped = audioRecorder.stopRecording()
            recordingDurationMs = stopped.durationMs
            segmenter.finalize()
            let snapshot = recordingRecoveryBuffer?.snapshot()
            discardRecovery()
            if !isOnboardingTrial, let snapshot,
               !snapshot.segments.isEmpty || !snapshot.transcripts.isEmpty {
                let checkpoint = SessionRecoveryCheckpoint(segments: snapshot.segments, transcripts: snapshot.transcripts,
                    mode: processingMode, language: configStore.generalConfig.translationTargetLanguage,
                    asrPlatform: recordingASRPlatform, target: targetInput,
                    context: configStore.windowContextEnabled ? capturedWindowContext : nil)
                checkpoint.isPartialRecording = true
                retainRecovery(checkpoint)
            }
            cleanupSegmenterState()
            diagnostics.log(sessionID: currentSessionID, event: "recording_interrupted", detail: reason.rawValue)
            handleError(.audioCaptureInterrupted(reason))
        }
    }

    var recoveryActionTitle: String? {
        guard let recovery else { return nil }
        return recovery.isPartialRecording ? "继续处理已录内容" : recovery.stage.retryTitle
    }

    /// 结束录音并开始处理链路
    func finishRecording() {
        guard state == .recording, recordingStopTask == nil else { return }
        recordingStopRequestedAt = Date()
        diagnostics.log(sessionID: currentSessionID, event: "recording_stop_requested")

        let pendingStart = recordingStartTask
        soundCueTask?.cancel()
        soundCueTask = nil

        // Short captures remain silent and close immediately. Valid captures
        // play End first and keep input open for 100ms, matching Typeless.
        guard audioRecorder.currentDurationMs >= 500 else {
            recordingStartTask?.cancel()
            recordingStartTask = nil
            completeRecordingStop(audioRecorder.stopRecording())
            return
        }
        onFeedbackEvent?(.recordingStopped)
        let generation = sessionGeneration
        recordingStopTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return }
            // Samples can arrive before startRecording returns. Keep that start alive
            // for a valid capture, so it installs the ASR consumer before we seal input.
            await pendingStart?.value
            guard !Task.isCancelled, let self, self.sessionGeneration == generation,
                  self.state == .recording else { return }
            self.recordingStopTask = nil
            self.completeRecordingStop(self.audioRecorder.stopRecording())
        }
    }

    private func completeRecordingStop(_ recordingResult: AudioRecordingResult) {
        let audioData = recordingResult.data
        recordingStoppedAt = Date()
        if let requested = recordingStopRequestedAt {
            diagnostics.log(sessionID: currentSessionID, event: "capture_closed",
                detail: "stop_request_to_capture_closed_ms=\(Int(Date().timeIntervalSince(requested) * 1000))")
        }

        // 短录音静默取消（<500ms）：先取消处理任务，再清理流
        if recordingResult.isShortRecording {
            diagnostics.shortRecordingCancelled(
                sessionID: currentSessionID,
                durationMs: recordingResult.durationMs
            )
            sessionGeneration &+= 1
            processingTask?.cancel()
            processingTask = nil
            lastRecordedAudio = nil
            clearWindowContextCapture()
            cancelPostInjectionLearning()
            targetApplicationPID = nil
            targetApplicationBundleID = nil
            cleanupSegmenterState()
            state = .idle
            onFeedbackEvent?(.processingCancelled)
            return
        }

        lastRecordedAudio = audioData

        guard realtimePipeline != nil || !audioData.isEmpty else {
            sessionGeneration &+= 1
            processingTask?.cancel()
            processingTask = nil
            clearWindowContextCapture()
            cancelPostInjectionLearning()
            cleanupSegmenterState()
            handleError(.asrEmptyAudio)
            return
        }

        // 记录录音时长供处理任务读取
        recordingDurationMs = recordingResult.durationMs

        // Capture has crossed its callback barrier; now drain the chosen pipeline.
        realtimePipeline?.input.finish()
        // 通知分段器结束，触发最终分段，关闭流
        segmenter.finalize()
        segmentContinuation?.finish()

        state = .transcribing
        diagnostics.log(sessionID: currentSessionID, event: "recording_finished", detail: "duration=\(recordingResult.durationMs)ms")
    }

    /// 取消当前任务
    func cancel() {
        recordingWarning = nil
        if isRecovering {
            discardRecovery()
            return
        }
        recordingStopTask?.cancel()
        recordingStopTask = nil
        switch state {
        case .recording:
            recordingStartTask?.cancel()
            recordingStartTask = nil
            soundCueTask?.cancel()
            soundCueTask = nil
            sessionGeneration &+= 1
            processingTask?.cancel()
            processingTask = nil
            _ = audioRecorder.stopRecording()
            clearWindowContextCapture()
            cancelPostInjectionLearning()
            cleanupSegmenterState()
            lastRecordedAudio = nil
            targetApplicationPID = nil
            targetApplicationBundleID = nil
            state = .cancelled
            diagnostics.sessionCancelled(sessionID: currentSessionID)
            onFeedbackEvent?(.processingCancelled)
            scheduleResetToIdle()
        case .transcribing, .polishing, .injecting:
            guard state != .injecting || isOnboardingTrial else { return }
            sessionGeneration &+= 1
            processingTask?.cancel()
            processingTask = nil
            clearWindowContextCapture()
            cancelPostInjectionLearning()
            cleanupSegmenterState()
            lastRecordedAudio = nil
            // 取消期间 runtime 可能仍在推理，排队销毁旧 recognizer，防止旧状态污染后续 session
            if state == .transcribing {
                asrRuntimeManager.invalidateCurrentWorker()
            }
            targetApplicationPID = nil
            targetApplicationBundleID = nil
            state = .cancelled
            diagnostics.sessionCancelled(sessionID: currentSessionID)
            onFeedbackEvent?(.processingCancelled)
            scheduleResetToIdle()
        default:
            break
        }
    }

    /// 切换当前录音 session 的文本处理模式（仅在录音态生效）
    func toggleProcessingMode() {
        guard state == .recording, recordingStopTask == nil else { return }
        processingMode = (processingMode == .polish) ? .translate : .polish
        diagnostics.log(sessionID: currentSessionID, event: "processing_mode_changed", detail: processingMode.rawValue)
        onFeedbackEvent?(.modeSwitched(processingMode))
    }

    private func processRealtimeAudio(_ pipeline: RealtimeRecognitionPipeline, generation: UInt64,
                                      sessionID: String, platform: ASRPlatform) async {
        do {
            let texts = try await pipeline.run()
            guard sessionGeneration == generation, !Task.isCancelled else { return }
            realtimePipeline = nil
            let checkpoint = await makeRecoveryCheckpoint(segments: [], transcripts: texts, asrPlatform: platform)
            guard sessionGeneration == generation, !Task.isCancelled else { checkpoint.discard(); return }
            var diag = SessionDiagnostics()
            diag.recordingMs = recordingDurationMs
            diag.asrMs = max(0, Int(Date().timeIntervalSince(recordingStoppedAt ?? Date()) * 1000))
            diag.totalMs = diag.asrMs ?? 0
            diag.targetBundleID = targetApplicationBundleID
            await runCheckpoint(checkpoint, generation: generation, sessionID: sessionID, diagnostics: diag)
        } catch {
            guard sessionGeneration == generation, !Task.isCancelled else { return }
            let wasRecording = state == .recording
            if wasRecording {
                recordingStopTask?.cancel()
                recordingStopTask = nil
                soundCueTask?.cancel()
                soundCueTask = nil
                recordingDurationMs = audioRecorder.stopRecording().durationMs
                pipeline.input.finish()
            }
            let snapshot = await pipeline.snapshot()
            guard sessionGeneration == generation, !Task.isCancelled else { return }
            let mapped = mapError(error)
            if !isOnboardingTrial, recordingDurationMs >= 500,
               !snapshot.audio.processedPCM.isEmpty || !snapshot.audio.rawPCM.isEmpty || !snapshot.transcripts.isEmpty {
                if case .transcriptTooLong = mapped {} else {
                    let checkpoint = await makeRecoveryCheckpoint(segments: [], transcripts: snapshot.transcripts,
                                                                   asrPlatform: platform)
                    guard sessionGeneration == generation, !Task.isCancelled else { checkpoint.discard(); return }
                    if !snapshot.audio.processedPCM.isEmpty || !snapshot.audio.rawPCM.isEmpty {
                        checkpoint.realtimeAudio = snapshot.audio
                    }
                    checkpoint.isPartialRecording = wasRecording || error is RealtimePipelineError
                    retainRecovery(checkpoint)
                }
            }
            await pipeline.cancel()
            guard sessionGeneration == generation, !Task.isCancelled else { return }
            realtimePipeline = nil
            diagnostics.sessionError(sessionID: sessionID, error: mapped)
            handleError(mapped)
        }
    }

    // MARK: - Segmented Processing Pipeline

    private nonisolated func processSegmentedAudio(
        generation: UInt64,
        sessionID: String,
        asrConfig: ASRConfig,
        selectedPlatform: ASRPlatform,
        recoveryBuffer: RecordingRecoveryBuffer
    ) async {
        let sessionStart = Date()
        var diag = SessionDiagnostics()
        diag.targetBundleID = await MainActor.run { targetApplicationBundleID }

        let wasColdStart = !asrRuntimeManager.isWarm

        // 本地 SenseVoice：等待预热完成
        if selectedPlatform == .localSenseVoice {
            do {
                try await asrRuntimeManager.awaitWarmupIfNeeded()
            } catch {
                diagnostics.log(sessionID: sessionID, event: "warmup_failed", detail: error.localizedDescription)
            }
        }

        // 构建 ASR Provider
        let asrProviderFactory = ASRProviderFactory(runtimeManager: asrRuntimeManager)
        let asrProvider = await MainActor.run {
            asrProviderOverride?(asrConfig) ?? asrProviderFactory.makeProvider(for: asrConfig)
        }

        guard let stream = await MainActor.run(body: { segmentStream }) else { return }

        // 串行处理分段（录音期间实时消费，提前 ASR）
        var transcripts: [String] = []
        var failedSegments: [SealedSegment] = []
        var firstASRError: MemoEchoError?
        var totalASRMs: Int = 0
        var totalDenoiseMs: Int = 0
        var accumulatedChars: Int = 0
        var segmentDiagList: [SegmentDiagnostics] = []
        var segmentCount = 0
        let maxChars = 8000

        diagnostics.log(sessionID: sessionID, event: "asr_loop_started", detail: "waiting for segments")

        for await segment in stream {
            guard await MainActor.run(body: { sessionGeneration }) == generation,
                  !Task.isCancelled else { return }

            segmentCount += 1

            // 跳过无语音的分段（如纯静音尾段）
            if !segment.voicedDetected {
                diagnostics.log(sessionID: sessionID, event: "segment_skipped_no_voice", detail: "index=\(segment.index)")
                continue
            }

            diagnostics.segmentSealed(
                sessionID: sessionID,
                index: segment.index,
                sampleCount: segment.sampleCount,
                reason: segment.sealReason.rawValue
            )

            if firstASRError != nil {
                failedSegments.append(segment)
                continue
            }

            // 编码为 WAV
            let wavData = WAVAudioEncoder.encodePCM16(
                pcmData: segment.pcmData,
                sampleRate: AudioSegmenter.sampleRate,
                channels: 1
            )

            // 降噪
            let denoiseStart = Date()
            let processedAudio: Data
            do {
                processedAudio = try audioPreprocessor.denoise(wavData: wavData)
            } catch {
                diagnostics.denoiseFailed(sessionID: sessionID, reason: "segment \(segment.index): \(error.localizedDescription)")
                // 降噪失败时使用原始音频
                processedAudio = wavData
            }
            let denoiseMs = Int(Date().timeIntervalSince(denoiseStart) * 1000)
            totalDenoiseMs += denoiseMs

            guard await MainActor.run(body: { sessionGeneration }) == generation,
                  !Task.isCancelled else { return }

            // ASR 识别（动态超时：按 AGENTS.md 规范 min(90s, max(15s, duration * 1.3 + 10s))）
            let dynamicTimeout = min(90.0, max(15.0, segment.durationSeconds * 1.3 + 10.0))
            diagnostics.log(sessionID: sessionID, event: "segment_asr_started", detail: "index=\(segment.index) duration=\(Int(segment.durationSeconds * 1000))ms timeout=\(Int(dynamicTimeout))s")
            let asrStart = Date()
            let transcriptResult: TranscriptResult
            do {
                transcriptResult = try await asrProvider.recognize(audioData: processedAudio, timeout: dynamicTimeout)
                guard !transcriptResult.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw MemoEchoError.asrEmptyTranscript
                }
                if selectedPlatform == .localSenseVoice {
                    asrRuntimeManager.markRecognitionSucceeded()
                }
            } catch {
                guard await MainActor.run(body: { sessionGeneration }) == generation,
                      !Task.isCancelled else { return }
                let mapped = await MainActor.run { mapError(error) }
                let asrMs = Int(Date().timeIntervalSince(asrStart) * 1000)
                diag.asrMs = totalASRMs + asrMs
                diag.denoiseMs = totalDenoiseMs
                diag.totalMs = Int(Date().timeIntervalSince(sessionStart) * 1000)
                diag.errorClassification = mapped.diagnosticClassification
                diag.segmentCount = segmentCount
                diag.segmentDiagnostics = segmentDiagList
                diagnostics.sessionError(sessionID: sessionID, error: mapped)
                diagnostics.sessionEnded(sessionID: sessionID, result: diag)
                firstASRError = mapped
                failedSegments.append(segment)
                // Seal the already-recorded tail before draining the stream into recovery.
                await MainActor.run {
                    guard sessionGeneration == generation, !Task.isCancelled else { return }
                    sealRecordingAfterRecognitionFailure()
                }
                continue
            }

            let accepted = await MainActor.run {
                guard sessionGeneration == generation, !Task.isCancelled else { return false }
                recoveryBuffer.complete(index: segment.index, text: transcriptResult.text)
                return true
            }
            guard accepted else { return }
            let asrMs = Int(Date().timeIntervalSince(asrStart) * 1000)
            totalASRMs += asrMs

            let segDiag = SegmentDiagnostics(
                index: segment.index,
                audioDurationMs: Int(segment.durationSeconds * 1000),
                denoiseMs: denoiseMs,
                asrMs: asrMs,
                charCount: transcriptResult.text.count,
                sealReason: segment.sealReason.rawValue
            )
            segmentDiagList.append(segDiag)
            diagnostics.segmentASRCompleted(sessionID: sessionID, segment: segDiag)

            if !transcriptResult.text.isEmpty {
                transcripts.append(transcriptResult.text)
                accumulatedChars += transcriptResult.text.count
                diagnostics.log(sessionID: sessionID, event: "segment_transcript", detail: "index=\(segment.index) chars=\(transcriptResult.text.count) accumulated=\(accumulatedChars)")
            }

            // 检查累计字符数
            if accumulatedChars > maxChars {
                diag.asrMs = totalASRMs
                diag.denoiseMs = totalDenoiseMs
                diag.totalMs = Int(Date().timeIntervalSince(sessionStart) * 1000)
                diag.segmentCount = segmentCount
                diag.segmentDiagnostics = segmentDiagList
                let tooLongError = MemoEchoError.transcriptTooLong(charCount: accumulatedChars)
                diag.errorClassification = tooLongError.diagnosticClassification
                diagnostics.sessionError(sessionID: sessionID, error: tooLongError)
                diagnostics.sessionEnded(sessionID: sessionID, result: diag)
                await MainActor.run {
                    guard sessionGeneration == generation, !Task.isCancelled else { return }
                    if state == .recording {
                        soundCueTask?.cancel()
                        soundCueTask = nil
                        _ = audioRecorder.stopRecording()
                        cleanupSegmenterState()
                    }
                    handleError(tooLongError)
                }
                return
            }
        }

        // --- 流已结束（录音已停止，所有分段已处理）---

        guard await MainActor.run(body: { sessionGeneration }) == generation,
              !Task.isCancelled else { return }

        await MainActor.run {
            guard sessionGeneration == generation, !Task.isCancelled else { return }
            lastRecordedAudio = nil
            cleanupSegmenterState()
        }
        let checkpoint = await makeRecoveryCheckpoint(segments: failedSegments, transcripts: transcripts,
                                                       asrPlatform: selectedPlatform)
        if let firstASRError {
            await MainActor.run {
                guard sessionGeneration == generation, !Task.isCancelled else { return }
                if !isOnboardingTrial { retainRecovery(checkpoint) }
                handleError(firstASRError)
            }
            return
        }
        diag.asrMs = totalASRMs
        diag.denoiseMs = totalDenoiseMs
        diag.segmentCount = segmentCount
        diag.segmentDiagnostics = segmentDiagList
        diag.recordingMs = await MainActor.run { recordingDurationMs }
        diagnostics.log(sessionID: sessionID, event: "asr_completed",
                        detail: "chars=\(transcripts.joined().count) cold=\(wasColdStart)")
        diag.totalMs = Int(Date().timeIntervalSince(sessionStart) * 1000)
        await runCheckpoint(checkpoint, generation: generation, sessionID: sessionID, diagnostics: diag)
    }

    private func makeRecoveryCheckpoint(segments: [SealedSegment], transcripts: [String],
                                        asrPlatform: ASRPlatform) async -> SessionRecoveryCheckpoint {
        await windowContextTask?.value
        return .init(segments: segments, transcripts: transcripts, mode: processingMode,
              language: configStore.generalConfig.translationTargetLanguage, asrPlatform: asrPlatform,
              target: targetInput, context: configStore.windowContextEnabled ? capturedWindowContext : nil)
    }

    /// Called after an ASR error, including during the final 100ms sound delay.
    private func sealRecordingAfterRecognitionFailure() {
        guard state == .recording else { return }
        recordingStopTask?.cancel()
        recordingStopTask = nil
        soundCueTask?.cancel()
        soundCueTask = nil
        let stopped = audioRecorder.stopRecording()
        recordingDurationMs = stopped.durationMs
        lastRecordedAudio = nil
        segmenter.finalize()
        segmentContinuation?.finish()
        state = .transcribing
    }

    var recoveryNeedsSettings: Bool {
        guard recovery != nil else { return false }
        switch recovery?.failure {
        case .llmConfigurationIncomplete, .invalidLLMConfiguration, .cloudASRConfigurationIncomplete,
             .cloudASRAuthenticationFailure, .asrModelMissing, .asrBinaryNotFound, .asrRuntimeMissing,
             .asrPlatformNotReady, .accessibilityPermissionDenied:
            return true
        default: return false
        }
    }

    var canRetryRecovery: Bool {
        state.allowsRecordingStart && !isRecovering && recovery?.canRetry == true
            && recovery?.isValid(at: Date()) == true
    }

    func retainRecovery(_ checkpoint: SessionRecoveryCheckpoint) {
        if recovery?.id != checkpoint.id {
            if lastInjectionFailureText == recovery?.finalText { lastInjectionFailureText = nil }
            if let id = recovery?.id { invalidateRecoveryPresentation(id) }
            recovery?.discard()
        }
        checkpoint.retainUntilExpiration(now: Date(), lifetime: recoveryLifetime)
        recovery = checkpoint
        recoveryOwnerGeneration = sessionGeneration
        recoveryExpiryTask?.cancel()
        let delay = max(0, checkpoint.expiresAt?.timeIntervalSinceNow ?? 0)
        let id = checkpoint.id
        recoveryExpiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.recovery?.id == id else { return }
            self.discardRecovery()
        }
    }

    func discardRecovery() {
        recoveryExpiryTask?.cancel()
        recoveryExpiryTask = nil
        if let id = recovery?.id { invalidateRecoveryPresentation(id) }
        recoveryOwnerGeneration = nil
        let finalText = recovery?.finalText
        recovery?.discard()
        recovery = nil
        if lastInjectionFailureText == finalText { lastInjectionFailureText = nil }
        if lastResult?.text == finalText { lastResult = nil }
        if isRecovering {
            sessionGeneration &+= 1
            processingTask?.cancel()
            processingTask = nil
            isRecovering = false
            state = .cancelled
            onFeedbackEvent?(.processingCancelled)
            scheduleResetToIdle()
        }
    }

    func retryRecovery() {
        guard canRetryRecovery, let checkpoint = recovery else { return }
        checkpoint.isPartialRecording = false
        resetToIdleTask?.cancel()
        resetToIdleTask = nil
        cancelPostInjectionLearning()
        sessionGeneration &+= 1
        let generation = sessionGeneration
        recoveryOwnerGeneration = generation
        currentSessionID = Self.generateSessionID()
        let sessionID = currentSessionID
        textOutput = .focusedApplication
        currentError = nil
        currentErrorRecoveryID = nil
        isRecovering = true
        state = checkpoint.stage == .recognition ? .transcribing : .polishing
        onFeedbackEvent?(.recoveryStarted)
        processingTask = Task { [weak self] in
            guard let self else { return }
            await self.runCheckpoint(checkpoint, generation: generation, sessionID: sessionID)
            guard self.sessionGeneration == generation else { return }
            self.isRecovering = false
            self.processingTask = nil
        }
    }

    private func makeRecoveryProcessor(_ checkpoint: SessionRecoveryCheckpoint) -> SessionRecoveryProcessor {
        if let recoveryProcessorFactory { return recoveryProcessorFactory(checkpoint) }
        // Read current credentials on each retry, keeping the original ASR platform and intent.
        var asrConfig = configStore.asrConfig
        asrConfig.selectedPlatform = checkpoint.asrPlatform
        let provider = asrProviderOverride?(asrConfig)
            ?? ASRProviderFactory(runtimeManager: asrRuntimeManager).makeProvider(for: asrConfig)
        let generation = sessionGeneration
        let llmConfig = configStore.llmConfig
        let apiKey = configStore.openAIAPIKey
        let isConfigured = configStore.isLLMConfigured
        let llm = LLMProvider(baseURL: llmConfig.baseURL, apiKey: apiKey, model: llmConfig.model,
                              omitThinkingParameter: configStore.omitThinkingParameter,
                              dictionaryTerms: dictionaryStore?.termsForPrompt() ?? [],
                              onThinkingUnsupported: { [weak self] in
            guard let self, self.sessionGeneration == generation, self.configStore.llmConfig.baseURL == llmConfig.baseURL,
                  self.configStore.llmConfig.model == llmConfig.model,
                  self.configStore.openAIAPIKey == apiKey else { return }
            try? self.configStore.markThinkingParameterUnsupported(for: llmConfig, apiKey: apiKey)
        }, windowContextEnabled: { [configStore] in configStore.windowContextEnabled })
        let preprocessor = audioPreprocessor
        var processor = SessionRecoveryProcessor(recognize: { segment in
            let audio = await Task.detached {
                let wav = WAVAudioEncoder.encodePCM16(pcmData: segment.pcmData,
                                                       sampleRate: AudioSegmenter.sampleRate, channels: 1)
                return (try? preprocessor.denoise(wavData: wav)) ?? wav
            }.value
            try Task.checkCancellation()
            let timeout = min(90.0, max(15.0, segment.durationSeconds * 1.3 + 10.0))
            return try await provider.recognize(audioData: audio, timeout: timeout).text
        }, polish: { transcripts, context in
            guard isConfigured else { throw MemoEchoError.llmConfigurationIncomplete }
            return try await llm.polish(text: transcripts.joined(), segmentCount: transcripts.count,
                                        context: WindowContextService.sanitized(context))
        }, translate: { text, language, context in
            guard isConfigured else { throw MemoEchoError.llmConfigurationIncomplete }
            return try await llm.translate(text: text, targetLanguage: language,
                                           context: WindowContextService.sanitized(context))
        })
        if asrConfig.selectedPlatform.isRealtime {
            let replayConfig = asrConfig
            processor.recognizeRealtime = { audio in
                try await RealtimeRecognitionPipeline.replay(audio, config: replayConfig)
            }
        }
        return processor
    }

    private func runCheckpoint(_ checkpoint: SessionRecoveryCheckpoint, generation: UInt64,
                               sessionID: String, diagnostics initial: SessionDiagnostics = .init()) async {
        var diag = initial
        let recoveryAttempt = isRecovering
        diagnostics.log(sessionID: sessionID, event: "recovery_attempt", detail: recoveryAttempt ? "1" : "0")
        let start = Date()
        var stageStart = start
        var activeStage: SessionRecoveryCheckpoint.Stage?
        func finishStageTiming() {
            let elapsed = Int(Date().timeIntervalSince(stageStart) * 1000)
            switch activeStage {
            case .recognition: diag.asrMs = (diag.asrMs ?? 0) + elapsed
            case .polish, .translation: diag.llmMs = (diag.llmMs ?? 0) + elapsed
            case .output: diag.injectionMs = (diag.injectionMs ?? 0) + elapsed
            case nil: break
            }
            stageStart = Date()
        }
        do {
            let processor = makeRecoveryProcessor(checkpoint)
            let text = try await processor.process(checkpoint, shouldContinue: { self.sessionGeneration == generation }, onStage: { stage in
                finishStageTiming()
                activeStage = stage
                self.state = stage == .recognition ? .transcribing : .polishing
                self.diagnostics.log(sessionID: sessionID, event: "processing_stage", detail: stage.rawValue)
            })
            guard sessionGeneration == generation, !Task.isCancelled, checkpoint.isValid(at: Date()) else { return }
            state = .injecting
            diag.resultSource = PolishResult.Source.llm.rawValue
            lastResult = SessionResult(text: text, source: .llm)
            var outputFeedbackSent = false
            let result = try await textOutput.deliver(text) { text in
                try await textInjector.inject(text: text, target: checkpoint.target,
                                               shouldContinue: { self.sessionGeneration == generation && checkpoint.isValid(at: Date()) },
                                               onOutputAttempt: { checkpoint.outputAttempted = true },
                                               onUnverifiedPasteDispatched: {
                    outputFeedbackSent = true
                    self.onFeedbackEvent?(.outputDispatched)
                })
            }
            guard sessionGeneration == generation, !Task.isCancelled else { return }
            if let result { diagnostics.injectionCompleted(sessionID: sessionID, path: result.path, breakdown: result.breakdown) }
            let unverified = result?.confirmation == .dispatched
            if result != nil {
                diagnostics.log(sessionID: sessionID, event: "output_confirmation", detail: unverified ? "dispatched" : "verified")
            }
            isRecovering = false
            if !isOnboardingTrial {
                lastInjectionFailureText = nil
                if !unverified {
                    beginPostInjectionLearningIfNeeded(generation: generation, mode: checkpoint.mode, sessionID: sessionID,
                                                       beforeInjection: result?.beforeInjection, insertedText: text)
                }
                discardRecovery()
            }
            checkpoint.discard()
            targetInput = nil
            lastResult = nil
            clearWindowContextCapture()
            state = .done
            finishStageTiming()
            diag.totalMs = initial.totalMs + Int(Date().timeIntervalSince(start) * 1000)
            diagnostics.sessionEnded(sessionID: sessionID, result: diag)
            if !recoveryAttempt, let stopped = recordingStopRequestedAt {
                diagnostics.log(sessionID: sessionID, event: "stop_to_injection",
                    detail: "stop_to_injection_ms=\(Int(Date().timeIntervalSince(stopped) * 1000))")
            }
            if !outputFeedbackSent {
                onFeedbackEvent?(unverified ? .outputDispatched : .processingFinished)
            }
            scheduleResetToIdle()
        } catch {
            guard sessionGeneration == generation, !Task.isCancelled, checkpoint.isValid(at: Date()) else { return }
            let mapped = mapError(error)
            if !isOnboardingTrial {
                if case .transcriptTooLong = mapped {
                    if recovery?.id == checkpoint.id {
                        isRecovering = false
                        discardRecovery()
                    }
                    checkpoint.discard()
                } else if checkpoint.realtimeAudio != nil || !checkpoint.transcripts.isEmpty || !checkpoint.pendingSegments.isEmpty || checkpoint.polished != nil {
                    retainRecovery(checkpoint)
                    if checkpoint.stage == .output { lastInjectionFailureText = checkpoint.finalText }
                }
            }
            isRecovering = false
            finishStageTiming()
            diag.totalMs = initial.totalMs + Int(Date().timeIntervalSince(start) * 1000)
            diag.errorClassification = mapped.diagnosticClassification
            diagnostics.sessionError(sessionID: sessionID, error: mapped)
            diagnostics.sessionEnded(sessionID: sessionID, result: diag)
            handleError(mapped, failedStage: checkpoint.stage)
        }
    }

    // MARK: - Segmenter Cleanup

    private func cleanupSegmenterState() {
        if let realtimePipeline { Task { await realtimePipeline.cancel() } }
        realtimePipeline = nil
        recordingRecoveryBuffer?.clear()
        recordingRecoveryBuffer = nil
        recordingWarning = nil
        segmenter.onSegmentSealed = nil
        segmentContinuation?.finish()
        segmentContinuation = nil
        segmentStream = nil
        segmenter.reset()
    }

    // MARK: - Error Handling

    private func handleError(_ error: MemoEchoError, failedStage: SessionRecoveryCheckpoint.Stage? = nil) {
        lastRecordedAudio = nil
        recordingWarning = nil
        recordingStopTask?.cancel()
        recordingStopTask = nil
        recordingStartTask?.cancel()
        recordingStartTask = nil
        soundCueTask?.cancel()
        soundCueTask = nil
        clearWindowContextCapture()
        cancelPostInjectionLearning()
        currentError = error
        state = .error
        let reason: HUDFailureReason = failedStage == .translation && error.hudFailureReason == .polishFailed
            ? .translationFailed : error.hudFailureReason
        currentErrorRecoveryID = nil
        if recoveryOwnerGeneration == sessionGeneration, let recovery {
            recovery.failure = error
            recovery.failureReason = reason
            currentErrorRecoveryID = recovery.id
        }
        onFeedbackEvent?(.processingFailed(reason))
        scheduleResetToIdle()
    }

    private func mapError(_ error: Error) -> MemoEchoError {
        if let realtime = error as? RealtimeASRError {
            switch realtime {
            case .authentication: return .cloudASRAuthenticationFailure
            case .configuration: return .cloudASRConfigurationIncomplete
            case .textLimit: return .transcriptTooLong(charCount: 8001)
            default: return .cloudASRNetworkFailure(message: realtime.localizedDescription)
            }
        }
        if error is RealtimePipelineError {
            return .cloudASRNetworkFailure(message: "实时音频缓冲达到上限，录音已停止，请检查网络后重试")
        }
        if let te = error as? MemoEchoError { return te }
        if let pe = error as? PermissionError {
            switch pe {
            case .microphonePermissionDenied: return .microphonePermissionDenied
            case .accessibilityPermissionDenied: return .accessibilityPermissionDenied
            }
        }
        if let recorderError = error as? AudioRecorderError {
            return .audioRecordingUnavailable(detail: recorderError.localizedDescription)
        }
        return .textInjectionFailure(detail: error.localizedDescription)
    }

    private func scheduleResetToIdle() {
        resetToIdleTask?.cancel()
        let generation = sessionGeneration
        resetToIdleTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard let self, !Task.isCancelled, self.sessionGeneration == generation else { return }
            guard self.state == .error || self.state == .cancelled || self.state == .done else { return }
            self.state = .idle
            self.targetApplicationPID = nil
            self.targetInput = nil
            self.targetApplicationBundleID = nil
            self.resetToIdleTask = nil
        }
    }

    // MARK: - Helpers

    private static func generateSessionID() -> String {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000) % 100_000_000
        let random = Int.random(in: 0..<0xFFFF)
        return String(format: "%08x-%04x", timestamp, random)
    }

    private func beginWindowContextCapture(
        generation: UInt64,
        sessionID: String,
        targetPID: pid_t?,
        targetBundleID: String?
    ) {
        windowContextTask?.cancel()
        capturedWindowContext = nil
        windowContextTask = nil
        guard configStore.windowContextEnabled else { return }

        let identity = targetInput?.scope == .field ? targetInput?.identity : nil
        windowContextTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.windowContextService.captureContextResult(
                targetPID: targetPID, targetBundleID: targetBundleID, targetIdentity: identity,
                onBasic: { [weak self] basic in
                    await MainActor.run {
                        guard let self, self.sessionGeneration == generation, !Task.isCancelled else { return }
                        self.capturedWindowContext = self.configStore.windowContextEnabled ? WindowContextService.sanitized(basic.snapshot) : nil
                    }
                })
            guard !Task.isCancelled, self.sessionGeneration == generation else { return }
            self.capturedWindowContext = self.configStore.windowContextEnabled ? WindowContextService.sanitized(result.snapshot) : nil
            self.windowContextTask = nil
            let quality = result.snapshot?.fieldStatus.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value.rawValue)" }.joined(separator: ",") ?? ""
            self.diagnostics.log(sessionID: sessionID, event: result.event.rawValue,
                                 detail: "ms=\(result.snapshot?.captureMilliseconds ?? 0) quality=\(quality)")
        }
    }

    private func clearWindowContextCapture() {
        windowContextTask?.cancel()
        windowContextTask = nil
        capturedWindowContext = nil
    }

    func beginPostInjectionLearningIfNeeded(
        generation: UInt64,
        mode: TextProcessingMode,
        sessionID: String,
        beforeInjection: FocusedElementTextSnapshot?,
        insertedText: String
    ) {
        cancelPostInjectionLearning()
        guard mode == .polish else {
            diagnostics.log(sessionID: sessionID, event: "dictionary_observation_skipped", detail: "translation_mode")
            return
        }
        guard let dictionaryStore, let beforeInjection else {
            diagnostics.log(sessionID: sessionID, event: "dictionary_observation_skipped", detail: "missing_store_or_snapshot")
            return
        }

        postInjectionLearningTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await postInjectionLearner.observe(
                beforeInjection: beforeInjection,
                insertedText: insertedText,
                store: dictionaryStore,
                shouldContinue: { [weak self] in
                    guard let self else { return false }
                    return self.sessionGeneration == generation
                },
                onObservation: { [weak self] event in
                    self?.diagnostics.log(sessionID: sessionID, event: "dictionary_observation", detail: event.rawValue)
                },
                onDecision: { [weak self] decision in
                    guard let self, self.sessionGeneration == generation else { return }
                    switch decision {
                    case .learned(let term):
                        self.diagnostics.log(
                            sessionID: sessionID,
                            event: "dictionary_term_learned",
                            detail: "chars=\(term.count)"
                        )
                        self.onFeedbackEvent?(.dictionaryTermLearned(term))
                    case .rejected(let term):
                        self.diagnostics.log(
                            sessionID: sessionID,
                            event: "dictionary_term_rejected",
                            detail: "chars=\(term.count)"
                        )
                    case .failed(let term, let reason):
                        self.diagnostics.log(
                            sessionID: sessionID,
                            event: "dictionary_term_learning_failed",
                            detail: "chars=\(term.count) reason=\(reason)"
                        )
                    }
                }
            )

            if self.sessionGeneration == generation {
                self.postInjectionLearningTask = nil
            }
        }
    }

    private func cancelPostInjectionLearning() {
        postInjectionLearningTask?.cancel()
        postInjectionLearningTask = nil
    }
}

// MARK: - Session Result

struct SessionResult: Sendable {
    let text: String
    let source: PolishResult.Source
}
