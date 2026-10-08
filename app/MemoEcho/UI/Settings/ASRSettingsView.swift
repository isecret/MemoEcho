import SwiftUI

enum ASRCloudStatusPresentation: Equatable {
    case ready
    case checking
    case notReady
    case failed

    static func initial(
        isComplete: Bool,
        persistedState: CloudASRValidationStatus,
        errorMessage: String?
    ) -> Self {
        guard isComplete else { return .notReady }

        switch persistedState {
        case .verified:
            return .ready
        case .failed:
            return normalizedErrorMessage(errorMessage) == nil ? .notReady : .failed
        case .unvalidated, .validating:
            return .notReady
        }
    }

    static func currentSession(
        isComplete: Bool,
        serviceStatus: CloudASRValidationDisplayStatus,
        errorMessage: String?
    ) -> Self {
        guard isComplete else { return .notReady }

        switch serviceStatus {
        case .incomplete:
            return .notReady
        case .ready:
            return .ready
        case .checking:
            return .checking
        case .failed:
            return normalizedErrorMessage(errorMessage) == nil ? .notReady : .failed
        }
    }

    var text: String {
        switch self {
        case .ready:
            return "已就绪"
        case .checking:
            return "验证中…"
        case .notReady:
            return "未就绪"
        case .failed:
            return "验证失败"
        }
    }

    var systemImage: String {
        switch self {
        case .ready:
            return "checkmark.circle.fill"
        case .checking:
            return "ellipsis.circle"
        case .notReady:
            return "exclamationmark.triangle.fill"
        case .failed:
            return "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .ready:
            return .green
        case .checking:
            return .secondary
        case .notReady:
            return .orange
        case .failed:
            return .red
        }
    }

    var showsErrorMessage: Bool {
        self == .failed
    }

    private static func normalizedErrorMessage(_ errorMessage: String?) -> String? {
        guard let errorMessage else { return nil }
        let trimmed = errorMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct ASRSettingsView: View {
    let configStore: ConfigStore
    let downloadManager: ModelDownloadManager
    let validationService: CloudASRValidationService
    var microphoneControls: MicrophoneLevelView? = nil

    @State private var selectedPlatform: ASRPlatform = .localSenseVoice

    @State private var tencentAppID = ""
    @State private var tencentSecretId: String = ""
    @State private var tencentSecretKey: String = ""

    @State private var aliyunAccessKeyId: String = ""
    @State private var aliyunAccessKeySecret: String = ""
    @State private var aliyunAppKey: String = ""

    @State private var bailianHTTPBaseURL = ""
    @State private var bailianHTTPAPIKey = ""
    @State private var bailianHTTPModel = AliyunBailianHTTPASRConfig.defaultModel
    @State private var bailianBaseURL = ""
    @State private var bailianAPIKey = ""
    @State private var bailianModel = AliyunBailianASRConfig.defaultModel

    @State private var volcengineAPIKey: String = ""
    @State private var volcengineModelVersion: VolcengineASRModelVersion = .v2
    @State private var volcengineTraditionalAppID = ""
    @State private var volcengineTraditionalToken = ""

    @State private var xunfeiAppID: String = ""
    @State private var xunfeiAPIKey: String = ""
    @State private var xunfeiIATAPIKey = ""
    @State private var xunfeiIATAPISecret = ""


    @State private var mimoBaseURL = MiMoASRConfig.defaultBaseURL
    @State private var mimoKey = ""
    @State private var mimoModel = MiMoASRConfig.defaultModel

    @State private var openAIFormat: OpenAIASRFormat = .audioTranscriptions
    @State private var openAIBaseURL = ""
    @State private var openAIKey = ""
    @State private var openAIModel = ""

    @State private var isLoaded = false
    @State private var saveTask: Task<Void, Never>?
    @State private var draftTracker = SettingsDraftTracker()
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let microphoneControls {
                SettingsFormGroup(title: "音频输入") {
                    microphoneControls.padding(.vertical, SettingsFormLayout.groupedSectionVerticalPadding)
                }
            }
            SettingsFormGroup(title: "语音识别") {
                SettingsPaneSection {
                    SettingsFormRow(title: "语音引擎") {
                        HStack(spacing: 4) {
                            Picker("语音引擎", selection: $selectedPlatform) {
                                ForEach(ASRVendorGroup.allCases) { group in
                                    Section(group.rawValue) {
                                        ForEach(group.platforms, id: \.self) { platform in
                                            Text(platform.pickerTitle).tag(platform)
                                        }
                                    }
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .fixedSize()

                            Link(destination: selectedPlatform.documentationURL) {
                                Image(systemName: "arrow.up.forward.square")
                                    .font(.system(size: 14, weight: .regular))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .accessibilityLabel("查看 \(selectedPlatform.displayName) 的使用文档")
                            .help("查看 \(selectedPlatform.displayName) 的使用文档")

                            Spacer(minLength: 0)
                        }
                        .frame(width: SettingsFormLayout.controlWidth, alignment: .leading)
                    }

                    switch selectedPlatform {
                    case .localSenseVoice:
                        localSenseVoicePanel
                    case .tencentCloudSentence, .tencentCloudRealtime:
                        tencentCloudPanel
                    case .aliyunSentence, .aliyunRealtime:
                        aliyunPanel
                    case .aliyunBailianHTTPASR:
                        aliyunBailianHTTPPanel
                    case .aliyunBailianASR:
                        aliyunBailianPanel
                    case .volcengineRealtime, .volcengineBigModelSentence, .volcengineSentence:
                        volcenginePanel
                    case .volcengineTraditionalSentence, .volcengineTraditionalRealtime:
                        volcengineTraditionalPanel
                    case .xunfeiIAT, .xunfeiRealtime:
                        xunfeiPanel
                    case .mimoASR:
                        mimoPanel
                    case .openAICompatibleASR:
                        openAICompatiblePanel
                    }
                } footer: {
                    Text(selectedPlatform.cloudConfigSummary)
                    if selectedPlatform == .aliyunBailianASR,
                       !bailianBaseURL.isEmpty, currentDraftConfig().aliyunBailian.requestURL == nil {
                        Text("地址格式不正确，请检查后再试。")
                            .foregroundStyle(.red)
                    }
                    if selectedPlatform == .openAICompatibleASR {
                        if currentDraftConfig().openAICompatible.requestURL?.scheme?.lowercased() == "http" {
                            Text("HTTP 未加密，仅用于可信的本机或局域网服务。")
                        }
                        if !openAIBaseURL.isEmpty, currentDraftConfig().openAICompatible.requestURL == nil {
                            Text("地址或接口格式不匹配，请检查后再试。")
                                .foregroundStyle(.red)
                        }
                    }
                    if let saveError { Text(saveError).foregroundStyle(.red) }
                }
            }
        }
        .onAppear {
            loadDraft()
            isLoaded = true
            validationService.validate(currentValidationInput())
        }
        .onDisappear { flushPendingSave() }
        .onChange(of: selectedPlatform) {
            savePlatform()
            validationService.syncFromConfig(for: currentValidationInput())
        }
        .onChange(of: cloudDraftFields) { debouncedSaveCloudConfig() }
    }

    // Observe editable values only, so validation-state updates never schedule a save.
    private var cloudDraftFields: [String] {
        [tencentAppID, tencentSecretId, tencentSecretKey, aliyunAccessKeyId, aliyunAccessKeySecret, aliyunAppKey,
         bailianHTTPBaseURL, bailianHTTPAPIKey, bailianHTTPModel,
         bailianBaseURL, bailianAPIKey, bailianModel, volcengineAPIKey, volcengineModelVersion.rawValue,
         volcengineTraditionalAppID, volcengineTraditionalToken,
         xunfeiAppID, xunfeiAPIKey, xunfeiIATAPIKey, xunfeiIATAPISecret, mimoBaseURL, mimoKey, mimoModel,
         openAIFormat.rawValue, openAIBaseURL, openAIKey, openAIModel]
    }

    // MARK: - Panels

    @ViewBuilder
    private var localSenseVoicePanel: some View {
        let status = configStore.asrConfig.local.modelStatus
        let error = localModelError(for: status)

        SettingsFormRow(title: "引擎状态") {
            VStack(alignment: .trailing, spacing: 4) {
                localModelStatusContent(for: status)

                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .frame(width: SettingsFormLayout.controlWidth, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private var tencentCloudPanel: some View {
        if selectedPlatform == .tencentCloudRealtime {
            cloudField(title: "AppID", text: $tencentAppID)
        }
        cloudField(title: "SecretId", text: $tencentSecretId)
        cloudSecureField(title: "SecretKey", text: $tencentSecretKey)
        cloudStatusRow(for: selectedPlatform)
    }

    @ViewBuilder
    private var aliyunPanel: some View {
        cloudField(title: "AccessKey ID", text: $aliyunAccessKeyId)
        cloudSecureField(title: "AccessKey Secret", text: $aliyunAccessKeySecret)
        cloudField(title: "AppKey", text: $aliyunAppKey)
        cloudStatusRow(for: selectedPlatform)
    }

    @ViewBuilder
    private var aliyunBailianHTTPPanel: some View {
        cloudField(title: "Base URL", text: $bailianHTTPBaseURL)
        cloudSecureField(title: "API Key", text: $bailianHTTPAPIKey)
        cloudField(title: "Model", text: $bailianHTTPModel)
        cloudStatusRow(for: .aliyunBailianHTTPASR)
    }

    @ViewBuilder
    private var aliyunBailianPanel: some View {
        cloudField(title: "Base URL", text: $bailianBaseURL)
        cloudSecureField(title: "API Key", text: $bailianAPIKey)
        cloudField(title: "Model", text: $bailianModel)
        cloudStatusRow(for: .aliyunBailianASR)
    }

    @ViewBuilder
    private var volcenginePanel: some View {
        cloudSecureField(title: "API Key", text: $volcengineAPIKey)
        if selectedPlatform != .volcengineSentence {
            SettingsFormRow(title: "模型版本") {
                Picker("模型版本", selection: $volcengineModelVersion) {
                    ForEach(VolcengineASRModelVersion.allCases, id: \.self) { version in
                        Text(version.rawValue).tag(version)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: SettingsFormLayout.controlWidth, alignment: .leading)
            }
        }
        cloudStatusRow(for: selectedPlatform)
    }

    @ViewBuilder
    private var volcengineTraditionalPanel: some View {
        cloudField(title: "AppID", text: $volcengineTraditionalAppID)
        cloudSecureField(title: "Access Token", text: $volcengineTraditionalToken)
        cloudStatusRow(for: selectedPlatform)
    }

    @ViewBuilder
    private var xunfeiPanel: some View {
        cloudField(title: "AppID", text: $xunfeiAppID)
        if selectedPlatform == .xunfeiIAT {
            cloudSecureField(title: "IAT API Key", text: $xunfeiIATAPIKey)
            cloudSecureField(title: "API Secret", text: $xunfeiIATAPISecret)
        } else {
            cloudSecureField(title: "RTASR API Key", text: $xunfeiAPIKey)
        }
        cloudStatusRow(for: selectedPlatform)
    }

    @ViewBuilder
    private var openAICompatiblePanel: some View {
        if openAIFormat == .chatCompletions {
            Text("Chat 音频识别已移至小米 MiMo，请手动配置。")
                .foregroundStyle(.red)
            Button("改用 Audio Transcriptions") { openAIFormat = .audioTranscriptions }
        }
        cloudField(title: "Base URL", text: $openAIBaseURL)
        cloudSecureField(title: "API Key（可选）", text: $openAIKey)
        cloudField(title: "Model", text: $openAIModel)
        cloudStatusRow(for: .openAICompatibleASR)
    }

    @ViewBuilder
    private var mimoPanel: some View {
        cloudField(title: "Base URL", text: $mimoBaseURL)
        cloudSecureField(title: "API Key", text: $mimoKey)
        cloudField(title: "Model", text: $mimoModel)
        cloudStatusRow(for: .mimoASR)
    }

    // MARK: - Shared Rows

    private func cloudField(title: String, text: Binding<String>) -> some View {
        SettingsFormRow(title: title) {
            SettingsTextInputField(text: text)
        }
    }

    private func cloudSecureField(title: String, text: Binding<String>) -> some View {
        SettingsFormRow(title: title) {
            SettingsSecureInputField(text: text)
        }
    }

    private func cloudStatusRow(for platform: ASRPlatform) -> some View {
        SettingsFormRow(title: "引擎状态") {
            VStack(alignment: .leading, spacing: 4) {
                let presentation = cloudStatusPresentation(for: platform)
                statusIndicator(
                    text: presentation.text,
                    systemImage: presentation.systemImage,
                    color: presentation.color
                )

                if presentation.showsErrorMessage,
                   let errorMessage = cloudValidationErrorMessage(for: platform) {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .frame(width: SettingsFormLayout.controlWidth, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Local Model

    @ViewBuilder
    private func localModelStatusContent(for status: LocalModelStatus) -> some View {
        switch status {
        case .notDownloaded:
            HStack(spacing: 10) {
                statusIndicator(
                    text: "未就绪",
                    systemImage: "exclamationmark.triangle.fill",
                    color: .orange
                )

                Button("下载") {
                    downloadManager.startDownload()
                }
                .fixedSize()
            }
            .accessibilityLabel("下载模型")
            .accessibilityValue("未下载")
            .help("下载模型")
        case .downloading:
            HStack(spacing: 10) {
                ProgressView(value: downloadManager.progress)
                    .frame(width: 180)

                Button {
                    downloadManager.cancelDownload()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("取消下载")
                .accessibilityValue("下载中")
                .help("取消下载")
            }
        case .ready:
            statusIndicator(
                text: "已就绪",
                systemImage: "checkmark.circle.fill",
                color: .green
            )
                .accessibilityLabel("模型已就绪")
                .accessibilityValue("已就绪")
                .help("模型已就绪")
        case .failed:
            Button("重试下载") {
                downloadManager.startDownload()
            }
            .fixedSize()
            .accessibilityLabel("重试下载")
            .accessibilityValue("下载失败")
            .help("重试下载")
        }
    }

    private func localModelError(for status: LocalModelStatus) -> String? {
        guard status == .failed else { return nil }
        return configStore.asrConfig.local.lastError ?? downloadManager.lastError
    }

    // MARK: - Persistence

    private func loadDraft() {
        configStore.refreshLocalModelStatusFromDisk()
        selectedPlatform = configStore.asrConfig.selectedPlatform

        tencentAppID = configStore.asrConfig.tencentCloud.appID
        tencentSecretId = configStore.asrConfig.tencentCloud.secretId
        tencentSecretKey = configStore.asrConfig.tencentCloud.secretKey

        aliyunAccessKeyId = configStore.asrConfig.aliyun.accessKeyId
        aliyunAccessKeySecret = configStore.asrConfig.aliyun.accessKeySecret
        aliyunAppKey = configStore.asrConfig.aliyun.appKey

        bailianHTTPBaseURL = configStore.asrConfig.aliyunBailianHTTP.baseURL
        bailianHTTPAPIKey = configStore.asrConfig.aliyunBailianHTTP.apiKey
        bailianHTTPModel = configStore.asrConfig.aliyunBailianHTTP.model
        bailianBaseURL = configStore.asrConfig.aliyunBailian.baseURL
        bailianAPIKey = configStore.asrConfig.aliyunBailian.apiKey
        bailianModel = configStore.asrConfig.aliyunBailian.model

        volcengineAPIKey = configStore.asrConfig.volcengine.apiKey
        volcengineModelVersion = configStore.asrConfig.volcengine.modelVersion
        volcengineTraditionalAppID = configStore.asrConfig.volcengineTraditional.appID
        volcengineTraditionalToken = configStore.asrConfig.volcengineTraditional.accessToken

        xunfeiAppID = configStore.asrConfig.xunfei.appID
        xunfeiAPIKey = configStore.asrConfig.xunfei.realtimeAPIKey
        xunfeiIATAPIKey = configStore.asrConfig.xunfei.apiKey
        xunfeiIATAPISecret = configStore.asrConfig.xunfei.apiSecret

        mimoBaseURL = configStore.asrConfig.mimo.baseURL
        mimoKey = configStore.asrConfig.mimo.apiKey
        mimoModel = configStore.asrConfig.mimo.model
        openAIFormat = configStore.asrConfig.openAICompatible.apiFormat
        openAIBaseURL = configStore.asrConfig.openAICompatible.baseURL
        openAIKey = configStore.asrConfig.openAICompatible.apiKey
        openAIModel = configStore.asrConfig.openAICompatible.model

        draftTracker.loaded(currentValidationInput().fingerprint)
        validationService.syncFromConfig(for: currentValidationInput())
    }

    private func currentDraftConfig() -> ASRConfig {
        var config = configStore.asrConfig
        config.selectedPlatform = selectedPlatform
        config.tencentCloud.appID = tencentAppID.trimmingCharacters(in: .whitespacesAndNewlines)
        config.tencentCloud.secretId = tencentSecretId.trimmingCharacters(in: .whitespacesAndNewlines)
        config.tencentCloud.secretKey = tencentSecretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        config.aliyun.accessKeyId = aliyunAccessKeyId.trimmingCharacters(in: .whitespacesAndNewlines)
        config.aliyun.accessKeySecret = aliyunAccessKeySecret.trimmingCharacters(in: .whitespacesAndNewlines)
        config.aliyun.appKey = aliyunAppKey.trimmingCharacters(in: .whitespacesAndNewlines)
        config.aliyunBailianHTTP.baseURL = bailianHTTPBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        config.aliyunBailianHTTP.apiKey = bailianHTTPAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        config.aliyunBailianHTTP.model = bailianHTTPModel.trimmingCharacters(in: .whitespacesAndNewlines)
        config.aliyunBailian.baseURL = bailianBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        config.aliyunBailian.apiKey = bailianAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        config.aliyunBailian.model = bailianModel.trimmingCharacters(in: .whitespacesAndNewlines)
        config.volcengine.apiKey = volcengineAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        config.volcengine.modelVersion = volcengineModelVersion
        config.volcengineTraditional.appID = volcengineTraditionalAppID.trimmingCharacters(in: .whitespacesAndNewlines)
        config.volcengineTraditional.accessToken = volcengineTraditionalToken.trimmingCharacters(in: .whitespacesAndNewlines)
        config.xunfei.appID = xunfeiAppID.trimmingCharacters(in: .whitespacesAndNewlines)
        config.xunfei.realtimeAPIKey = xunfeiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        config.xunfei.apiKey = xunfeiIATAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        config.xunfei.apiSecret = xunfeiIATAPISecret.trimmingCharacters(in: .whitespacesAndNewlines)
        config.mimo.baseURL = mimoBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        config.mimo.apiKey = mimoKey.trimmingCharacters(in: .whitespacesAndNewlines)
        config.mimo.model = mimoModel.trimmingCharacters(in: .whitespacesAndNewlines)
        config.openAICompatible.apiFormat = openAIFormat
        config.openAICompatible.baseURL = openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        config.openAICompatible.apiKey = openAIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        config.openAICompatible.model = openAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return config
    }

    private func savePlatform() {
        guard isLoaded else { return }
        guard draftTracker.changed(to: currentValidationInput().fingerprint) else { return }
        saveCloudConfig()
    }

    private func debouncedSaveCloudConfig() {
        guard isLoaded else { return }
        saveTask?.cancel()
        guard draftTracker.changed(to: currentValidationInput().fingerprint) else { return }
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            saveCloudConfig()
        }
    }

    private func flushPendingSave() {
        saveTask?.cancel()
        saveTask = nil
        if isLoaded, draftTracker.hasPendingChanges { saveCloudConfig() }
    }

    private func saveCloudConfig() {
        let draftConfig = currentDraftConfig()
        do {
            try configStore.saveASRConfig(draftConfig)
            draftTracker.loaded(currentValidationInput().fingerprint)
            saveError = nil
        } catch {
            saveError = "配置未保存，请检查配置目录权限。"
            return
        }
        validationService.syncFromConfig(for: currentValidationInput())

        let input = currentValidationInput()
        if input.isCloudPlatform {
            validationService.validate(input)
        }
    }

    @ViewBuilder
    private func statusIndicator(text: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(text)
        }
        .foregroundStyle(color)
    }

    private func currentValidationInput() -> CloudASRValidationInput {
        CloudASRValidationInput(
            platform: selectedPlatform,
            asrConfig: currentDraftConfig()
        )
    }

    private func cloudStatusPresentation(for platform: ASRPlatform) -> ASRCloudStatusPresentation {
        let draftConfig = currentDraftConfig()
        let input = CloudASRValidationInput(platform: platform, asrConfig: draftConfig)
        let errorMessage = cloudValidationErrorMessage(for: platform)

        return .currentSession(
            isComplete: input.isComplete,
            serviceStatus: validationService.status(for: input),
            errorMessage: errorMessage
        )
    }

    private func cloudValidationErrorMessage(for platform: ASRPlatform) -> String? {
        let draftConfig = currentDraftConfig()
        let persistedError = persistedCloudValidationError(for: platform, in: draftConfig)

        guard selectedPlatform == platform,
              let serviceError = validationService.lastErrorMessage,
              !serviceError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return persistedError
        }

        return serviceError
    }

    private func persistedCloudValidationError(for platform: ASRPlatform, in config: ASRConfig) -> String? {
        switch platform {
        case .localSenseVoice:
            return nil
        case .tencentCloudSentence:
            return config.tencentCloud.sentenceLastValidationError
        case .tencentCloudRealtime:
            return config.tencentCloud.lastValidationError
        case .aliyunSentence:
            return config.aliyun.sentenceLastValidationError
        case .aliyunRealtime:
            return config.aliyun.lastValidationError
        case .aliyunBailianHTTPASR:
            return config.aliyunBailianHTTP.lastValidationError
        case .aliyunBailianASR:
            return config.aliyunBailian.lastValidationError
        case .volcengineRealtime:
            return config.volcengine.lastValidationError
        case .volcengineBigModelSentence:
            return config.volcengine.bigModelSentenceValidationError
        case .volcengineSentence:
            return config.volcengine.fileLastValidationError
        case .volcengineTraditionalSentence:
            return config.volcengineTraditional.sentenceLastValidationError
        case .volcengineTraditionalRealtime:
            return config.volcengineTraditional.realtimeLastValidationError
        case .xunfeiIAT:
            return config.xunfei.iatLastValidationError
        case .xunfeiRealtime:
            return config.xunfei.lastValidationError
        case .mimoASR:
            return config.mimo.lastValidationError
        case .openAICompatibleASR:
            return config.openAICompatible.lastValidationError
        }
    }
}
