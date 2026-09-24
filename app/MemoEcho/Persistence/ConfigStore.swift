import Foundation

/// 配置中心：全部配置统一存储到 ~/.memoecho/config.json
@MainActor
@Observable
final class ConfigStore {
    // MARK: - 公开配置

    private(set) var llmConfig = LLMConfig()
    private(set) var generalConfig = GeneralConfig()
    private(set) var asrConfig = ASRConfig()
    private(set) var audioInputConfig = AudioInputConfig.systemDefault
    private(set) var onboardingProgress = OnboardingProgress()

    // MARK: - 密钥（启动时从配置文件直接加载到内存）

    private(set) var openAIAPIKey: String = ""

    /// 配置文件加载是否失败（损坏等情况），用于区分 fresh install 与 corrupt config
    private(set) var configLoadFailed: Bool = false

    // MARK: - 首次配置判断

    /// 用户已完成引导展示；运行条件由 VoiceInputReadiness 独立判断。
    var hasCompletedInitialSetup: Bool {
        onboardingProgress.hasFinishedPresentation && !configLoadFailed
    }

    /// A corrupt existing file belongs in Settings for repair, not in first-run setup.
    var requiresInitialSetup: Bool {
        !onboardingProgress.hasFinishedPresentation && !configLoadFailed
    }

    var canOpenSettings: Bool { !requiresInitialSetup }

    var isLLMConfigured: Bool {
        !llmConfig.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !llmConfig.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 当前选中的 ASR 平台是否可用
    var isASRReady: Bool {
        asrConfig.isReady(localModelsAvailable: Self.localModelsAvailable())
    }

    /// ASR 平台不可用的原因描述
    var asrNotReadyReason: String? {
        asrConfig.notReadyReason(localModelsAvailable: Self.localModelsAvailable())
    }

    // MARK: - 配置文件路径

    private let configDirectory: URL
    private let configFileURL: URL

    // MARK: - 配置文件模型

    private struct ConfigFile: Codable {
        var llm: LLMFileConfig = LLMFileConfig()
        var general: GeneralFileConfig = GeneralFileConfig()
        var asr: ASRConfig = ASRConfig()
        var audio: AudioInputConfig = .systemDefault
        var onboarding: OnboardingProgress = OnboardingProgress()

        init(
            llm: LLMFileConfig = LLMFileConfig(),
            general: GeneralFileConfig = GeneralFileConfig(),
            asr: ASRConfig = ASRConfig(),
            audio: AudioInputConfig = .systemDefault,
            onboarding: OnboardingProgress = OnboardingProgress()
        ) {
            self.llm = llm
            self.general = general
            self.asr = asr
            self.audio = audio
            self.onboarding = onboarding
        }

        struct LLMFileConfig: Codable {
            var baseURL: String = ""
            var model: String = ""
            var apiKey: String = ""
            var thinkingDisabled: Bool = false
        }

        struct GeneralFileConfig: Codable {
            var hotkey: HotkeyCombo = .default
            var interactionSoundEnabled: Bool = true
            var translationTargetLanguage: TranslationTargetLanguage = .english
            var launchAtLogin: Bool = false

            init(
                hotkey: HotkeyCombo = .default,
                interactionSoundEnabled: Bool = true,
                translationTargetLanguage: TranslationTargetLanguage = .english,
                launchAtLogin: Bool = false
            ) {
                self.hotkey = hotkey
                self.interactionSoundEnabled = interactionSoundEnabled
                self.translationTargetLanguage = translationTargetLanguage
                self.launchAtLogin = launchAtLogin
            }

            var publicConfig: GeneralConfig {
                GeneralConfig(
                    hotkey: hotkey,
                    interactionSoundEnabled: interactionSoundEnabled,
                    translationTargetLanguage: translationTargetLanguage,
                    launchAtLogin: launchAtLogin
                )
            }
        }
    }

    // MARK: - 初始化

    init(configDirectory: URL? = nil) {
        self.configDirectory = configDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".memoecho", isDirectory: true)
        self.configFileURL = self.configDirectory.appendingPathComponent("config.json")
        loadAll()
    }

    // MARK: - 加载

    func loadAll() {
        let fileURL = configFileURL

        if FileManager.default.fileExists(atPath: fileURL.path) {
            // 配置文件已存在，尝试加载
            do {
                let data = try Data(contentsOf: fileURL)
                let configFile = try JSONDecoder().decode(ConfigFile.self, from: data)
                applyConfigFile(configFile)
                configLoadFailed = false
            } catch {
                // 保留损坏文件，交由设置页显式修复；不要自动进入首次向导。
                applyConfigFile(ConfigFile(onboarding: OnboardingProgress(
                    lastVisitedStep: .tryIt, hasFinishedPresentation: true, hasConfirmedHotkey: true
                )))
                configLoadFailed = true
            }
        } else {
            let initial = ConfigFile()
            applyConfigFile(initial)
            configLoadFailed = false
            try? writeConfigFile(initial)
        }

        if !configLoadFailed { refreshLocalModelStatusFromDisk() }
    }

    // MARK: - LLM 配置保存

    func saveLLMConfig(_ config: LLMConfig, apiKey: String) throws {
        let trimmedURL = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedURL.isEmpty, URL(string: trimmedURL) == nil {
            throw ConfigValidationError.invalidURL(trimmedURL)
        }

        var normalConfig = config
        normalConfig.baseURL = trimmedURL
        normalConfig.model = trimmedModel
        normalConfig.thinkingDisabled = shouldResetThinkingDisabled(
            baseURL: trimmedURL,
            model: trimmedModel,
            apiKey: trimmedKey
        ) ? false : llmConfig.thinkingDisabled

        var configFile = buildConfigFile()
        configFile.llm = ConfigFile.LLMFileConfig(
            baseURL: trimmedURL,
            model: trimmedModel,
            apiKey: trimmedKey,
            thinkingDisabled: normalConfig.thinkingDisabled
        )
        try writeConfigFile(configFile)

        llmConfig = normalConfig
        openAIAPIKey = trimmedKey
    }

    func markThinkingDisabledForCurrentLLM() throws {
        guard !llmConfig.thinkingDisabled else { return }

        llmConfig.thinkingDisabled = true
        var configFile = buildConfigFile()
        configFile.llm.thinkingDisabled = true
        try writeConfigFile(configFile)
    }

    // MARK: - 通用配置保存

    func saveGeneralConfig(_ config: GeneralConfig, confirmingHotkey: Bool = false) throws {
        var configFile = buildConfigFile()
        configFile.general = ConfigFile.GeneralFileConfig(
            hotkey: config.hotkey,
            interactionSoundEnabled: config.interactionSoundEnabled,
            translationTargetLanguage: config.translationTargetLanguage,
            launchAtLogin: config.launchAtLogin
        )
        if confirmingHotkey {
            configFile.onboarding.hasConfirmedHotkey = true
        }
        try writeConfigFile(configFile)

        generalConfig = config
        onboardingProgress = configFile.onboarding
    }

    // MARK: - ASR 配置保存

    func saveASRConfig(_ config: ASRConfig) throws {
        var normalizedConfig = config
        invalidateCloudValidationStateIfNeeded(from: asrConfig, to: &normalizedConfig)

        var configFile = buildConfigFile()
        configFile.asr = normalizedConfig
        try writeConfigFile(configFile)

        asrConfig = normalizedConfig
    }

    // MARK: - 音频输入配置保存

    func saveOnboardingProgress(_ progress: OnboardingProgress) throws {
        let normalized = OnboardingProgress(
            lastVisitedStep: progress.lastVisitedStep,
            hasFinishedPresentation: progress.hasFinishedPresentation,
            hasConfirmedHotkey: progress.hasConfirmedHotkey,
            hasAttemptedAccessibilityDrag: progress.hasAttemptedAccessibilityDrag
        )
        var configFile = buildConfigFile()
        configFile.onboarding = normalized
        try writeConfigFile(configFile)
        onboardingProgress = normalized
        configLoadFailed = false
    }

    func saveAudioInputConfig(_ config: AudioInputConfig) throws {
        var configFile = buildConfigFile()
        configFile.audio = config
        try writeConfigFile(configFile)

        audioInputConfig = config
    }

    func updateLocalModelStatus(_ status: LocalModelStatus, error: String? = nil) throws {
        asrConfig.local.modelStatus = status
        asrConfig.local.lastError = error
        var configFile = buildConfigFile()
        configFile.asr = asrConfig
        try writeConfigFile(configFile)
    }

    func updateCloudValidationState(
        for platform: ASRPlatform,
        status: CloudASRValidationStatus,
        error: String? = nil
    ) throws {
        var updatedConfig = asrConfig

        switch platform {
        case .localSenseVoice:
            return
        case .tencentCloudSentence:
            updatedConfig.tencentCloud.validationStatus = status
            updatedConfig.tencentCloud.lastValidationError = error
        case .aliyunSentence:
            updatedConfig.aliyun.validationStatus = status
            updatedConfig.aliyun.lastValidationError = error
        case .volcengineSentence:
            updatedConfig.volcengine.validationStatus = status
            updatedConfig.volcengine.lastValidationError = error
        case .xunfeiSentence:
            updatedConfig.xunfei.validationStatus = status
            updatedConfig.xunfei.lastValidationError = error
        case .xiaomiMiMoASR:
            updatedConfig.xiaomiMiMo.validationStatus = status
            updatedConfig.xiaomiMiMo.lastValidationError = error
        case .xiaomiMiMoTokenPlanASR:
            updatedConfig.xiaomiMiMoTokenPlan.validationStatus = status
            updatedConfig.xiaomiMiMoTokenPlan.lastValidationError = error
        }

        var configFile = buildConfigFile()
        configFile.asr = updatedConfig
        try writeConfigFile(configFile)
        asrConfig = updatedConfig
    }

    func refreshLocalModelStatusFromDisk() {
        guard !configLoadFailed else { return }
        guard asrConfig.local.modelStatus != .downloading else { return }

        let hasLocalModels = Self.localModelsAvailable()
        let currentStatus = asrConfig.local.modelStatus

        if hasLocalModels, currentStatus != .ready {
            try? updateLocalModelStatus(.ready)
        } else if !hasLocalModels, currentStatus == .ready {
            try? updateLocalModelStatus(.notDownloaded)
        }
    }

    // MARK: - 内部方法

    /// 将 ConfigFile 映射到公开属性
    private func applyConfigFile(_ configFile: ConfigFile) {
        llmConfig = LLMConfig(
            baseURL: configFile.llm.baseURL,
            model: configFile.llm.model,
            thinkingDisabled: configFile.llm.thinkingDisabled
        )
        openAIAPIKey = configFile.llm.apiKey

        generalConfig = configFile.general.publicConfig
        asrConfig = normalizedInterruptedCloudValidationStates(in: configFile.asr)
        audioInputConfig = configFile.audio
        onboardingProgress = configFile.onboarding
    }

    /// 从当前内存状态构建 ConfigFile
    private func buildConfigFile() -> ConfigFile {
        ConfigFile(
            llm: ConfigFile.LLMFileConfig(
                baseURL: llmConfig.baseURL,
                model: llmConfig.model,
                apiKey: openAIAPIKey,
                thinkingDisabled: llmConfig.thinkingDisabled
            ),
            general: ConfigFile.GeneralFileConfig(
                hotkey: generalConfig.hotkey,
                interactionSoundEnabled: generalConfig.interactionSoundEnabled,
                translationTargetLanguage: generalConfig.translationTargetLanguage,
                launchAtLogin: generalConfig.launchAtLogin
            ),
            asr: asrConfig,
            audio: audioInputConfig,
            onboarding: onboardingProgress
        )
    }

    private func shouldResetThinkingDisabled(baseURL: String, model: String, apiKey: String) -> Bool {
        llmConfig.baseURL != baseURL
            || llmConfig.model != model
            || openAIAPIKey != apiKey
    }

    private func invalidateCloudValidationStateIfNeeded(from oldConfig: ASRConfig, to newConfig: inout ASRConfig) {
        if oldConfig.tencentCloud.secretId != newConfig.tencentCloud.secretId
            || oldConfig.tencentCloud.secretKey != newConfig.tencentCloud.secretKey {
            newConfig.tencentCloud.validationStatus = .unvalidated
            newConfig.tencentCloud.lastValidationError = nil
        }

        if oldConfig.aliyun.accessKeyId != newConfig.aliyun.accessKeyId
            || oldConfig.aliyun.accessKeySecret != newConfig.aliyun.accessKeySecret
            || oldConfig.aliyun.appKey != newConfig.aliyun.appKey {
            newConfig.aliyun.validationStatus = .unvalidated
            newConfig.aliyun.lastValidationError = nil
        }

        if oldConfig.volcengine.apiKey != newConfig.volcengine.apiKey {
            newConfig.volcengine.validationStatus = .unvalidated
            newConfig.volcengine.lastValidationError = nil
        }

        if oldConfig.xunfei.appID != newConfig.xunfei.appID
            || oldConfig.xunfei.apiKey != newConfig.xunfei.apiKey
            || oldConfig.xunfei.apiSecret != newConfig.xunfei.apiSecret {
            newConfig.xunfei.validationStatus = .unvalidated
            newConfig.xunfei.lastValidationError = nil
        }

        if oldConfig.xiaomiMiMo.apiKey != newConfig.xiaomiMiMo.apiKey {
            newConfig.xiaomiMiMo.validationStatus = .unvalidated
            newConfig.xiaomiMiMo.lastValidationError = nil
        }

        if oldConfig.xiaomiMiMoTokenPlan.apiKey != newConfig.xiaomiMiMoTokenPlan.apiKey {
            newConfig.xiaomiMiMoTokenPlan.validationStatus = .unvalidated
            newConfig.xiaomiMiMoTokenPlan.lastValidationError = nil
        }
    }

    private func normalizedInterruptedCloudValidationStates(in config: ASRConfig) -> ASRConfig {
        var normalized = config

        if normalized.tencentCloud.validationStatus == .validating {
            normalized.tencentCloud.validationStatus = .unvalidated
            normalized.tencentCloud.lastValidationError = nil
        }

        if normalized.aliyun.validationStatus == .validating {
            normalized.aliyun.validationStatus = .unvalidated
            normalized.aliyun.lastValidationError = nil
        }

        if normalized.volcengine.validationStatus == .validating {
            normalized.volcengine.validationStatus = .unvalidated
            normalized.volcengine.lastValidationError = nil
        }

        if normalized.xunfei.validationStatus == .validating {
            normalized.xunfei.validationStatus = .unvalidated
            normalized.xunfei.lastValidationError = nil
        }

        if normalized.xiaomiMiMo.validationStatus == .validating {
            normalized.xiaomiMiMo.validationStatus = .unvalidated
            normalized.xiaomiMiMo.lastValidationError = nil
        }

        if normalized.xiaomiMiMoTokenPlan.validationStatus == .validating {
            normalized.xiaomiMiMoTokenPlan.validationStatus = .unvalidated
            normalized.xiaomiMiMoTokenPlan.lastValidationError = nil
        }

        return normalized
    }

    static func localModelsAvailable() -> Bool {
        let fm = FileManager.default

        for fileName in LocalASRConfig.requiredFileNames {
            let fileURL = LocalASRConfig.modelRoot.appendingPathComponent(fileName)
            guard fm.fileExists(atPath: fileURL.path),
                  ((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 else {
                return false
            }
        }

        return true
    }

    /// 原子写入配置文件，确保目录和文件权限正确
    private func writeConfigFile(_ configFile: ConfigFile) throws {
        let fm = FileManager.default
        let dirURL = configDirectory
        let fileURL = configFileURL

        // 确保目录存在且权限为 0700
        if !fm.fileExists(atPath: dirURL.path) {
            try fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dirURL.path)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configFile)

        try data.write(to: fileURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        configLoadFailed = false
    }

}
