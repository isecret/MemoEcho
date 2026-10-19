import Foundation

@MainActor
@Observable
final class LLMValidationService {
    typealias Validator = @Sendable (LLMValidationInput, @escaping @MainActor @Sendable () -> Void) async throws -> Void

    private let validator: Validator
    private let usesDefaultValidator: Bool
    let health: ServiceHealthMonitor
    private var verifiedFingerprint: String?
    private var currentInput: LLMValidationInput?
    private var pendingPurposes: [LLMValidationPurpose] = []
    private var purposeFingerprint: String?
    private let onThinkingUnsupported: @MainActor @Sendable (LLMValidationInput) -> Void

    private var validationTask: Task<Void, Never>?
    private var closingValidationTask: Task<Void, Never>?
    private var activeFingerprint: String?
    private var lastCompletedFingerprint: String?
    private var activeRequestID: UUID?

    private var validationStatus: LLMModelStatus = .incomplete
    var status: LLMModelStatus { currentInput.map { status(for: $0) } ?? validationStatus }
    private var validationErrorMessage: String?
    var lastErrorMessage: String? { health.failure?.message ?? validationErrorMessage }
    private var legacyTransientFailure = false
    var isTransientRuntimeFailure: Bool { health.state == .temporaryFailure || legacyTransientFailure }

    init(
        onThinkingUnsupported: @escaping @MainActor @Sendable (LLMValidationInput) -> Void = { _ in },
        validator: Validator? = nil,
        probePolicy: ServiceHealthMonitor.Policy = .init()
    ) {
        self.onThinkingUnsupported = onThinkingUnsupported
        self.validator = validator ?? Self.defaultValidator
        usesDefaultValidator = validator == nil
        health = ServiceHealthMonitor(policy: probePolicy)
    }

    func status(for input: LLMValidationInput) -> LLMModelStatus {
        guard input.isComplete else { return .incomplete }
        let fingerprint = Self.configurationFingerprint(input)
        if health.fingerprint == fingerprint {
            switch health.state {
            case .checking: return .checking
            case .ready: return .ready
            case .temporaryFailure, .blocked: return .failed
            case .idle: break
            }
        }
        if activeFingerprint == fingerprint { return .checking }
        guard activeFingerprint == nil, lastCompletedFingerprint == fingerprint else { return .incomplete }
        return validationStatus
    }

    /// 主链路已确认当前配置失效时，不能继续复用先前的成功结果。
    func invalidateCurrentValidation(isTransient: Bool = false) {
        health.cancel()
        legacyTransientFailure = isTransient
        let fingerprint = activeFingerprint ?? lastCompletedFingerprint
        cancelOngoingValidation()
        lastCompletedFingerprint = fingerprint
        validationStatus = .failed
        validationErrorMessage = "AI 模型暂不可用，请检查配置并重试"
    }

    func validate(_ input: LLMValidationInput, force: Bool = false) {
        let normalizedInput = input.normalized()
        currentInput = normalizedInput
        resetPurposes(for: Self.configurationFingerprint(normalizedInput))
        health.reset(ifDifferent: Self.configurationFingerprint(normalizedInput))
        if force { retry(normalizedInput); return }
        if health.state != .idle || health.businessActive { return }

        guard normalizedInput.isComplete else {
            cancelOngoingValidation()
            activeFingerprint = nil
            lastCompletedFingerprint = nil
            validationStatus = .incomplete
            validationErrorMessage = nil
            return
        }

        let fingerprint = Self.configurationFingerprint(normalizedInput)
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

        let validator = self.validator
        let onThinkingUnsupported: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self, self.activeRequestID == requestID else { return }
            self.onThinkingUnsupported(normalizedInput)
        }

        let previousValidation = closingValidationTask
        let health = health
        validationTask = Task { [weak self] in
            await previousValidation?.value
            await health.waitForClose()
            guard !Task.isCancelled else { return }
            let result: Result<Void, Error>
            do {
                try await validator(normalizedInput, onThinkingUnsupported)
                result = .success(())
            } catch {
                result = .failure(error)
            }

            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self, self.activeRequestID == requestID else { return }
                self.activeFingerprint = nil
                self.activeRequestID = nil
                self.lastCompletedFingerprint = fingerprint
                self.validationTask = nil

                switch result {
                case .success:
                    self.validationStatus = .ready
                    self.verifiedFingerprint = fingerprint
                    self.validationErrorMessage = nil
                case .failure(let error):
                    self.validationStatus = .failed
                    self.validationErrorMessage = Self.errorMessage(from: error)
                }
            }
        }
    }

    func canRetry(_ input: LLMValidationInput) -> Bool {
        input.isComplete && health.canStart && activeFingerprint == nil
    }

    func retry(_ input: LLMValidationInput) {
        guard canRetry(input) else { return }
        startProbe(input, automatic: false)
    }

    func reportRuntimeFailure(_ input: LLMValidationInput, purpose: LLMValidationPurpose = .polish) {
        resetPurposes(for: Self.configurationFingerprint(input))
        pendingPurposes.removeAll { $0 == purpose }
        pendingPurposes.insert(purpose, at: 0)
        startProbe(input, automatic: true)
    }

    func readinessStatus(for input: LLMValidationInput) -> LLMModelStatus {
        let key = Self.configurationFingerprint(input)
        if input.isComplete, health.fingerprint == key, health.preservesReadiness { return .ready }
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
            throw MemoEchoError.llmNetworkFailure(message: "服务限流，请稍后重试")
        }
        guard health.state != .blocked else {
            throw MemoEchoError.invalidLLMConfiguration(detail: "服务测试未通过，请在设置中重试")
        }
    }
    func shutdown() { cancelOngoingValidation(); health.cancel() }

    func recordSuccess(_ input: LLMValidationInput, purpose: LLMValidationPurpose = .polish) {
        currentInput = input
        let key = Self.configurationFingerprint(input)
        resetPurposes(for: key)
        pendingPurposes.removeAll { $0 == purpose }
        health.recordSuccess(for: key, allPurposesHealthy: pendingPurposes.isEmpty)
        verifiedFingerprint = key
        lastCompletedFingerprint = key
        validationStatus = .ready
        validationErrorMessage = nil
        legacyTransientFailure = false
    }

    private func startProbe(_ input: LLMValidationInput, automatic: Bool) {
        guard input.isComplete else { return }
        let input = input.normalized()
        let key = Self.configurationFingerprint(input)
        guard activeFingerprint == nil else { return } // Share a running initial validation.
        legacyTransientFailure = false
        currentInput = input
        resetPurposes(for: key)
        if pendingPurposes.isEmpty { pendingPurposes = [.polish] }
        var omitThinking = input.omitThinkingParameter
        let validator = validator
        let useDefault = usesDefaultValidator
        health.check(fingerprint: key, verified: verifiedFingerprint == key,
                     automatic: automatic, requestTimeout: 15, operation: { [weak self] in
            guard let self else { throw CancellationError() }
            await self.closingValidationTask?.value
            try Task.checkCancellation()
            let callback: @MainActor @Sendable () -> Void = { [weak self] in
                guard let self, self.health.fingerprint == key, !Task.isCancelled else { return }
                omitThinking = true
                self.onThinkingUnsupported(input)
            }
            while let purpose = self.pendingPurposes.first {
                try Task.checkCancellation()
                if useDefault {
                    let provider = LLMProvider(baseURL: input.baseURL, apiKey: input.apiKey, model: input.model,
                                               omitThinkingParameter: omitThinking,
                                               onThinkingUnsupported: callback)
                    try await provider.validateConfiguration(purpose: purpose)
                } else { try await validator(input, callback) }
                try Task.checkCancellation()
                guard self.purposeFingerprint == key else { throw CancellationError() }
                self.pendingPurposes.removeAll { $0 == purpose }
            }
        }, completion: { [weak self] result in
            guard let self, Self.configurationFingerprint(self.currentInput ?? input) == key else { return }
            self.lastCompletedFingerprint = key
            self.legacyTransientFailure = false
            switch result {
            case .success:
                self.validationStatus = .ready
                self.verifiedFingerprint = key
                self.validationErrorMessage = nil
            case .failure(let error):
                self.validationErrorMessage = error.message
                if error.kind == .confirmedBlocker {
                    self.validationStatus = .failed
                    self.verifiedFingerprint = nil
                }
            }
        })
    }

    private func resetPurposes(for key: String) {
        guard purposeFingerprint != key else { return }
        purposeFingerprint = key
        pendingPurposes.removeAll()
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

    private static func configurationFingerprint(_ input: LLMValidationInput) -> String {
        // 验证中自动记住的兼容开关不改变连接身份，避免 fallback 成功后立即重复验证。
        var identity = input.normalized()
        identity.omitThinkingParameter = false
        return identity.fingerprint
    }

    private static func defaultValidator(
        input: LLMValidationInput,
        onThinkingUnsupported: @escaping @MainActor @Sendable () -> Void
    ) async throws {
        let provider = LLMProvider(
            baseURL: input.baseURL,
            apiKey: input.apiKey,
            model: input.model,
            omitThinkingParameter: input.omitThinkingParameter,
            onThinkingUnsupported: onThinkingUnsupported
        )
        try await provider.validateConfiguration()
    }

    private static func errorMessage(from error: Error) -> String {
        if let memoechoError = error as? MemoEchoError {
            return memoechoError.userMessage
        }
        if let configError = error as? ConfigValidationError {
            return configError.errorDescription ?? error.localizedDescription
        }
        return "AI 模型验证失败，请检查配置或网络后重试"
    }
}
