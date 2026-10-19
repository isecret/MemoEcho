import Foundation

@MainActor
@Observable
final class CloudASRValidationService {
    typealias ValidatorFactory = @MainActor @Sendable (CloudASRValidationInput) throws -> any CloudASRValidating

    private let validatorFactory: ValidatorFactory
    private let configStore: ConfigStore
    let health: ServiceHealthMonitor
    private var currentInput: CloudASRValidationInput?

    private var validationTask: Task<Void, Never>?
    private var closingValidationTask: Task<Void, Never>?
    private var activeFingerprint: String?
    private var lastCompletedFingerprint: String?
    private var activeRequestID: UUID?

    private var validationStatus: CloudASRValidationDisplayStatus = .incomplete
    var status: CloudASRValidationDisplayStatus { currentInput.map { status(for: $0) } ?? validationStatus }
    private var validationErrorMessage: String?
    var lastErrorMessage: String? { health.failure?.message ?? validationErrorMessage }
    private var legacyTransientFailure = false
    var isTransientRuntimeFailure: Bool { health.state == .temporaryFailure || legacyTransientFailure }

    init(
        configStore: ConfigStore,
        validatorFactory: @escaping ValidatorFactory = CloudASRValidationService.defaultValidatorFactory,
        probePolicy: ServiceHealthMonitor.Policy = .init()
    ) {
        self.configStore = configStore
        self.validatorFactory = validatorFactory
        health = ServiceHealthMonitor(policy: probePolicy)
    }

    func syncFromConfig(for input: CloudASRValidationInput) {
        currentInput = input
        health.reset(ifDifferent: input.fingerprint)
        if lastCompletedFingerprint != input.fingerprint { legacyTransientFailure = false }
        guard input.isCloudPlatform else {
            cancelOngoingValidation()
            validationStatus = .incomplete
            validationErrorMessage = nil
            activeFingerprint = nil
            lastCompletedFingerprint = nil
            return
        }

        let cloudState = cloudState(for: input)
        if !cloudState.isComplete {
            cancelOngoingValidation()
            validationStatus = .incomplete
            validationErrorMessage = nil
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
            validationStatus = .incomplete
            validationErrorMessage = nil
            lastCompletedFingerprint = nil
        case .verified:
            validationStatus = .ready
            validationErrorMessage = nil
            lastCompletedFingerprint = input.fingerprint
        case .failed:
            validationStatus = .failed
            validationErrorMessage = cloudState.lastValidationError
            lastCompletedFingerprint = input.fingerprint
        }
    }

    func status(for input: CloudASRValidationInput) -> CloudASRValidationDisplayStatus {
        guard input.isCloudPlatform, input.isComplete, matchesSavedConfiguration(input) else { return .incomplete }
        if health.fingerprint == input.fingerprint {
            switch health.state {
            case .checking: return .checking
            case .ready: return .ready
            case .temporaryFailure, .blocked: return .failed
            case .idle: break
            }
        }
        if activeFingerprint == input.fingerprint { return .checking }
        if activeFingerprint == nil, lastCompletedFingerprint == input.fingerprint { return validationStatus }
        switch cloudState(for: input).validationStatus {
        case .verified: return .ready
        case .failed: return .failed
        case .unvalidated, .validating: return .incomplete
        }
    }

    func invalidateCurrentValidation(isTransient: Bool = false) {
        legacyTransientFailure = isTransient
        let input = CloudASRValidationInput(platform: configStore.asrConfig.selectedPlatform, asrConfig: configStore.asrConfig)
        guard input.isCloudPlatform else { return }
        cancelOngoingValidation()
        lastCompletedFingerprint = input.fingerprint
        validationStatus = .failed
        validationErrorMessage = "云端识别暂不可用，请检查配置并重试"
        try? configStore.updateCloudValidationState(for: input.platform, status: .failed, error: lastErrorMessage)
    }

    func validate(_ input: CloudASRValidationInput, force: Bool = false) {
        currentInput = input
        health.reset(ifDifferent: input.fingerprint)
        if force { retry(input); return }
        if health.state != .idle || health.businessActive { return }
        guard input.isCloudPlatform else {
            syncFromConfig(for: input)
            return
        }

        guard input.isComplete else {
            cancelOngoingValidation()
            validationStatus = .incomplete
            validationErrorMessage = nil
            activeFingerprint = nil
            lastCompletedFingerprint = nil
            return
        }

        let fingerprint = input.fingerprint
        if activeFingerprint == fingerprint { return }
        if !force {
            if lastCompletedFingerprint == fingerprint, validationStatus != .checking {
                return
            }
        }

        cancelOngoingValidation()
        let requestID = UUID()
        activeRequestID = requestID
        activeFingerprint = fingerprint
        legacyTransientFailure = false
        validationStatus = .checking
        validationErrorMessage = nil

        let validatorFactory = self.validatorFactory
        let configStore = self.configStore

        let previousValidation = closingValidationTask
        let health = health
        validationTask = Task { [weak self] in
            await previousValidation?.value
            await health.waitForClose()
            guard !Task.isCancelled else { return }
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
                        self.validationStatus = .incomplete
                        return
                    }
                    try configStore.updateCloudValidationState(for: input.platform, status: .verified)
                    self.activeFingerprint = nil
                    self.activeRequestID = nil
                    self.lastCompletedFingerprint = fingerprint
                    self.validationTask = nil
                    self.validationStatus = .ready
                    self.validationErrorMessage = nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                let errorMessage = Self.errorMessage(from: error)
                await MainActor.run {
                    guard let self, self.activeRequestID == requestID else { return }
                    guard self.matchesSavedConfiguration(input) else {
                        self.cancelOngoingValidation()
                        self.validationStatus = .incomplete
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
                    self.validationStatus = .failed
                    self.validationErrorMessage = errorMessage
                }
            }
        }
    }

    func canRetry(_ input: CloudASRValidationInput) -> Bool {
        input.isCloudPlatform && input.isComplete && health.canStart && activeFingerprint == nil
    }

    func retry(_ input: CloudASRValidationInput) {
        guard canRetry(input) else { return }
        startProbe(input, automatic: false)
    }

    func reportRuntimeFailure(_ input: CloudASRValidationInput) { startProbe(input, automatic: true) }

    func readinessStatus(for input: CloudASRValidationInput) -> CloudASRValidationDisplayStatus {
        if input.isComplete, matchesSavedConfiguration(input), health.fingerprint == input.fingerprint,
           health.preservesReadiness { return .ready }
        return status(for: input)
    }

    func setBusinessActive(_ active: Bool) {
        health.setBusinessActive(active)
        if active, validationTask != nil {
            cancelOngoingValidation()
            validationStatus = .incomplete
        }
    }
    func waitForProbeClose() async {
        await closingValidationTask?.value
        await health.waitForClose()
    }
    func prepareForBusinessRequest() async throws {
        await waitForProbeClose()
        try Task.checkCancellation()
        guard !health.isCoolingDown else {
            throw MemoEchoError.cloudASRNetworkFailure(message: "服务限流，请稍后重试")
        }
        guard health.state != .blocked else {
            throw MemoEchoError.cloudASRAuthenticationFailure
        }
    }
    func shutdown() { cancelOngoingValidation(); health.cancel() }

    func recordSuccess(_ input: CloudASRValidationInput) {
        guard input.isCloudPlatform, input.isComplete, matchesSavedConfiguration(input) else { return }
        currentInput = input
        health.recordSuccess(for: input.fingerprint)
        lastCompletedFingerprint = input.fingerprint
        validationStatus = .ready
        validationErrorMessage = nil
        legacyTransientFailure = false
        try? configStore.updateCloudValidationState(for: input.platform, status: .verified)
    }

    private func startProbe(_ input: CloudASRValidationInput, automatic: Bool) {
        guard input.isCloudPlatform, input.isComplete, matchesSavedConfiguration(input), activeFingerprint == nil else { return }
        legacyTransientFailure = false
        currentInput = input
        let key = input.fingerprint
        let factory = validatorFactory
        let previousValidation = closingValidationTask
        let savedInput = CloudASRValidationInput(platform: input.platform, asrConfig: configStore.asrConfig)
        let verified = cloudState(for: savedInput).validationStatus == .verified
        health.check(fingerprint: key, verified: verified, automatic: automatic,
                     requestTimeout: input.platform.isRealtime ? 30 : 15, operation: {
            await previousValidation?.value
            try Task.checkCancellation()
            let validator = try factory(input)
            try await validator.validateCredentials()
        }, completion: { [weak self] result in
            guard let self, self.matchesSavedConfiguration(input) else { return }
            self.lastCompletedFingerprint = key
            self.legacyTransientFailure = false
            switch result {
            case .success:
                self.validationStatus = .ready
                self.validationErrorMessage = nil
                try? self.configStore.updateCloudValidationState(for: input.platform, status: .verified)
            case .failure(let error):
                self.validationErrorMessage = error.message
                if error.kind == .confirmedBlocker {
                    self.validationStatus = .failed
                    try? self.configStore.updateCloudValidationState(for: input.platform, status: .failed, error: error.message)
                }
            }
        })
    }

    private func cancelOngoingValidation() {
        let previous = closingValidationTask
        let current = validationTask
        current?.cancel()
        if current != nil {
            closingValidationTask = Task { await previous?.value; await current?.value }
        }
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
