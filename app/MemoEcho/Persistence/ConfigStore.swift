import Foundation

/// User preferences and credentials live in config.json; durable app state lives in state.json.
@MainActor
@Observable
final class ConfigStore {
    private(set) var llmConfig = LLMConfig()
    private(set) var generalConfig = GeneralConfig()
    private(set) var asrConfig = ASRConfig()
    private(set) var audioInputConfig = AudioInputConfig.automatic
    private(set) var openAIAPIKey = ""
    private(set) var configLoadFailed = false
    private let stateStore: AppStateStore
    private let configFileURL: URL

    var windowContextEnabled: Bool { generalConfig.windowContextEnabled }
    var onboardingProgress: OnboardingProgress {
        var progress = stateStore.value.onboarding
        progress.hasConfirmedHotkey = progress.hasConfirmedHotkey
            && stateStore.value.confirmedHotkeyFingerprint == hotkeyFingerprint
        return progress
    }
    var omitThinkingParameter: Bool {
        stateStore.value.llmWithoutThinkingParameter == llmFingerprint
    }
    var hasCompletedInitialSetup: Bool { onboardingProgress.hasFinishedPresentation && !configLoadFailed }
    var requiresInitialSetup: Bool { !onboardingProgress.hasFinishedPresentation && !configLoadFailed }
    var canOpenSettings: Bool { !requiresInitialSetup }
    var isLLMConfigured: Bool {
        !llmConfig.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !llmConfig.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var isASRReady: Bool { asrConfig.isReady(localModelsAvailable: Self.localModelsAvailable()) }
    var asrNotReadyReason: String? { asrConfig.notReadyReason(localModelsAvailable: Self.localModelsAvailable()) }

    private struct ConfigFile: Codable {
        var llm = LLMFileConfig()
        var general = GeneralConfig()
        var asr = ASRConfig()
        var audio = AudioInputConfig.automatic

        struct LLMFileConfig: Codable {
            var baseURL = ""
            var model = ""
            var apiKey = ""
        }
    }

    init(configDirectory: URL? = nil) {
        let directory = configDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".memoecho", isDirectory: true)
        configFileURL = directory.appendingPathComponent("config.json")
        stateStore = AppStateStore(directory: directory)
        loadAll()
    }

    func loadAll() {
        stateStore.reload()
        if FileManager.default.fileExists(atPath: configFileURL.path) {
            do {
                let file = try JSONDecoder().decode(ConfigFile.self, from: Data(contentsOf: configFileURL))
                applyConfigFile(file)
                configLoadFailed = false
            } catch {
                // Preserve the file for repair; never silently convert an old or damaged schema.
                applyConfigFile(ConfigFile())
                configLoadFailed = true
            }
        } else {
            applyConfigFile(ConfigFile())
            do {
                // Deleting config is an explicit fresh setup, even if state.json still exists.
                try stateStore.reset()
                try writeConfigFile(buildConfigFile())
            } catch {
                configLoadFailed = true
            }
        }
        if !configLoadFailed { refreshLocalModelStatusFromDisk() }
    }

    func saveLLMConfig(_ config: LLMConfig, apiKey: String) throws {
        let url = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.isEmpty, URL(string: url) == nil { throw ConfigValidationError.invalidURL(url) }
        var file = buildConfigFile()
        file.llm = .init(baseURL: url, model: model, apiKey: key)
        try writeConfigFile(file)
        llmConfig = .init(baseURL: url, model: model)
        openAIAPIKey = key
    }

    func markThinkingParameterUnsupported(for config: LLMConfig, apiKey: String) throws {
        guard config == llmConfig, apiKey == openAIAPIKey, !omitThinkingParameter else { return }
        var state = stateStore.value
        state.llmWithoutThinkingParameter = llmFingerprint
        try stateStore.save(state)
    }

    func saveWindowContextEnabled(_ enabled: Bool) throws {
        var general = generalConfig
        general.windowContextEnabled = enabled
        try saveGeneralConfig(general)
    }

    func saveGeneralConfig(_ config: GeneralConfig, confirmingHotkey: Bool = false) throws {
        let previous = buildConfigFile()
        var file = previous
        file.general = config
        try writeConfigFile(file)
        generalConfig = config
        if confirmingHotkey {
            var progress = onboardingProgress
            progress.hasConfirmedHotkey = true
            do {
                try saveOnboardingProgress(progress)
            } catch {
                // Keep the saved hotkey and the registered hotkey consistent when state cannot be written.
                let stateError = error
                do {
                    try writeConfigFile(previous)
                    generalConfig = previous.general
                } catch {
                    configLoadFailed = true
                    throw error
                }
                throw stateError
            }
        }
    }

    func saveOnboardingProgress(_ progress: OnboardingProgress) throws {
        var state = stateStore.value
        state.onboarding = progress
        state.confirmedHotkeyFingerprint = progress.hasConfirmedHotkey ? hotkeyFingerprint : nil
        try stateStore.save(state)
    }

    func saveASRConfig(_ config: ASRConfig) throws {
        var normalized = config
        invalidateCloudValidationStateIfNeeded(from: asrConfig, to: &normalized)
        var file = buildConfigFile()
        file.asr = normalized
        try writeConfigFile(file)
        asrConfig = normalized
    }

    func saveAudioInputConfig(_ config: AudioInputConfig) throws {
        var file = buildConfigFile()
        file.audio = config
        try writeConfigFile(file)
        audioInputConfig = config
    }

    func updateLocalModelStatus(_ status: LocalModelStatus, error: String? = nil) {
        asrConfig.local.modelStatus = status
        asrConfig.local.lastError = error
    }

    func updateCloudValidationState(for platform: ASRPlatform, status: CloudASRValidationStatus,
                                    error: String? = nil) throws {
        guard platform != .localSenseVoice else { return }
        setCloudRuntimeState(for: platform, status: status, error: error)
        var state = stateStore.value
        // In-flight work and errors stay in memory. A failed/restarted validation invalidates success.
        if status == .verified {
            state.verifiedCloudConfigurations[platform.rawValue] = cloudFingerprint(for: platform)
        } else {
            state.verifiedCloudConfigurations.removeValue(forKey: platform.rawValue)
        }
        if state != stateStore.value { try stateStore.save(state) }
    }

    private func setCloudRuntimeState(for platform: ASRPlatform, status: CloudASRValidationStatus, error: String? = nil) {
        switch platform {
        case .localSenseVoice: break
        case .tencentCloudSentence:
            asrConfig.tencentCloud.sentenceValidationStatus = status
            asrConfig.tencentCloud.sentenceLastValidationError = error
        case .tencentCloudRealtime:
            asrConfig.tencentCloud.validationStatus = status
            asrConfig.tencentCloud.lastValidationError = error
        case .aliyunSentence:
            asrConfig.aliyun.sentenceValidationStatus = status
            asrConfig.aliyun.sentenceLastValidationError = error
        case .aliyunRealtime:
            asrConfig.aliyun.validationStatus = status
            asrConfig.aliyun.lastValidationError = error
        case .aliyunBailianHTTPASR:
            asrConfig.aliyunBailianHTTP.validationStatus = status
            asrConfig.aliyunBailianHTTP.lastValidationError = error
        case .aliyunBailianASR:
            asrConfig.aliyunBailian.validationStatus = status
            asrConfig.aliyunBailian.lastValidationError = error
        case .volcengineRealtime:
            asrConfig.volcengine.validationStatus = status
            asrConfig.volcengine.lastValidationError = error
        case .volcengineBigModelSentence:
            asrConfig.volcengine.bigModelSentenceValidationStatus = status
            asrConfig.volcengine.bigModelSentenceValidationError = error
        case .volcengineSentence:
            asrConfig.volcengine.fileValidationStatus = status
            asrConfig.volcengine.fileLastValidationError = error
        case .volcengineTraditionalSentence:
            asrConfig.volcengineTraditional.sentenceValidationStatus = status
            asrConfig.volcengineTraditional.sentenceLastValidationError = error
        case .volcengineTraditionalRealtime:
            asrConfig.volcengineTraditional.realtimeValidationStatus = status
            asrConfig.volcengineTraditional.realtimeLastValidationError = error
        case .xunfeiIAT:
            asrConfig.xunfei.iatValidationStatus = status
            asrConfig.xunfei.iatLastValidationError = error
        case .xunfeiRealtime:
            asrConfig.xunfei.validationStatus = status
            asrConfig.xunfei.lastValidationError = error
        case .mimoASR:
            asrConfig.mimo.validationStatus = status
            asrConfig.mimo.lastValidationError = error
        case .openAICompatibleASR:
            asrConfig.openAICompatible.validationStatus = status
            asrConfig.openAICompatible.lastValidationError = error
        }
    }

    func refreshLocalModelStatusFromDisk() {
        guard !configLoadFailed, asrConfig.local.modelStatus != .downloading else { return }
        if Self.localModelsAvailable() {
            updateLocalModelStatus(.ready)
        } else if asrConfig.local.modelStatus == .ready {
            updateLocalModelStatus(.notDownloaded)
        }
    }

    private func applyConfigFile(_ file: ConfigFile) {
        llmConfig = .init(baseURL: file.llm.baseURL, model: file.llm.model)
        openAIAPIKey = file.llm.apiKey
        generalConfig = file.general
        asrConfig = file.asr
        audioInputConfig = file.audio
        for platform in ASRPlatform.allCases where platform != .localSenseVoice {
            if stateStore.value.verifiedCloudConfigurations[platform.rawValue] == cloudFingerprint(for: platform) {
                setCloudRuntimeState(for: platform, status: .verified)
            }
        }
    }

    private func buildConfigFile() -> ConfigFile {
        ConfigFile(llm: .init(baseURL: llmConfig.baseURL, model: llmConfig.model, apiKey: openAIAPIKey),
                   general: generalConfig, asr: asrConfig, audio: audioInputConfig)
    }

    private var llmFingerprint: String {
        let identity = [llmConfig.baseURL, llmConfig.model, openAIAPIKey]
        return AppStateStore.fingerprint(String(decoding: try! JSONEncoder().encode(identity), as: UTF8.self))
    }
    private var hotkeyFingerprint: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return AppStateStore.fingerprint(String(decoding: try! encoder.encode(generalConfig.hotkey), as: UTF8.self))
    }
    private func cloudFingerprint(for platform: ASRPlatform) -> String {
        AppStateStore.fingerprint(CloudASRValidationInput(platform: platform, asrConfig: asrConfig).fingerprint)
    }

    private func invalidateCloudValidationStateIfNeeded(from oldConfig: ASRConfig, to newConfig: inout ASRConfig) {
        if CloudASRValidationInput(platform: .tencentCloudSentence, asrConfig: oldConfig).fingerprint
            != CloudASRValidationInput(platform: .tencentCloudSentence, asrConfig: newConfig).fingerprint {
            newConfig.tencentCloud.sentenceValidationStatus = .unvalidated
            newConfig.tencentCloud.sentenceLastValidationError = nil
        }
        if CloudASRValidationInput(platform: .aliyunSentence, asrConfig: oldConfig).fingerprint
            != CloudASRValidationInput(platform: .aliyunSentence, asrConfig: newConfig).fingerprint {
            newConfig.aliyun.sentenceValidationStatus = .unvalidated
            newConfig.aliyun.sentenceLastValidationError = nil
        }
        if CloudASRValidationInput(platform: .xunfeiIAT, asrConfig: oldConfig).fingerprint
            != CloudASRValidationInput(platform: .xunfeiIAT, asrConfig: newConfig).fingerprint {
            newConfig.xunfei.iatValidationStatus = .unvalidated
            newConfig.xunfei.iatLastValidationError = nil
        }
        if oldConfig.tencentCloud.appID != newConfig.tencentCloud.appID
            || oldConfig.tencentCloud.secretId != newConfig.tencentCloud.secretId
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

        if oldConfig.aliyunBailianHTTP.connectionIdentity != newConfig.aliyunBailianHTTP.connectionIdentity {
            newConfig.aliyunBailianHTTP.validationStatus = .unvalidated
            newConfig.aliyunBailianHTTP.lastValidationError = nil
        }
        if oldConfig.aliyunBailian.connectionIdentity != newConfig.aliyunBailian.connectionIdentity {
            newConfig.aliyunBailian.validationStatus = .unvalidated
            newConfig.aliyunBailian.lastValidationError = nil
        }

        if oldConfig.volcengine.apiKey != newConfig.volcengine.apiKey {
            newConfig.volcengine.fileValidationStatus = .unvalidated
            newConfig.volcengine.fileLastValidationError = nil
        }
        if CloudASRValidationInput(platform: .volcengineBigModelSentence, asrConfig: oldConfig).fingerprint
            != CloudASRValidationInput(platform: .volcengineBigModelSentence, asrConfig: newConfig).fingerprint {
            newConfig.volcengine.bigModelSentenceValidationStatus = .unvalidated
            newConfig.volcengine.bigModelSentenceValidationError = nil
        }
        if oldConfig.volcengineTraditional.sentenceConnectionIdentity != newConfig.volcengineTraditional.sentenceConnectionIdentity {
            newConfig.volcengineTraditional.sentenceValidationStatus = .unvalidated
            newConfig.volcengineTraditional.sentenceLastValidationError = nil
        }
        if oldConfig.volcengineTraditional.realtimeConnectionIdentity != newConfig.volcengineTraditional.realtimeConnectionIdentity {
            newConfig.volcengineTraditional.realtimeValidationStatus = .unvalidated
            newConfig.volcengineTraditional.realtimeLastValidationError = nil
        }
        if oldConfig.volcengine.apiKey != newConfig.volcengine.apiKey
            || oldConfig.volcengine.modelVersion != newConfig.volcengine.modelVersion {
            newConfig.volcengine.validationStatus = .unvalidated
            newConfig.volcengine.lastValidationError = nil
        }

        if oldConfig.xunfei.realtimeAPIKey != newConfig.xunfei.realtimeAPIKey
            || oldConfig.xunfei.appID != newConfig.xunfei.appID {
            newConfig.xunfei.validationStatus = .unvalidated
            newConfig.xunfei.lastValidationError = nil
        }

        if oldConfig.mimo.connectionIdentity != newConfig.mimo.connectionIdentity {
            newConfig.mimo.validationStatus = .unvalidated
            newConfig.mimo.lastValidationError = nil
        }
        if oldConfig.openAICompatible.connectionIdentity != newConfig.openAICompatible.connectionIdentity {
            newConfig.openAICompatible.validationStatus = .unvalidated
            newConfig.openAICompatible.lastValidationError = nil
        }
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

    private func writeConfigFile(_ file: ConfigFile) throws {
        try PrivateJSONFile.write(file, to: configFileURL)
        configLoadFailed = false
    }
}
