import XCTest
@testable import MemoEcho

final class LLMValidationServiceTests: XCTestCase {

    @MainActor
    func testStartupTimeoutRecoversWithinInitialValidationWithoutManualRefresh() async {
        let counter = Counter()
        let service = LLMValidationService(validator: { _, _ in
            await counter.increment()
            if await counter.currentValue() == 1 { throw URLError(.timedOut) }
        }, probePolicy: immediatePolicy())
        defer { service.shutdown() }
        let input = makeInput()
        service.validate(input)
        await waitUntil { service.status(for: input) == .ready }
        let count = await counter.currentValue()
        XCTAssertEqual(count, 2)
        XCTAssertFalse(service.isTransientRuntimeFailure)
    }

    @MainActor
    func testExhaustedStartupTimeoutIsTemporaryAndOrdinaryRefreshCanRecoverAfterCooldown() async {
        let counter = Counter()
        let service = LLMValidationService(validator: { _, _ in
            await counter.increment()
            if await counter.currentValue() <= 3 { throw URLError(.timedOut) }
        }, probePolicy: immediatePolicy())
        defer { service.shutdown() }
        let input = makeInput()
        service.validate(input)
        await waitUntil { service.status(for: input) == .failed }
        let initialCount = await counter.currentValue()
        XCTAssertEqual(initialCount, 3)
        XCTAssertEqual(LLMStatusPresentation(status: service.status(for: input),
            isTransientFailure: service.isTransientRuntimeFailure).text, "暂不可用")
        service.validate(input)
        await waitUntil { service.status(for: input) == .ready }
        let recoveredCount = await counter.currentValue()
        XCTAssertEqual(recoveredCount, 4)
    }

    @MainActor
    func testStartupFailureDoesNotLoopDuringCooldownButExplicitRetryCanRecover() async {
        let counter = Counter()
        let service = LLMValidationService(validator: { _, _ in
            await counter.increment()
            if await counter.currentValue() <= 3 { throw URLError(.timedOut) }
        }, probePolicy: immediatePolicy(cooldown: 60))
        defer { service.shutdown() }
        let input = makeInput()
        service.validate(input)
        await waitUntil { service.status(for: input) == .failed }
        for _ in 0..<5 { service.validate(input) }
        let count = await counter.currentValue()
        XCTAssertEqual(count, 3)
        service.retry(input)
        await waitUntil { service.status(for: input) == .ready }
    }

    @MainActor
    func testStartupRetryAfterCannotBeBypassedByRefreshOrBusinessSend() async {
        let counter = Counter()
        let service = LLMValidationService(validator: { _, _ in
            await counter.increment()
            throw ServiceProbeFailure(kind: .transient, message: "服务限流，请稍后重试",
                                      retryAfter: 60, httpStatus: 429)
        }, probePolicy: immediatePolicy())
        defer { service.health.reset(ifDifferent: "cleanup"); service.shutdown() }
        let input = makeInput()
        service.validate(input)
        await waitUntil { service.status(for: input) == .failed }
        XCTAssertTrue(service.isTransientRuntimeFailure)
        XCTAssertFalse(service.canRetry(input))
        service.validate(input)
        service.retry(input)
        do {
            try await service.prepareForBusinessRequest()
            XCTFail("The startup probe's server cooldown must protect business sends")
        } catch {
            XCTAssertEqual(error as? MemoEchoError, .llmNetworkFailure(message: "服务限流，请稍后重试"))
        }
        let count = await counter.currentValue()
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testStartupThinkingFallbackStaysOmittedOnNetworkRetryWithinOneBudget() async {
        let transport = StartupThinkingTransport()
        let service = makeTransportService(transport)
        defer { service.shutdown() }
        service.validate(makeInput())
        await waitUntil { service.status == .ready }
        let thinking = await transport.thinkingRequests
        XCTAssertEqual(thinking, [true, false, false])
    }

    @MainActor
    func testStartupThinkingFallbackAndPersistentNetworkFailureStopAtThreeActualSends() async {
        let transport = StartupThinkingTransport(persistentFailure: true)
        let service = makeTransportService(transport)
        defer { service.shutdown() }
        service.validate(makeInput())
        await waitUntil { service.status == .failed }
        XCTAssertTrue(service.isTransientRuntimeFailure)
        let thinking = await transport.thinkingRequests
        XCTAssertEqual(thinking, [true, false, false])
    }

    @MainActor
    private func makeTransportService(_ transport: StartupThinkingTransport) -> LLMValidationService {
        LLMValidationService(validator: { input, callback in
            let provider = LLMProvider(baseURL: input.baseURL, apiKey: input.apiKey, model: input.model,
                omitThinkingParameter: input.omitThinkingParameter, onThinkingUnsupported: callback,
                requestSender: { try await transport.send($0) })
            try await provider.validateConfiguration()
        }, probePolicy: immediatePolicy())
    }

    private func immediatePolicy(cooldown: TimeInterval = 0) -> ServiceHealthMonitor.Policy {
        .init(delays: [0, 0], cooldown: cooldown, episodeTimeout: 5, jitter: { 0 },
              sleep: { _ in try Task.checkCancellation() }, waitForNetwork: { try Task.checkCancellation() })
    }

    @MainActor
    func testThinkingFallbackKeepsCurrentConfigurationReadyWithoutAnotherRequest() async {
        let counter = Counter()
        let service = LLMValidationService(validator: { _, onThinkingUnsupported in
            await counter.increment()
            await onThinkingUnsupported()
        })
        var input = makeInput()
        service.validate(input)
        await waitUntil { service.status == .ready }
        input.omitThinkingParameter = true
        XCTAssertEqual(service.status(for: input), .ready)
        service.validate(input)
        let count = await counter.currentValue()
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testSameFlightIsSharedEvenWhenExplicitRetryIsRequested() async {
        let counter = Counter()
        let input = makeInput()
        let service = LLMValidationService(validator: { _, _ in
            await counter.increment()
            try await Task.sleep(for: .milliseconds(30))
        })
        service.validate(input)
        service.validate(input)
        service.validate(input, force: true)
        XCTAssertEqual(service.status(for: input), .checking)
        await waitUntil { service.status == .ready }
        let count = await counter.currentValue()
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testReadyStatusBelongsOnlyToValidatedInput() async {
        let service = LLMValidationService(validator: { _, _ in })
        let input = makeInput()
        service.validate(input)
        await waitUntil { service.status == .ready }
        XCTAssertEqual(service.status(for: input), .ready)
        XCTAssertEqual(service.status(for: makeInput(model: "other-model")), .incomplete)
        service.invalidateCurrentValidation()
        XCTAssertEqual(service.status(for: input), .failed)
        service.validate(input)
        XCTAssertEqual(service.status(for: input), .failed)
        service.validate(input, force: true)
        await waitUntil { service.status(for: input) == .ready }
    }

    @MainActor
    func testFailedValidationDoesNotRetryUntilExplicitRequestAndRedactsUnknownError() async {
        let counter = Counter()
        let service = LLMValidationService(validator: { _, _ in
            await counter.increment()
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "test-key response body"])
        })
        service.validate(makeInput())
        await waitUntil { service.status == .failed }
        service.validate(makeInput())
        XCTAssertEqual(service.lastErrorMessage, "AI 模型验证失败，请检查配置或网络后重试")
        let count = await counter.currentValue()
        XCTAssertEqual(count, 1)
        service.validate(makeInput(), force: true)
        await waitUntil { service.status == .failed }
        let retriedCount = await counter.currentValue()
        XCTAssertEqual(retriedCount, 2)
    }

    @MainActor
    func testIncompleteInputDoesNotRunValidator() async {
        let counter = Counter()
        let service = LLMValidationService(
            validator: { _, _ in
                await counter.increment()
            }
        )

        service.validate(
            LLMValidationInput(
                baseURL: "",
                apiKey: "key",
                model: "gpt-4o-mini",
                omitThinkingParameter: false
            )
        )

        XCTAssertEqual(service.status, .incomplete)
        XCTAssertNil(service.lastErrorMessage)
        let count = await counter.currentValue()
        XCTAssertEqual(count, 0)
    }

    @MainActor
    func testSuccessfulValidationTransitionsToReady() async {
        let service = LLMValidationService(
            validator: { _, _ in
                try await Task.sleep(for: .milliseconds(20))
            }
        )

        service.validate(makeInput())

        XCTAssertEqual(service.status, .checking)
        await waitUntil { service.status == .ready }
        XCTAssertNil(service.lastErrorMessage)
    }

    @MainActor
    func testValidationFailureExposesUserFacingError() async {
        let service = LLMValidationService(
            validator: { _, _ in
                throw MemoEchoError.invalidLLMConfiguration(detail: "模型不存在或 URL 错误")
            }
        )

        service.validate(makeInput())

        await waitUntil { service.status == .failed }
        XCTAssertEqual(service.lastErrorMessage, "LLM 配置异常：模型不存在或 URL 错误")
    }

    @MainActor
    func testLatestValidationWinsOverCancelledRequest() async {
        let service = LLMValidationService(
            validator: { input, _ in
                if input.model == "first-model" {
                    try await Task.sleep(for: .milliseconds(150))
                    throw MemoEchoError.llmNetworkFailure(message: "old request should be cancelled")
                }
            }
        )

        service.validate(makeInput(model: "first-model"))
        service.validate(makeInput(model: "second-model"))

        await waitUntil { service.status == .ready }
        XCTAssertNil(service.lastErrorMessage)
    }

    @MainActor
    func testThinkingUnsupportedCallbackCanBeTriggered() async {
        let counter = Counter()
        let service = LLMValidationService(
            onThinkingUnsupported: { _ in
                Task {
                    await counter.increment()
                }
            },
            validator: { _, onThinkingUnsupported in
                await onThinkingUnsupported()
            }
        )

        service.validate(makeInput())

        await waitUntil { service.status == .ready }
        let start = ContinuousClock.now
        while ContinuousClock.now - start < .seconds(1) {
            if await counter.currentValue() == 1 {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for callback")
    }

    private func makeInput(model: String = "gpt-4o-mini") -> LLMValidationInput {
        LLMValidationInput(
            baseURL: "https://example.com/v1",
            apiKey: "test-key",
            model: model,
            omitThinkingParameter: false
        )
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < timeout {
            if condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for condition")
    }
}

private actor Counter {
    private var value = 0

    func increment() {
        value += 1
    }

    func currentValue() -> Int {
        value
    }
}

private actor StartupThinkingTransport {
    private let persistentFailure: Bool
    private(set) var thinkingRequests: [Bool] = []

    init(persistentFailure: Bool = false) { self.persistentFailure = persistentFailure }

    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        let hasThinking = body?["thinking"] != nil
        thinkingRequests.append(hasThinking)
        if hasThinking {
            return (Data(#"{"error":{"message":"thinking is not supported"}}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!)
        }
        if persistentFailure || thinkingRequests.count == 2 { throw URLError(.networkConnectionLost) }
        let content = #"{"mode":"plain_text","text":"合成验证。","correction_applied":false}"#
        let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
