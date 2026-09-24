import Foundation

enum OnboardingTrialPhase {
    case idle, recording, processing, succeeded, failed

    var isActive: Bool { self == .recording || self == .processing }
}

@MainActor
@Observable
final class OnboardingCoordinator {
    let configStore: ConfigStore
    let permissionsManager: PermissionsManager
    let modelDownloadManager: ModelDownloadManager
    let llmModelListService: LLMModelListService
    let llmValidationService: LLMValidationService
    let cloudASRValidationService: CloudASRValidationService
    private let readinessService: VoiceInputReadinessService

    private(set) var step: SetupStep = .welcome
    private(set) var isPresented = false
    private(set) var lastErrorMessage: String?
    var trialText = ""
    private(set) var trialPhase: OnboardingTrialPhase = .idle
    private var trialID: UUID?

    var onApplyHotkey: ((HotkeyCombo) -> HotkeyRegistrationResult)?
    var onHotkeyCaptureSuspended: ((Bool) -> Void)?
    var onFinish: (() -> Void)?
    var onCancelTrial: (() -> Void)?
    var onOpenRecoverySettings: ((SetupStep) -> Void)?

    init(
        configStore: ConfigStore,
        permissionsManager: PermissionsManager,
        modelDownloadManager: ModelDownloadManager,
        llmModelListService: LLMModelListService,
        llmValidationService: LLMValidationService,
        cloudASRValidationService: CloudASRValidationService,
        readinessService: VoiceInputReadinessService
    ) {
        self.configStore = configStore
        self.permissionsManager = permissionsManager
        self.modelDownloadManager = modelDownloadManager
        self.llmModelListService = llmModelListService
        self.llmValidationService = llmValidationService
        self.cloudASRValidationService = cloudASRValidationService
        self.readinessService = readinessService
    }

    var readiness: VoiceInputReadiness { readinessService.snapshot }

    var canContinue: Bool {
        switch step {
        case .welcome: true
        case .asr: readiness.asr.isReady
        case .llm: readiness.llm.isReady
        case .permissions: readiness.microphone.isReady && readiness.accessibility.isReady
        case .hotkey:
            readinessService.hotkeyRegistrationResult == .success
                && readiness.asr.isReady && readiness.llm.isReady
                && readiness.microphone.isReady && readiness.accessibility.isReady
        case .tryIt: !trialPhase.isActive
        }
    }

    var primaryActionTitle: String {
        switch step {
        case .welcome: "开始设置"
        case .asr where configStore.asrConfig.selectedPlatform == .localSenseVoice
            && modelDownloadManager.isDownloading: "正在下载…"
        case .hotkey: "完成设置"
        case .tryIt: "开始使用"
        default: "继续"
        }
    }

    func prepareForPresentation(at requestedStep: SetupStep? = nil) {
        guard !isPresented else { return }
        refresh()
        let progress = configStore.onboardingProgress
        let destination = requestedStep ?? (progress.hasFinishedPresentation
            ? readiness.nextRequiredStep ?? .tryIt
            : progress.lastVisitedStep)
        isPresented = true
        go(to: destination)
    }

    func dismissed() {
        isPresented = false
        cancelTrial()
        trialText = ""
        setHotkeyCaptureSuspended(false)
    }

    func go(to destination: SetupStep) {
        lastErrorMessage = nil
        var progress = configStore.onboardingProgress
        progress.lastVisitedStep = destination
        guard save(progress) else { return }
        if step != destination {
            cancelTrial()
        }
        step = destination
    }

    var canStartTrial: Bool {
        // The trial always delivers to this page, independent of text-editor
        // focus. AppCoordinator still requires the onboarding window to be key.
        isPresented && step == .tryIt && configStore.hasCompletedInitialSetup
            && !trialPhase.isActive && !permissionsManager.isHandlingAuthorization && readiness.isReady
    }

    /// 只由用户的快捷键操作调用；配置/授权回调不会启动试用。
    func beginTrial() -> UUID? {
        refresh()
        guard canStartTrial else { return nil }
        let id = UUID()
        trialID = id
        lastErrorMessage = nil
        trialPhase = .recording
        return id
    }

    @discardableResult
    func receiveTrialText(_ text: String, for id: UUID) -> Bool {
        guard isPresented, step == .tryIt, trialID == id, trialPhase.isActive else { return false }
        trialText += trialText.isEmpty ? text : "\n" + text
        return true
    }

    func handleTrialFeedback(_ event: SessionFeedbackEvent, error: MemoEchoError?) {
        guard trialID != nil else { return }
        switch event {
        case .recordingStarted: trialPhase = .recording
        case .recordingStopped: trialPhase = .processing
        case .processingFinished:
            trialPhase = .succeeded
            trialID = nil
        case .processingCancelled:
            trialPhase = .idle
            trialID = nil
        case .processingFailed:
            trialPhase = .failed
            lastErrorMessage = error?.userMessage ?? "试用失败，请检查配置后重试。"
            trialID = nil
        default: break
        }
    }

    private func cancelTrial() {
        let wasActive = trialID != nil
        trialID = nil
        trialPhase = .idle
        if wasActive { onCancelTrial?() }
    }

    func goBack() {
        guard step != .tryIt else { return }
        guard let index = SetupStep.allCases.firstIndex(of: step), index > 0 else { return }
        go(to: SetupStep.allCases[index - 1])
    }

    func goForward() {
        guard isPresented else { return }
        refresh()
        guard canContinue else { return }
        if step == .tryIt {
            dismissed()
            onFinish?()
            return
        }
        if step == .hotkey {
            var progress = configStore.onboardingProgress
            progress.hasConfirmedHotkey = true
            progress.hasFinishedPresentation = true
            progress.lastVisitedStep = .tryIt
            guard save(progress) else { return }
            refresh()
            step = .tryIt
            return
        }
        guard let index = SetupStep.allCases.firstIndex(of: step), index + 1 < SetupStep.allCases.count else { return }
        go(to: SetupStep.allCases[index + 1])
    }

    func refresh() { readinessService.refresh() }

    func openRecoverySettings(for step: SetupStep) {
        onOpenRecoverySettings?(step)
    }

    func selectASRPlatform(_ platform: ASRPlatform) {
        var config = configStore.asrConfig
        config.selectedPlatform = platform
        do {
            try configStore.saveASRConfig(config)
            lastErrorMessage = nil
            refresh()
        } catch {
            lastErrorMessage = "无法保存识别方式，请重试。"
        }
    }

    func startModelDownload() {
        lastErrorMessage = nil
        modelDownloadManager.startDownload()
    }

    func retryCurrentValidation() {
        lastErrorMessage = nil
        readinessService.retryValidation(for: step)
    }

    func requestNextPermission() {
        permissionsManager.refreshAll()
        guard !permissionsManager.isHandlingAuthorization else { return }
        lastErrorMessage = nil
        switch permissionsManager.microphoneStatus {
        case .notDetermined:
            Task { @MainActor [weak self] in
                guard let self else { return }
                await permissionsManager.requestMicrophonePermission()
                refresh()
            }
        case .denied:
            permissionsManager.openMicrophoneSettings()
        case .restricted:
            lastErrorMessage = "麦克风访问受系统限制，请联系设备管理员。"
        case .granted:
            permissionsManager.promptAndOpenAccessibilitySettings()
            lastErrorMessage = permissionsManager.accessibilityGuideError
        }
    }

    @discardableResult
    func applyHotkey(_ combo: HotkeyCombo) -> Bool {
        let result = onApplyHotkey?(combo) ?? .failure("快捷键暂时不可用")
        guard result == .success else {
            lastErrorMessage = result.errorMessage
            return false
        }
        lastErrorMessage = nil
        return true
    }

    func setHotkeyCaptureSuspended(_ value: Bool) {
        onHotkeyCaptureSuspended?(value)
    }

    private func save(_ progress: OnboardingProgress) -> Bool {
        do {
            try configStore.saveOnboardingProgress(progress)
            return true
        } catch {
            lastErrorMessage = "无法保存设置进度，请检查配置目录权限后重试。"
            return false
        }
    }
}
