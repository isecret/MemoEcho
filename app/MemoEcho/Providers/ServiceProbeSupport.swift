import Foundation
import Network

/// Probe results contain only bounded, local messages, never response bodies or credentials.
struct ServiceProbeFailure: Error, LocalizedError, Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case transient, confirmedBlocker, invalidResponse, localFixture, budgetExhausted
    }

    let kind: Kind
    let message: String
    var retryAfter: TimeInterval? = nil
    var httpStatus: Int? = nil
    var waitsForNetwork = false
    var errorDescription: String? { message }
    var isRetryable: Bool { kind == .transient }

    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
            || (error as? MemoEchoError) == .sessionCancelled
            || (error as? RealtimeASRError) == .cancelled
    }

    /// Used only for independent fixture requests, never to invalidate a user request's configuration.
    static func classify(_ error: Error) -> ServiceProbeFailure {
        if let failure = error as? ServiceProbeFailure { return failure }
        if let error = error as? MemoEchoError {
            switch error {
            case .cloudASRConfigurationIncomplete, .llmConfigurationIncomplete:
                return .init(kind: .confirmedBlocker, message: "服务配置不完整")
            case .cloudASRAuthenticationFailure:
                return .init(kind: .confirmedBlocker, message: "服务鉴权失败，请检查凭据或产品权限")
            case .invalidLLMConfiguration:
                return .init(kind: .confirmedBlocker, message: "模型配置或鉴权未通过，请检查设置")
            case .cloudASRNetworkFailure, .llmNetworkFailure:
                return .init(kind: .transient, message: "服务暂时不可用，请稍后重试")
            default: break
            }
        }
        if let error = error as? RealtimeASRError {
            switch error {
            case .configuration, .authentication:
                return .init(kind: .confirmedBlocker, message: "语音服务配置或鉴权未通过")
            case .connectionClosed, .timeout:
                return .init(kind: .transient, message: "语音服务连接中断或超时")
            default: break
            }
        }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet:
                return .init(kind: .transient, message: "网络未连接，等待网络恢复", waitsForNetwork: true)
            case .timedOut, .networkConnectionLost, .cannotConnectToHost:
                return .init(kind: .transient, message: "网络连接失败，请稍后重试")
            default:
                return .init(kind: .invalidResponse, message: "无法安全连接服务，请检查地址和网络设置")
            }
        }
        return .init(kind: .invalidResponse, message: "服务测试未通过，请稍后重试或检查设置")
    }

    static func http(_ response: HTTPURLResponse, data: Data = Data(), now: Date = Date()) -> ServiceProbeFailure? {
        let status = response.statusCode
        let delay = retryDelay(response.value(forHTTPHeaderField: "Retry-After"), now: now)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let envelope = object?["error"] as? [String: Any]
        let tencent = (object?["Response"] as? [String: Any])?["Error"] as? [String: Any]
        let code = (envelope?["code"] as? String ?? envelope?["type"] as? String
            ?? tencent?["Code"] as? String ?? object?["code"] as? String ?? object?["Code"] as? String)?.lowercased()
        if let code, ["invalid_api_key", "model_not_found", "invalid_model", "permission_denied", "unauthorized",
                       "insufficient_quota", "quota_exhausted", "billing_hard_limit_reached",
                       "service_not_activated", "service_not_enabled", "invalidaccesskeyid", "signaturedoesnotmatch"].contains(code)
            || code.hasPrefix("authfailure.") || code == "authfailure" {
            return .init(kind: .confirmedBlocker, message: "服务凭据、模型、产品权限或额度未通过",
                         retryAfter: delay, httpStatus: status)
        }
        if [408, 429, 500, 502, 503, 504].contains(status) {
            return .init(kind: .transient, message: status == 429 ? "服务限流，请稍后重试" : "服务暂时不可用，请稍后重试",
                         retryAfter: delay, httpStatus: status)
        }
        if status == 401 || status == 403 {
            return .init(kind: .confirmedBlocker, message: "服务鉴权失败，请检查凭据或产品权限",
                         retryAfter: delay, httpStatus: status)
        }
        if (200...299).contains(status) {
            if let code, ["server_error", "internal_error", "internalerror", "rate_limit_exceeded",
                          "requestlimitexceeded", "throttling", "throttling.user"].contains(code) {
                return .init(kind: .transient, message: "服务暂时不可用，请稍后重试", retryAfter: delay, httpStatus: status)
            }
            if envelope != nil || tencent != nil {
                return .init(kind: .invalidResponse, message: "服务未接受测试请求，请检查接口和模型设置",
                             retryAfter: delay, httpStatus: status)
            }
            return nil
        }
        // 404 may be a gateway routing problem; a generic 400 does not prove invalid credentials.
        return .init(kind: .invalidResponse, message: "服务未接受测试请求，请检查接口和模型设置",
                     retryAfter: delay, httpStatus: status)
    }

    static func retryDelay(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}

actor ServiceProbeBudget {
    let maximumRequests: Int
    private(set) var requestsUsed = 0
    var remainingRequests: Int { max(0, maximumRequests - requestsUsed) }

    init(maximumRequests: Int = 3) { self.maximumRequests = max(0, maximumRequests) }

    func consume() throws {
        try Task.checkCancellation()
        guard requestsUsed < maximumRequests else {
            throw ServiceProbeFailure(kind: .budgetExhausted, message: "本轮检查次数已用完，请稍后重试")
        }
        requestsUsed += 1
    }
}

enum ServiceProbeContext {
    @TaskLocal static var budget: ServiceProbeBudget?

    /// Each inference send is counted, including LLM's existing field-compatibility fallback.
    /// Token requests are classified and cancellable, but are not inference sends.
    static func send(
        _ request: URLRequest,
        isInference: Bool = true,
        allowsThinkingFallback: Bool = false,
        using sender: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) async throws -> (Data, URLResponse) {
        guard let budget else { return try await sender(request) }
        try Task.checkCancellation()
        if isInference { try await budget.consume() }
        do {
            let result = try await sender(request)
            try Task.checkCancellation()
            if let http = result.1 as? HTTPURLResponse,
               let failure = ServiceProbeFailure.http(http, data: result.0) {
                // Preserve the existing compatibility branch, which examines a sanitized 400 reason.
                // Its second request still passes through this method and consumes this same budget.
                if !(allowsThinkingFallback && http.statusCode == 400 && failure.kind == .invalidResponse
                     && (failure.retryAfter ?? 0) <= 0
                     && isThinkingRejection(result.0)) { throw failure }
            }
            return result
        } catch {
            if Task.isCancelled || ServiceProbeFailure.isCancellation(error) { throw CancellationError() }
            throw ServiceProbeFailure.classify(error)
        }
    }

    static func preserveFailure(_ error: Error) throws {
        if Task.isCancelled || ServiceProbeFailure.isCancellation(error) { throw CancellationError() }
        if let failure = error as? ServiceProbeFailure { throw failure }
    }

    private static func isThinkingRejection(_ data: Data) -> Bool {
        let body = String(decoding: data, as: UTF8.self).lowercased()
        let explicitlyRejected = body.contains("unsupported") || body.contains("not supported")
            || body.contains("unknown") || body.contains("not permitted") || body.contains("invalid")
        return (body.contains("thinking") && explicitlyRejected)
            || (body.contains(".type") && body.contains("`disabled`") && body.contains("not supported"))
    }
}

enum LLMValidationPurpose: Sendable, Hashable { case polish, translation }

enum ValidationFixture {
    static let version = 1
    static let text = "明天下午三点开会。"
    static let translationTarget = TranslationTargetLanguage.english
}

/// Observes OS path changes only; it never polls or sends a network request.
enum ServiceProbeNetworkRecovery {
    static func waitUntilAvailable() async throws {
        try await waitUntilAvailable(monitor: SystemProbeNetworkPathMonitor())
    }

    static func waitUntilAvailable(monitor: any ServiceProbeNetworkPathMonitoring) async throws {
        let waiter = NetworkRecoveryWaiter(monitor: monitor)
        try await waiter.wait()
    }
}

protocol ServiceProbeNetworkPathMonitoring: Sendable {
    func start(onUpdate: @escaping @Sendable (Bool) -> Void)
    func cancel()
}

private final class SystemProbeNetworkPathMonitor: ServiceProbeNetworkPathMonitoring, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "me.wangmao.memoecho.probe-network-recovery")

    // NetworkRecoveryWaiter serializes setup and teardown on its actor.
    func start(onUpdate: @escaping @Sendable (Bool) -> Void) {
        monitor.pathUpdateHandler = { path in onUpdate(path.status == .satisfied) }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.pathUpdateHandler = nil
        monitor.cancel()
    }
}

private actor NetworkRecoveryWaiter {
    private let monitor: any ServiceProbeNetworkPathMonitoring
    private var continuation: CheckedContinuation<Void, any Error>?
    private var result: Result<Void, any Error>?

    init(monitor: any ServiceProbeNetworkPathMonitoring) { self.monitor = monitor }

    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let result {
                    continuation.resume(with: result)
                    return
                }
                self.continuation = continuation
                if Task.isCancelled {
                    complete(.failure(CancellationError()))
                    return
                }
                monitor.start { [weak self] available in
                    guard available else { return }
                    Task { await self?.complete(.success(())) }
                }
            }
            try Task.checkCancellation()
        } onCancel: {
            // The actor serializes cancellation with start and path callbacks, so a late callback
            // cannot resume twice or restart a cancelled monitor.
            Task { await self.complete(.failure(CancellationError())) }
        }
    }

    private func complete(_ result: Result<Void, any Error>) {
        guard self.result == nil else { return }
        self.result = result
        monitor.cancel()
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}
