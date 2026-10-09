import Foundation

@MainActor
@Observable
final class CloudASRValidationService {
    typealias ValidatorFactory = @MainActor @Sendable (CloudASRValidationInput) throws -> any CloudASRValidating

    private let validatorFactory: ValidatorFactory
    private let configStore: ConfigStore

    private var validationTask: Task<Void, Never>?
    private var activeFingerprint: String?
    private var lastCompletedFingerprint: String?
    private var activeRequestID: UUID?

    private(set) var status: CloudASRValidationDisplayStatus = .incomplete
    private(set) var lastErrorMessage: String?
    private(set) var isTransientRuntimeFailure = false

    init(
        configStore: ConfigStore,
        validatorFactory: @escaping ValidatorFactory = CloudASRValidationService.defaultValidatorFactory
    ) {
        self.configStore = configStore
        self.validatorFactory = validatorFactory
    }

    func syncFromConfig(for input: CloudASRValidationInput) {
        if lastCompletedFingerprint != input.fingerprint { isTransientRuntimeFailure = false }
        guard input.isCloudPlatform else {
            cancelOngoingValidation()
            status = .incomplete
            lastErrorMessage = nil
            activeFingerprint = nil
            lastCompletedFingerprint = nil
            return
        }

        let cloudState = cloudState(for: input)
        if !cloudState.isComplete {
            cancelOngoingValidation()
            status = .incomplete
            lastErrorMessage = nil
            activeFingerprint = nil
            lastCompletedFingerprint = nil
            return
        }

        // 切换页面时保留同一配置正在进行的验证，不能把 .validating 当作成功。
        if activeFingerprint == input.fingerprint { return }
        if activeFingerprint == nil, lastCompletedFingerprint == input.fingerprint { return }
        cancelOngoingValidation()

        switch cloudState.validationStatus {
        case .unvalidated, .validating:
            status = .incomplete
            lastErrorMessage = nil
            lastCompletedFingerprint = nil
        case .verified:
            status = .ready
            lastErrorMessage = nil
            lastCompletedFingerprint = input.fingerprint
        case .failed:
            status = .failed
            lastErrorMessage = cloudState.lastValidationError
            lastCompletedFingerprint = input.fingerprint
        }
    }

    func status(for input: CloudASRValidationInput) -> CloudASRValidationDisplayStatus {
        guard input.isCloudPlatform, input.isComplete, matchesSavedConfiguration(input) else { return .incomplete }
        if activeFingerprint == input.fingerprint { return .checking }
        if activeFingerprint == nil, lastCompletedFingerprint == input.fingerprint { return status }
        switch cloudState(for: input).validationStatus {
        case .verified: return .ready
        case .failed: return .failed
        case .unvalidated, .validating: return .incomplete
        }
    }

    func invalidateCurrentValidation(isTransient: Bool = false) {
        isTransientRuntimeFailure = isTransient
        let input = CloudASRValidationInput(platform: configStore.asrConfig.selectedPlatform, asrConfig: configStore.asrConfig)
        guard input.isCloudPlatform else { return }
        cancelOngoingValidation()
        lastCompletedFingerprint = input.fingerprint
        status = .failed
        lastErrorMessage = "云端识别暂不可用，请检查配置并重试"
        try? configStore.updateCloudValidationState(for: input.platform, status: .failed, error: lastErrorMessage)
    }

    func validate(_ input: CloudASRValidationInput, force: Bool = false) {
        guard input.isCloudPlatform else {
            syncFromConfig(for: input)
            return
        }

        guard input.isComplete else {
            cancelOngoingValidation()
            status = .incomplete
            lastErrorMessage = nil
            activeFingerprint = nil
            lastCompletedFingerprint = nil
            return
        }

        let fingerprint = input.fingerprint
        if activeFingerprint == fingerprint { return }
        if !force {
            if lastCompletedFingerprint == fingerprint, status != .checking {
                return
            }
        }

        validationTask?.cancel()
        let requestID = UUID()
        activeRequestID = requestID
        activeFingerprint = fingerprint
        isTransientRuntimeFailure = false
        status = .checking
        lastErrorMessage = nil

        let validatorFactory = self.validatorFactory
        let configStore = self.configStore

        validationTask = Task { [weak self] in
            do {
                try await MainActor.run {
                    guard let self, self.activeRequestID == requestID, self.matchesSavedConfiguration(input) else {
                        throw CancellationError()
                    }
                    try configStore.updateCloudValidationState(for: input.platform, status: .validating)
                }
                let validator = try validatorFactory(input)
                try await validator.validateCredentials()

                guard !Task.isCancelled else { return }
                try await MainActor.run {
                    guard let self, self.activeRequestID == requestID else { return }
                    guard self.matchesSavedConfiguration(input) else {
                        self.cancelOngoingValidation()
                        self.status = .incomplete
                        return
                    }
                    try configStore.updateCloudValidationState(for: input.platform, status: .verified)
                    self.activeFingerprint = nil
                    self.activeRequestID = nil
                    self.lastCompletedFingerprint = fingerprint
                    self.validationTask = nil
                    self.status = .ready
                    self.lastErrorMessage = nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                let errorMessage = Self.errorMessage(from: error)
                await MainActor.run {
                    guard let self, self.activeRequestID == requestID else { return }
                    guard self.matchesSavedConfiguration(input) else {
                        self.cancelOngoingValidation()
                        self.status = .incomplete
                        return
                    }
                    try? configStore.updateCloudValidationState(
                        for: input.platform,
                        status: .failed,
                        error: errorMessage
                    )
                    self.activeFingerprint = nil
                    self.activeRequestID = nil
                    self.lastCompletedFingerprint = fingerprint
                    self.validationTask = nil
                    self.status = .failed
                    self.lastErrorMessage = errorMessage
                }
            }
        }
    }

    private func cancelOngoingValidation() {
        validationTask?.cancel()
        validationTask = nil
        activeFingerprint = nil
        activeRequestID = nil
    }

    private func matchesSavedConfiguration(_ input: CloudASRValidationInput) -> Bool {
        CloudASRValidationInput(platform: input.platform, asrConfig: configStore.asrConfig).fingerprint == input.fingerprint
    }

    private func cloudState(for input: CloudASRValidationInput) -> any CloudASRConfigState {
        switch input.platform {
        case .localSenseVoice:
            return input.asrConfig.tencentCloud
        case .tencentCloudSentence:
            return input.asrConfig.tencentCloud.sentenceState
        case .tencentCloudRealtime:
            return input.asrConfig.tencentCloud
        case .aliyunSentence:
            return input.asrConfig.aliyun.sentenceState
        case .aliyunRealtime:
            return input.asrConfig.aliyun
        case .aliyunBailianHTTPASR:
            return input.asrConfig.aliyunBailianHTTP
        case .aliyunBailianASR:
            return input.asrConfig.aliyunBailian
        case .volcengineRealtime:
            return input.asrConfig.volcengine
        case .volcengineBigModelSentence:
            return input.asrConfig.volcengine.bigModelSentenceState
        case .volcengineSentence:
            return input.asrConfig.volcengine.fileState
        case .volcengineTraditionalSentence:
            return input.asrConfig.volcengineTraditional.sentenceState
        case .volcengineTraditionalRealtime:
            return input.asrConfig.volcengineTraditional.realtimeState
        case .xunfeiIAT:
            return input.asrConfig.xunfei.iatState
        case .xunfeiRealtime:
            return input.asrConfig.xunfei
        case .mimoASR:
            return input.asrConfig.mimo
        case .openAICompatibleASR:
            return input.asrConfig.openAICompatible
        }
    }

    private static func defaultValidatorFactory(input: CloudASRValidationInput) throws -> any CloudASRValidating {
        switch input.platform {
        case .localSenseVoice:
            throw MemoEchoError.asrPlatformNotReady(detail: "本地平台不需要云端验证")
        case .tencentCloudRealtime, .aliyunRealtime, .aliyunBailianASR, .volcengineRealtime, .volcengineBigModelSentence, .volcengineTraditionalSentence, .volcengineTraditionalRealtime, .xunfeiIAT, .xunfeiRealtime:
            var config = input.asrConfig
            config.selectedPlatform = input.platform
            return RealtimeASRValidator(config: config)
        case .tencentCloudSentence, .aliyunSentence, .aliyunBailianHTTPASR, .volcengineSentence:
            var config = input.asrConfig
            config.selectedPlatform = input.platform
            guard let provider = ASRProviderFactory.makeSentenceProvider(for: config) else {
                throw MemoEchoError.cloudASRConfigurationIncomplete
            }
            return provider
        case .mimoASR:
            return MiMoASRProvider(config: input.asrConfig.mimo)
        case .openAICompatibleASR:
            return OpenAICompatibleASRProvider(config: input.asrConfig.openAICompatible)
        }
    }

    private static func errorMessage(from error: Error) -> String {
        if let memoechoError = error as? MemoEchoError {
            return memoechoError.userMessage
        }
        if let realtimeError = error as? RealtimeASRError { return realtimeError.localizedDescription }
        if let configError = error as? ConfigValidationError {
            return configError.errorDescription ?? error.localizedDescription
        }
        return "云端识别验证失败，请检查配置或网络后重试"
    }
}
