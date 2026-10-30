import Foundation

/// Business requests get one silent retry. Independent fixture probes own their own budget.
enum ServiceRequestRetry {
    @TaskLocal static var currentDelay: RetryDelay?

    /// Per-operation metadata only; it never changes provider errors or probe budgets.
    actor RetryDelay {
        private(set) var seconds: TimeInterval = 0.3

        func observe(_ response: HTTPURLResponse) {
            guard response.statusCode == 408 || response.statusCode == 429 || (500...599).contains(response.statusCode),
                  let delay = ServiceProbeFailure.retryDelay(response.value(forHTTPHeaderField: "Retry-After")) else { return }
            seconds = max(seconds, delay)
        }
    }

    static func perform<T>(
        isolation: isolated (any Actor)? = #isolation,
        automaticallyRetry: Bool = true,
        shouldContinue: () -> Bool = { true },
        operation: () async throws -> T
    ) async throws -> T {
        func check() throws {
            try Task.checkCancellation()
            guard shouldContinue() else { throw CancellationError() }
        }
        let delay = RetryDelay()
        try check()
        do {
            return try await $currentDelay.withValue(delay, operation: operation, isolation: isolation)
        } catch {
            try check()
            guard automaticallyRetry, isRetryable(error) else { throw error }
        }
        try await waitBeforeRetry(seconds: await delay.seconds)
        try check()
        return try await $currentDelay.withValue(delay, operation: operation, isolation: isolation)
    }

    static func waitBeforeRetry(seconds: TimeInterval = 0.3) async throws {
        // Chunk untrusted header values so a very large delay cannot overflow Duration.
        var remaining = seconds
        while remaining > 0 {
            let interval = min(remaining, 60)
            try await Task.sleep(for: .seconds(interval))
            remaining -= interval
        }
    }

    static func isRetryable(_ error: Error) -> Bool {
        guard !ServiceProbeFailure.isCancellation(error) else { return false }
        if let error = error as? MemoEchoError {
            switch error {
            case .cloudASRNetworkFailure(let message), .llmNetworkFailure(let message):
                // Some providers include a response body after the status; never inspect or log it.
                if message.hasPrefix("HTTP "), let status = Int(message.dropFirst(5).prefix(3)) {
                    return status == 408 || status == 429 || (500...599).contains(status)
                }
                return true
            default: return false
            }
        }
        if let error = error as? RealtimeASRError {
            return error == .connectionClosed || error == .timeout
        }
        if let error = error as? URLError {
            return [.timedOut, .networkConnectionLost, .cannotConnectToHost,
                    .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet].contains(error.code)
        }
        return false
    }
}
