import XCTest
@testable import MemoEcho

final class LLMValidationServiceTests: XCTestCase {

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
        input.thinkingDisabled = true
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
                thinkingDisabled: false
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
            onThinkingUnsupported: {
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
            thinkingDisabled: false
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
