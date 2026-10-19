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
    var beforeServiceRequest: (@MainActor @Sendable (SessionRecoveryCheckpoint.Stage) async throws -> Void)?
    var onLLMRequestPrepared: (@MainActor @Sendable (LLMValidationInput) -> Void)?
    var onServiceSucceeded: (@MainActor @Sendable (SessionRecoveryCheckpoint.Stage) -> Void)?
    private(set) var lastRecordedAudio: Data?
    private(set) var currentError: MemoEchoError?
    private(set) var currentFailureIsLocal = false
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
            currentFailureIsLocal = false
            currentErrorRecoveryID = nil
        }
        onRecoveryInvalidated?(id)
    }

    var onFeedbackEvent: (@MainActor @Sendable (SessionFeedbackEvent) -> Void)?

    /// 返回当前音频录制电平（0-1），供 HUD 声波动画使用
    func currentAudioLevel() -> Float {
        audioRecorder.currentLevel()
    }

    /// Settings may resume its meter as soon as cancellation updates UI, before the old mic closes.
    func waitForCaptureClose() async {
        if let captureDrainTask { _ = await captureDrainTask.value }
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
    private let realtimeSessionFactory: (@Sendable (ASRConfig, ASRHotwords) throws -> any RealtimeASRSession)?
    private let asrProviderOverride: ((ASRConfig, ASRHotwords) -> any ASRProvider)?
    private let recoveryLifetime: TimeInterval
    private let recoveryProcessorFactory: ((SessionRecoveryCheckpoint) -> SessionRecoveryProcessor)?
    private var targetInput: TextInjectionFocus?
    private let windowContextService: WindowContextService
    private let clock: PipelineClock
    private var latencyTimeline: SessionLatencyTimeline?
    private(set) var lastLatencyDiagnostics: SessionLatencySnapshot?
    var onLatencyMilestone: (@MainActor @Sendable (String, SessionLatencyTimeline.Milestone, SessionLatencySnapshot) -> Void)?
    private var windowContextReadyAt: ContinuousClock.Instant?
    private let promptTermIndex = LLMTermIndexWarmer()
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
    /// Physical close survives UI/task cancellation and is awaited before configuring another capture.
    private var captureDrainTask: Task<AudioRecordingResult, Never>?
    private var captureHasDrained = false
    private var closedCaptureMetadata = AudioRecordingResult(data: Data(), durationMs: 0)
    private var captureGeneration: UInt64?
    var beforeCaptureStart: (@MainActor @Sendable () async -> Void)?
    private var sessionGeneration: UInt64 = 0
    private(set) var currentSessionID: String = ""
    private var processingMode: TextProcessingMode = .polish
    private var textOutput: SessionTextOutput = .focusedApplication
    var isOnboardingTrial: Bool { textOutput.isOnboardingTrial }

    // 分段相关
    private let segmenter = AudioSegmenter()
    private var realtimePipeline: RealtimeRecognitionPipeline?
    private var recordingRecoveryBuffer: RecordingRecoveryBuffer?
    private var recordingHotwords: ASRHotwords = .empty
    private var recordingASRPlatform: ASRPlatform = .localSenseVoice
    private(set) var recordingWarning: String?
    private var segmentStream: AsyncStream<SealedSegment>?
    private var segmentContinuation: AsyncStream<SealedSegment>.Continuation?
    /// 录音时长（毫秒），finishRecording 写入，processSegmentedAudio 读取
    private var recordingDurationMs: Int = 0
    private var recordingStopRequestedAt: ContinuousClock.Instant?
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
        asrProviderOverride: ((ASRConfig, ASRHotwords) -> any ASRProvider)? = nil,
        realtimeSessionFactory: (@Sendable (ASRConfig, ASRHotwords) throws -> any RealtimeASRSession)? = nil,
        clock: PipelineClock = .live,
        windowContextService: WindowContextService = WindowContextService()
    ) {
        self.clock = clock
        self.windowContextService = windowContextService
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
        currentFailureIsLocal = false
        currentErrorRecoveryID = nil
        recordingStopRequestedAt = nil
        latencyTimeline = nil
        lastLatencyDiagnostics = nil
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
        let hotwords = ASRHotwords(terms: dictionaryStore?.entries.map(\.term) ?? [], platform: selectedPlatform)
        promptTermIndex.prepare(dictionaryStore?.termsForPrompt() ?? [])
        recordingHotwords = hotwords
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
                    asrConfig: recordingConfig,
                    hotwords: hotwords
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
        asrConfig: ASRConfig,
        hotwords: ASRHotwords
    ) async {
        guard generation == sessionGeneration, state == .recording else { return }

        do {
            if let captureDrainTask { _ = await captureDrainTask.value }
            guard !Task.isCancelled, generation == sessionGeneration, state == .recording else { return }
            await beforeCaptureStart?()
            guard !Task.isCancelled, generation == sessionGeneration, state == .recording else { return }
            captureDrainTask = nil
            captureHasDrained = false
            closedCaptureMetadata = .init(data: Data(), durationMs: 0)
            captureGeneration = generation
            let realtimeFactory = realtimeSessionFactory
            let realtime: RealtimeRecognitionPipeline? = selectedPlatform.isRealtime
                ? RealtimeRecognitionPipeline(sessionID: sessionID) {
                    try realtimeFactory?(asrConfig, hotwords) ?? ASRProviderFactory.makeRealtimeSession(for: asrConfig, hotwords: hotwords)
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
                    _ = await drainCapture().value
                    if generation == sessionGeneration { cleanupSegmenterState() }
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
                                                     platform: selectedPlatform, hotwords: hotwords)
                } else {
                await self?.processSegmentedAudio(
                    generation: generation,
                    sessionID: sessionID,
                    asrConfig: asrConfig,
                    selectedPlatform: selectedPlatform,
                    recoveryBuffer: recoveryBuffer,
                    hotwords: hotwords
                )
                }
                if self?.sessionGeneration == generation { self?.processingTask = nil }
            }
        } catch {
            guard !Task.isCancelled, generation == sessionGeneration else { return }
            _ = await drainCapture().value
            guard !Task.isCancelled, generation == sessionGeneration else { return }
            cleanupSegmenterState()
            handleError(mapError(error))
        }
    }

    private func drainCapture() -> Task<AudioRecordingResult, Never> {
        if let captureDrainTask { return captureDrainTask }
        if captureHasDrained { return Task { [closedCaptureMetadata] in closedCaptureMetadata } }
        let generation = sessionGeneration
        let task = Task { [weak self, audioRecorder] in
            let result = await audioRecorder.stopRecording()
            self?.markCurrentLatency(.captureClosed, generation: generation)
            // Keep duration for concurrent failure handling, but release the full WAV after its caller consumes it.
            self?.closedCaptureMetadata = .init(data: Data(), durationMs: result.durationMs, sampleCount: result.sampleCount)
            self?.captureHasDrained = true
            self?.captureDrainTask = nil
            return result
        }
        captureDrainTask = task
        return task
    }

    private var isCaptureClosing: Bool {
        captureGeneration == sessionGeneration && (captureDrainTask != nil || captureHasDrained)
    }

    private func handleCaptureEvent(_ event: AudioCaptureEvent) {
        switch event {
        case .signalMissing, .signalRestored:
            guard recordingStopTask == nil, !isCaptureClosing else { return }
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
            let generation = sessionGeneration
            let drain = drainCapture()
            recordingStopTask = Task { [weak self] in
                let stopped = await drain.value
                guard let self, !Task.isCancelled, self.sessionGeneration == generation else { return }
                self.completeCaptureInterruption(reason, stopped: stopped)
            }
        }
    }

    private func completeCaptureInterruption(_ reason: AudioCaptureInterruption, stopped: AudioRecordingResult) {
        recordingDurationMs = stopped.durationMs
        segmenter.finalize()
        let snapshot = recordingRecoveryBuffer?.snapshot()
        discardRecovery()
        if !isOnboardingTrial, let snapshot,
           !snapshot.segments.isEmpty || !snapshot.transcripts.isEmpty {
            let checkpoint = SessionRecoveryCheckpoint(segments: snapshot.segments, transcripts: snapshot.transcripts,
                mode: processingMode, language: configStore.generalConfig.translationTargetLanguage,
                asrPlatform: recordingASRPlatform, target: targetInput,
                context: configStore.windowContextEnabled ? capturedWindowContext : nil, hotwords: recordingHotwords)
            checkpoint.isPartialRecording = true
            retainRecovery(checkpoint)
        }
        cleanupSegmenterState()
        diagnostics.log(sessionID: currentSessionID, event: "recording_interrupted", detail: reason.rawValue)
        handleError(.audioCaptureInterrupted(reason))
    }

    var recoveryActionTitle: String? {
        guard let recovery else { return nil }
        return recovery.isPartialRecording ? "继续处理已录内容" : recovery.stage.retryTitle
    }

    /// 结束录音并开始处理链路
    func finishRecording() {
        guard state == .recording, recordingStopTask == nil, !isCaptureClosing else { return }
        recordingStopRequestedAt = clock.now()
        latencyTimeline = SessionLatencyTimeline(origin: .recordingStop,
            path: recordingASRPlatform.isRealtime ? .realtime : .segmented, startedAt: recordingStopRequestedAt!)
        diagnostics.log(sessionID: currentSessionID, event: "recording_stop_requested")

        let pendingStart = recordingStartTask
        soundCueTask?.cancel()
        soundCueTask = nil

        let generation = sessionGeneration
        let hadCapture = captureGeneration == generation
        let shortCapture = audioRecorder.currentDurationMs < 500 || !hadCapture
        // Short captures remain silent. End still precedes the unchanged 100ms tail window.
        if shortCapture {
            recordingStartTask?.cancel()
            recordingStartTask = nil
        } else {
            onFeedbackEvent?(.recordingStopped)
        }
        // Reserve the stop slot synchronously, before the first suspension.
        let immediateDrain = shortCapture ? drainCapture() : nil
        recordingStopTask = Task { [weak self] in
            if !shortCapture {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
                await pendingStart?.value
            }
            guard !Task.isCancelled, let self, self.sessionGeneration == generation,
                  self.state == .recording else { return }
            let result = await (immediateDrain ?? self.drainCapture()).value
            guard !Task.isCancelled, self.sessionGeneration == generation, self.state == .recording else { return }
            self.recordingStopTask = nil
            self.completeRecordingStop(hadCapture ? result : .init(data: Data(), durationMs: 0))
        }
    }

    private func completeRecordingStop(_ recordingResult: AudioRecordingResult) {
        let audioData = recordingResult.data

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
            _ = drainCapture()
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
        guard state == .recording, recordingStopTask == nil, !isCaptureClosing else { return }
        processingMode = (processingMode == .polish) ? .translate : .polish
        diagnostics.log(sessionID: currentSessionID, event: "processing_mode_changed", detail: processingMode.rawValue)
        onFeedbackEvent?(.modeSwitched(processingMode))
    }

    private func processRealtimeAudio(_ pipeline: RealtimeRecognitionPipeline, generation: UInt64,
                                      sessionID: String, platform: ASRPlatform, hotwords: ASRHotwords) async {
        do {
            let texts = try await pipeline.run()
            guard sessionGeneration == generation, !Task.isCancelled else { return }
            onServiceSucceeded?(.recognition)
            markCurrentLatency(.asrFinal, generation: generation)
            realtimePipeline = nil
            let checkpoint = await makeRecoveryCheckpoint(segments: [], transcripts: texts, asrPlatform: platform, hotwords: hotwords, generation: generation)
            guard sessionGeneration == generation, !Task.isCancelled else { checkpoint.discard(); return }
            var diag = SessionDiagnostics()
            diag.recordingMs = recordingDurationMs
            diag = diagnosticsForCurrentAttempt(diag, generation: generation)
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
                let stopped = await drainCapture().value
                guard sessionGeneration == generation, !Task.isCancelled else { return }
                recordingDurationMs = stopped.durationMs
                pipeline.input.finish()
            }
            let snapshot = await pipeline.snapshot()
            guard sessionGeneration == generation, !Task.isCancelled else { return }
            let mapped = mapError(error)
            if !isOnboardingTrial, recordingDurationMs >= 500,
               !snapshot.audio.processedPCM.isEmpty || !snapshot.audio.rawPCM.isEmpty || !snapshot.transcripts.isEmpty {
                if case .transcriptTooLong = mapped {} else {
                    let checkpoint = await makeRecoveryCheckpoint(segments: [], transcripts: snapshot.transcripts,
                                                                   asrPlatform: platform, hotwords: hotwords, generation: generation)
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
        recoveryBuffer: RecordingRecoveryBuffer,
        hotwords: ASRHotwords
    ) async {
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
            asrProviderOverride?(asrConfig, hotwords) ?? asrProviderFactory.makeProvider(for: asrConfig, hotwords: hotwords)
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
            let denoiseStart = clock.now()
            let processedAudio: Data
            do {
                processedAudio = try audioPreprocessor.denoise(wavData: wavData)
            } catch {
                diagnostics.denoiseFailed(sessionID: sessionID, reason: "segment \(segment.index): \(error.localizedDescription)")
                // 降噪失败时使用原始音频
                processedAudio = wavData
            }
            let denoiseMs = clock.milliseconds(since: denoiseStart)
            totalDenoiseMs += denoiseMs

            guard await MainActor.run(body: { sessionGeneration }) == generation,
                  !Task.isCancelled else { return }

            // ASR 识别（动态超时：按 AGENTS.md 规范 min(90s, max(15s, duration * 1.3 + 10s))）
            let dynamicTimeout = min(90.0, max(15.0, segment.durationSeconds * 1.3 + 10.0))
            diagnostics.log(sessionID: sessionID, event: "segment_asr_started", detail: "index=\(segment.index) duration=\(Int(segment.durationSeconds * 1000))ms timeout=\(Int(dynamicTimeout))s")
            let asrStart = clock.now()
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
                let asrMs = clock.milliseconds(since: asrStart)
                diag.asrWorkMs = totalASRMs + asrMs
                diag.denoiseMs = totalDenoiseMs
                diag = await diagnosticsForCurrentAttempt(diag, generation: generation)
                diag.errorClassification = mapped.diagnosticClassification
                diag.segmentCount = segmentCount
                diag.segmentDiagnostics = segmentDiagList
                diagnostics.sessionError(sessionID: sessionID, error: mapped)
                diagnostics.sessionEnded(sessionID: sessionID, result: diag)
                firstASRError = mapped
                failedSegments.append(segment)
                // Seal the already-recorded tail before draining the stream into recovery.
                await sealRecordingAfterRecognitionFailure(generation: generation)
                continue
            }

            let accepted = await MainActor.run {
                guard sessionGeneration == generation, !Task.isCancelled else { return false }
                recoveryBuffer.complete(index: segment.index, text: transcriptResult.text)
                onServiceSucceeded?(.recognition)
                return true
            }
            guard accepted else { return }
            let asrMs = clock.milliseconds(since: asrStart)
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
                diag.asrWorkMs = totalASRMs
                diag.denoiseMs = totalDenoiseMs
                diag = await diagnosticsForCurrentAttempt(diag, generation: generation)
                diag.segmentCount = segmentCount
                diag.segmentDiagnostics = segmentDiagList
                let tooLongError = MemoEchoError.transcriptTooLong(charCount: accumulatedChars)
                diag.errorClassification = tooLongError.diagnosticClassification
                diagnostics.sessionError(sessionID: sessionID, error: tooLongError)
                diagnostics.sessionEnded(sessionID: sessionID, result: diag)
                await stopRecordingForTranscriptLimit(tooLongError, generation: generation)
                return
            }
        }

        // --- 流已结束（录音已停止，所有分段已处理）---

        guard await MainActor.run(body: { sessionGeneration }) == generation,
              !Task.isCancelled else { return }

        if firstASRError == nil { await markCurrentLatency(.asrFinal, generation: generation) }
        await MainActor.run {
            guard sessionGeneration == generation, !Task.isCancelled else { return }
            lastRecordedAudio = nil
            cleanupSegmenterState()
        }
        let checkpoint = await makeRecoveryCheckpoint(segments: failedSegments, transcripts: transcripts,
                                                       asrPlatform: selectedPlatform, hotwords: hotwords, generation: generation)
        if let firstASRError {
            await MainActor.run {
                guard sessionGeneration == generation, !Task.isCancelled else { return }
                if !isOnboardingTrial { retainRecovery(checkpoint) }
                handleError(firstASRError)
            }
            return
        }
        diag.asrWorkMs = totalASRMs
        diag.denoiseMs = totalDenoiseMs
        diag.segmentCount = segmentCount
        diag.segmentDiagnostics = segmentDiagList
        diag.recordingMs = await MainActor.run { recordingDurationMs }
        diagnostics.log(sessionID: sessionID, event: "asr_completed",
                        detail: "chars=\(transcripts.joined().count) cold=\(wasColdStart)")
        diag = await diagnosticsForCurrentAttempt(diag, generation: generation)
        await runCheckpoint(checkpoint, generation: generation, sessionID: sessionID, diagnostics: diag)
    }

    private func makeRecoveryCheckpoint(segments: [SealedSegment], transcripts: [String],
                                        asrPlatform: ASRPlatform, hotwords: ASRHotwords,
                                        generation: UInt64) async -> SessionRecoveryCheckpoint {
        let waitStarted = clock.now()
        await windowContextTask?.value
        if generation == sessionGeneration {
            latencyTimeline?.contextWaitMs += clock.milliseconds(since: waitStarted)
            markCurrentLatency(.contextReady, generation: generation, at: windowContextReadyAt ?? latencyTimeline?.startedAt ?? clock.now())
        }
        return .init(segments: segments, transcripts: transcripts, mode: processingMode,
              language: configStore.generalConfig.translationTargetLanguage, asrPlatform: asrPlatform,
              target: targetInput, context: configStore.windowContextEnabled ? capturedWindowContext : nil, hotwords: hotwords)
    }

    /// Called after an ASR error, including during the final 100ms sound delay.
    private func sealRecordingAfterRecognitionFailure(generation: UInt64) async {
        guard generation == sessionGeneration, !Task.isCancelled, state == .recording else { return }
        recordingStopTask?.cancel()
        recordingStopTask = nil
        soundCueTask?.cancel()
        soundCueTask = nil
        let stopped = await drainCapture().value
        guard generation == sessionGeneration, !Task.isCancelled else { return }
        recordingDurationMs = stopped.durationMs
        lastRecordedAudio = nil
        segmenter.finalize()
        segmentContinuation?.finish()
        state = .transcribing
    }

    private func stopRecordingForTranscriptLimit(_ error: MemoEchoError, generation: UInt64) async {
        guard generation == sessionGeneration, !Task.isCancelled else { return }
        if state == .recording {
            recordingStopTask?.cancel()
            recordingStopTask = nil
            soundCueTask?.cancel()
            soundCueTask = nil
            _ = await drainCapture().value
            guard generation == sessionGeneration, !Task.isCancelled else { return }
            cleanupSegmenterState()
        }
        handleError(error)
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
        latencyTimeline = SessionLatencyTimeline(origin: .recoveryAttempt, path: .recovery, startedAt: clock.now())
        lastLatencyDiagnostics = nil
        markCurrentLatency(.contextReady, generation: generation)
        textOutput = .focusedApplication
        currentError = nil
        currentFailureIsLocal = false
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
        let hotwords = checkpoint.hotwords
        let provider = asrProviderOverride?(asrConfig, hotwords)
            ?? ASRProviderFactory(runtimeManager: asrRuntimeManager).makeProvider(for: asrConfig, hotwords: hotwords)
        let generation = sessionGeneration
        let llmConfig = configStore.llmConfig
        let apiKey = configStore.openAIAPIKey
        onLLMRequestPrepared?(.init(baseURL: llmConfig.baseURL, apiKey: apiKey, model: llmConfig.model,
                                   omitThinkingParameter: configStore.omitThinkingParameter))
        let isConfigured = configStore.isLLMConfigured
        let terms = dictionaryStore?.termsForPrompt() ?? []
        let sessionID = currentSessionID
        let logger = diagnostics
        promptTermIndex.prepare(terms)
        let llm = LLMProvider(baseURL: llmConfig.baseURL, apiKey: apiKey, model: llmConfig.model,
                              omitThinkingParameter: configStore.omitThinkingParameter,
                              dictionaryTerms: terms,
                              preparedTermIndex: promptTermIndex.ready(for: terms),
                              onThinkingUnsupported: { [weak self] in
            guard let self, self.sessionGeneration == generation, self.configStore.llmConfig.baseURL == llmConfig.baseURL,
                  self.configStore.llmConfig.model == llmConfig.model,
                  self.configStore.openAIAPIKey == apiKey else { return }
            try? self.configStore.markThinkingParameterUnsupported(for: llmConfig, apiKey: apiKey)
        }, onRequestMetrics: { metrics in logger.llmRequest(sessionID: sessionID, metrics: metrics) },
        windowContextEnabled: { [configStore] in configStore.windowContextEnabled })
        let preprocessor = audioPreprocessor
        let beforeRequest = beforeServiceRequest
        let reportSuccess: @MainActor @Sendable (SessionRecoveryCheckpoint.Stage) -> Void = { [weak self] stage in
            guard let self, self.sessionGeneration == generation, !Task.isCancelled else { return }
            self.onServiceSucceeded?(stage)
        }
        var processor = SessionRecoveryProcessor(recognize: { segment in
            try await beforeRequest?(.recognition)
            let audio = await Task.detached {
                let wav = WAVAudioEncoder.encodePCM16(pcmData: segment.pcmData,
                                                       sampleRate: AudioSegmenter.sampleRate, channels: 1)
                return (try? preprocessor.denoise(wavData: wav)) ?? wav
            }.value
            try Task.checkCancellation()
            let timeout = min(90.0, max(15.0, segment.durationSeconds * 1.3 + 10.0))
            let result = try await provider.recognize(audioData: audio, timeout: timeout).text
            reportSuccess(.recognition)
            return result
        }, polish: { transcripts, context in
            guard isConfigured else { throw MemoEchoError.llmConfigurationIncomplete }
            try await beforeRequest?(.polish)
            try Task.checkCancellation()
            let result = try await llm.polish(text: transcripts.joined(), segmentCount: transcripts.count,
                                              context: WindowContextService.sanitized(context))
            reportSuccess(.polish)
            return result
        }, translate: { text, language, context in
            guard isConfigured else { throw MemoEchoError.llmConfigurationIncomplete }
            try await beforeRequest?(.translation)
            try Task.checkCancellation()
            let result = try await llm.translate(text: text, targetLanguage: language,
                                                 context: WindowContextService.sanitized(context))
            reportSuccess(.translation)
            return result
        })
        if asrConfig.selectedPlatform.isRealtime {
            let replayConfig = asrConfig
            processor.recognizeRealtime = { audio in
                try await beforeRequest?(.recognition)
                try Task.checkCancellation()
                let result = try await RealtimeRecognitionPipeline.replay(audio, config: replayConfig, hotwords: hotwords)
                reportSuccess(.recognition)
                return result
            }
        }
        return processor
    }

    private func runCheckpoint(_ checkpoint: SessionRecoveryCheckpoint, generation: UInt64,
                               sessionID: String, diagnostics initial: SessionDiagnostics = .init()) async {
        var diag = initial
        let recoveryAttempt = isRecovering
        diagnostics.log(sessionID: sessionID, event: "recovery_attempt", detail: recoveryAttempt ? "1" : "0")
        let attemptTimeline = latencyTimeline
        var stageStart = clock.now()
        var activeStage: SessionRecoveryCheckpoint.Stage?
        func finishStageTiming() {
            let elapsed = clock.milliseconds(since: stageStart)
            switch activeStage {
            case .recognition: diag.asrWorkMs = (diag.asrWorkMs ?? 0) + elapsed
            case .polish, .translation: diag.llmMs = (diag.llmMs ?? 0) + elapsed
            case .output: diag.injectionMs = (diag.injectionMs ?? 0) + elapsed
            case nil: break
            }
            stageStart = clock.now()
        }
        do {
            let processor = makeRecoveryProcessor(checkpoint)
            let text = try await processor.process(checkpoint, shouldContinue: { self.sessionGeneration == generation }, onStage: { stage in
                finishStageTiming()
                if activeStage == .recognition, stage != .recognition {
                    self.markCurrentLatency(.asrFinal, generation: generation)
                }
                if stage == .output, activeStage == .polish || activeStage == .translation {
                    self.markCurrentLatency(.llmComplete, generation: generation)
                }
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
                                               onOutputDispatched: {
                    outputFeedbackSent = true
                    self.emitLatency(.dispatched, timeline: attemptTimeline, generation: generation, sessionID: sessionID)
                    self.onFeedbackEvent?(.outputDispatched)
                }, onCleanupCompleted: {
                    self.emitLatency(.cleanupComplete, timeline: attemptTimeline, generation: generation, sessionID: sessionID)
                })
            }
            if result == nil {
                emitLatency(.dispatched, timeline: attemptTimeline, generation: generation, sessionID: sessionID)
                emitLatency(.cleanupComplete, timeline: attemptTimeline, generation: generation, sessionID: sessionID)
            }
            guard sessionGeneration == generation, !Task.isCancelled else { return }
            if let result { diagnostics.injectionCompleted(sessionID: sessionID, path: result.path, breakdown: result.breakdown) }
            isRecovering = false
            if !isOnboardingTrial {
                lastInjectionFailureText = nil
                // The learner independently establishes its baseline; it never gates delivery.
                beginPostInjectionLearningIfNeeded(generation: generation, mode: checkpoint.mode, sessionID: sessionID,
                                                   beforeInjection: result?.beforeInjection, insertedText: text)
                discardRecovery()
            }
            checkpoint.discard()
            targetInput = nil
            lastResult = nil
            clearWindowContextCapture()
            state = .done
            finishStageTiming()
            diag = diagnosticsForCurrentAttempt(diag, generation: generation)
            diagnostics.sessionEnded(sessionID: sessionID, result: diag)
            if !outputFeedbackSent {
                onFeedbackEvent?(.processingFinished)
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
            diag = diagnosticsForCurrentAttempt(diag, generation: generation)
            diag.errorClassification = mapped.diagnosticClassification
            diagnostics.sessionError(sessionID: sessionID, error: mapped)
            diagnostics.sessionEnded(sessionID: sessionID, result: diag)
            handleError(mapped, failedStage: checkpoint.stage)
        }
    }

    private func markCurrentLatency(_ milestone: SessionLatencyTimeline.Milestone, generation: UInt64,
                                    at instant: ContinuousClock.Instant? = nil) {
        guard generation == sessionGeneration else { return }
        emitLatency(milestone, timeline: latencyTimeline, generation: generation,
                    sessionID: currentSessionID, at: instant)
    }

    private func emitLatency(_ milestone: SessionLatencyTimeline.Milestone, timeline: SessionLatencyTimeline?,
                             generation: UInt64, sessionID: String, at instant: ContinuousClock.Instant? = nil) {
        guard let timeline else { return }
        timeline.mark(milestone, at: instant ?? clock.now())
        let snapshot = timeline.snapshot(at: clock.now())
        if generation == sessionGeneration, timeline === latencyTimeline { lastLatencyDiagnostics = snapshot }
        diagnostics.latencyMilestone(sessionID: sessionID, milestone: milestone, snapshot: snapshot)
        onLatencyMilestone?(sessionID, milestone, snapshot)
    }

    private func diagnosticsForCurrentAttempt(_ initial: SessionDiagnostics, generation: UInt64) -> SessionDiagnostics {
        guard generation == sessionGeneration, let latencyTimeline else { return initial }
        var result = initial
        let snapshot = latencyTimeline.snapshot(at: clock.now())
        result.latency = snapshot
        result.asrWaitMs = snapshot.asrWaitMs
        result.totalMs = snapshot.elapsedMs
        lastLatencyDiagnostics = snapshot
        return result
    }

    // MARK: - Segmenter Cleanup

    private func cleanupSegmenterState() {
        recordingHotwords = .empty
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
        currentFailureIsLocal = error is RealtimePipelineError
            || ServiceProbeFailure.isCancellation(error)
            || (error as? RealtimeASRError) == .invalidState
            || (error as? RealtimeASRError) == .sessionLimit
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
        windowContextReadyAt = clock.now()
        guard configStore.windowContextEnabled else { return }
        windowContextReadyAt = nil

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
            self.windowContextReadyAt = self.clock.now()
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
        windowContextReadyAt = nil
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
