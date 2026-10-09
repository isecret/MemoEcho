import Foundation

@MainActor
@Observable
final class LLMValidationService {
    typealias Validator = @Sendable (LLMValidationInput, @escaping @MainActor @Sendable () -> Void) async throws -> Void

    private let validator: Validator
    private let onThinkingUnsupported: @MainActor @Sendable (LLMValidationInput) -> Void

    private var validationTask: Task<Void, Never>?
    private var activeFingerprint: String?
    private var lastCompletedFingerprint: String?
    private var activeRequestID: UUID?

    private(set) var status: LLMModelStatus = .incomplete
    private(set) var lastErrorMessage: String?
    private(set) var isTransientRuntimeFailure = false

    init(
        onThinkingUnsupported: @escaping @MainActor @Sendable (LLMValidationInput) -> Void = { _ in },
        validator: @escaping Validator = LLMValidationService.defaultValidator
    ) {
        self.onThinkingUnsupported = onThinkingUnsupported
        self.validator = validator
    }

    func status(for input: LLMValidationInput) -> LLMModelStatus {
        guard input.isComplete else { return .incomplete }
        let fingerprint = Self.configurationFingerprint(input)
        if activeFingerprint == fingerprint { return .checking }
        guard activeFingerprint == nil, lastCompletedFingerprint == fingerprint else { return .incomplete }
        return status
    }

    /// 主链路已确认当前配置失效时，不能继续复用先前的成功结果。
    func invalidateCurrentValidation(isTransient: Bool = false) {
        isTransientRuntimeFailure = isTransient
        let fingerprint = activeFingerprint ?? lastCompletedFingerprint
        cancelOngoingValidation()
        lastCompletedFingerprint = fingerprint
        status = .failed
        lastErrorMessage = "AI 模型暂不可用，请检查配置并重试"
    }

    func validate(_ input: LLMValidationInput, force: Bool = false) {
        let normalizedInput = input.normalized()

        guard normalizedInput.isComplete else {
            cancelOngoingValidation()
            activeFingerprint = nil
            lastCompletedFingerprint = nil
            status = .incomplete
            lastErrorMessage = nil
            return
        }

        let fingerprint = Self.configurationFingerprint(normalizedInput)
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

        let validator = self.validator
        let onThinkingUnsupported: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self, self.activeRequestID == requestID else { return }
            self.onThinkingUnsupported(normalizedInput)
        }

        validationTask = Task { [weak self] in
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
                    self.status = .ready
                    self.lastErrorMessage = nil
                case .failure(let error):
                    self.status = .failed
                    self.lastErrorMessage = Self.errorMessage(from: error)
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
