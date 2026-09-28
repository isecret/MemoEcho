import Foundation

@MainActor
@Observable
final class VoiceInputReadinessService {
    private let configStore: ConfigStore
    private let permissionsManager: PermissionsManager
    private let llmValidationService: LLMValidationService
    private let cloudASRValidationService: CloudASRValidationService

    var hotkeyRegistrationResult: HotkeyRegistrationResult = .failure("快捷键还未启用")

    init(
        configStore: ConfigStore,
        permissionsManager: PermissionsManager,
        llmValidationService: LLMValidationService,
        cloudASRValidationService: CloudASRValidationService
    ) {
        self.configStore = configStore
        self.permissionsManager = permissionsManager
        self.llmValidationService = llmValidationService
        self.cloudASRValidationService = cloudASRValidationService
    }

    var snapshot: VoiceInputReadiness {
        VoiceInputReadiness.make(
            hotkeyResult: hotkeyRegistrationResult,
            hasConfirmedHotkey: configStore.onboardingProgress.hasConfirmedHotkey,
            microphone: permissionsManager.microphoneStatus,
            accessibility: permissionsManager.accessibilityStatus,
            asrConfig: configStore.asrConfig,
            localModelsAvailable: ConfigStore.localModelsAvailable(),
            cloudStatus: cloudASRValidationService.status(for: cloudInput),
            llmStatus: llmValidationService.status(for: llmInput)
        )
    }

    /// 权限和文件重新检查；验证服务合并进行中的请求并记住当前配置的验证结果。
    func refresh() {
        permissionsManager.refreshAll()
        configStore.refreshLocalModelStatusFromDisk()
        cloudASRValidationService.syncFromConfig(for: cloudInput)
        cloudASRValidationService.validate(cloudInput)
        llmValidationService.validate(llmInput)
    }

    func retryValidation(for step: SetupStep) {
        switch step {
        case .asr: cloudASRValidationService.validate(cloudInput, force: true)
        case .llm: llmValidationService.validate(llmInput, force: true)
        default: break
        }
    }

    private var llmInput: LLMValidationInput {
        LLMValidationInput(
            baseURL: configStore.llmConfig.baseURL,
            apiKey: configStore.openAIAPIKey,
            model: configStore.llmConfig.model,
            omitThinkingParameter: configStore.omitThinkingParameter
        )
    }

    private var cloudInput: CloudASRValidationInput {
        CloudASRValidationInput(platform: configStore.asrConfig.selectedPlatform, asrConfig: configStore.asrConfig)
    }
}
