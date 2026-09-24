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

    init(
        configStore: ConfigStore,
        validatorFactory: @escaping ValidatorFactory = CloudASRValidationService.defaultValidatorFactory
    ) {
        self.configStore = configStore
        self.validatorFactory = validatorFactory
    }

    func syncFromConfig(for input: CloudASRValidationInput) {
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

    func invalidateCurrentValidation() {
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
                do {
                    try await validator.validateCredentials()
                } catch let error as MemoEchoError where error == .cloudASREmptyResponse {
                    // 鉴权成功但测试音频没有识别结果，仍视为配置验证通过。
                }

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
            return input.asrConfig.tencentCloud
        case .aliyunSentence:
            return input.asrConfig.aliyun
        case .volcengineSentence:
            return input.asrConfig.volcengine
        case .xunfeiSentence:
            return input.asrConfig.xunfei
        case .xiaomiMiMoASR:
            return input.asrConfig.xiaomiMiMo
        case .xiaomiMiMoTokenPlanASR:
            return input.asrConfig.xiaomiMiMoTokenPlan
        }
    }

    private static func defaultValidatorFactory(input: CloudASRValidationInput) throws -> any CloudASRValidating {
        switch input.platform {
        case .localSenseVoice:
            throw MemoEchoError.asrPlatformNotReady(detail: "本地平台不需要云端验证")
        case .tencentCloudSentence:
            return TencentSentenceASRProvider(
                secretId: input.asrConfig.tencentCloud.secretId,
                secretKey: input.asrConfig.tencentCloud.secretKey
            )
        case .aliyunSentence:
            return AliyunSentenceASRProvider(
                accessKeyId: input.asrConfig.aliyun.accessKeyId,
                accessKeySecret: input.asrConfig.aliyun.accessKeySecret,
                appKey: input.asrConfig.aliyun.appKey
            )
        case .volcengineSentence:
            return VolcengineSentenceASRProvider(apiKey: input.asrConfig.volcengine.apiKey)
        case .xunfeiSentence:
            return XunfeiSentenceASRProvider(
                appID: input.asrConfig.xunfei.appID,
                apiKey: input.asrConfig.xunfei.apiKey,
                apiSecret: input.asrConfig.xunfei.apiSecret
            )
        case .xiaomiMiMoASR:
            return XiaomiMiMoASRProvider(
                apiKey: input.asrConfig.xiaomiMiMo.apiKey,
                baseURL: XiaomiMiMoASRProvider.defaultBaseURL
            )
        case .xiaomiMiMoTokenPlanASR:
            return XiaomiMiMoASRProvider(
                apiKey: input.asrConfig.xiaomiMiMoTokenPlan.apiKey,
                baseURL: XiaomiMiMoASRProvider.tokenPlanBaseURL
            )
        }
    }

    private static func errorMessage(from error: Error) -> String {
        if let memoechoError = error as? MemoEchoError {
            return memoechoError.userMessage
        }
        if let configError = error as? ConfigValidationError {
            return configError.errorDescription ?? error.localizedDescription
        }
        return "云端识别验证失败，请检查配置或网络后重试"
    }
}
