import XCTest
@testable import MemoEcho

@MainActor
final class ServiceRequestRetryTests: XCTestCase {
    func testPermanentErrorsAndCancellationAreNotRetried() async {
        let errors: [any Error] = [
            MemoEchoError.cloudASRConfigurationIncomplete,
            MemoEchoError.cloudASRAuthenticationFailure,
            MemoEchoError.invalidLLMConfiguration(detail: "synthetic"),
            MemoEchoError.cloudASRNetworkFailure(message: "HTTP 400: synthetic"),
            MemoEchoError.llmNetworkFailure(message: "HTTP 400: unsupported thinking"),
            MemoEchoError.llmNetworkFailure(message: "HTTP 404"),
            MemoEchoError.llmEmptyResponse, MemoEchoError.llmInvalidResponse,
            MemoEchoError.asrEmptyTranscript, MemoEchoError.asrModelMissing,
            MemoEchoError.textInjectionFailure(detail: "synthetic"),
            RealtimeASRError.authentication, RealtimeASRError.serviceRejected,
            RealtimePipelineError.backpressure, CancellationError(), URLError(.cancelled)
        ]
        for error in errors {
            var calls = 0
            do {
                let _: String = try await ServiceRequestRetry.perform {
                    calls += 1
                    throw error
                }
                XCTFail("Expected failure")
            } catch {}
            XCTAssertEqual(calls, 1)
        }
    }

    func testCancellationDuringRetryDelayDoesNotSendAgain() async {
        var calls = 0
        let firstAttempt = expectation(description: "First attempt failed")
        let task = Task {
            try await ServiceRequestRetry.perform { () -> String in
                calls += 1
                firstAttempt.fulfill()
                throw MemoEchoError.llmNetworkFailure(message: "HTTP 503")
            }
        }
        await fulfillment(of: [firstAttempt], timeout: 1)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls, 1)
    }

    func testExhaustionPropagatesSecondError() async {
        var calls = 0
        do {
            let _: String = try await ServiceRequestRetry.perform {
                calls += 1
                throw MemoEchoError.llmNetworkFailure(message: calls == 1 ? "HTTP 503" : "HTTP 502")
            }
            XCTFail("Expected failure")
        } catch { XCTAssertEqual(error as? MemoEchoError, .llmNetworkFailure(message: "HTTP 502")) }
        XCTAssertEqual(calls, 2)
    }

    func testLLMRetryRebuildsRequestAfterWindowContextIsDisabled() async throws {
        let preference = RetryContextPreference()
        let network = RetryContextNetwork(preference: preference)
        let provider = LLMProvider(baseURL: "https://example.invalid", apiKey: "synthetic", model: "test",
            omitThinkingParameter: true, windowContextEnabled: { preference.enabled },
            requestSender: { try await network.send($0) })
        let context = WindowContextService.buildSnapshot(from: .init(selectedText: "SYNTHETIC_CONTEXT")).snapshot
        let checkpoint = SessionRecoveryCheckpoint(transcripts: ["合成转写"], mode: .polish, language: .english,
            asrPlatform: .openAICompatibleASR, target: nil, context: context)
        let worker = SessionRecoveryProcessor(recognize: { _ in XCTFail("ASR already completed"); return "" },
            polish: { transcripts, context in try await provider.polish(text: transcripts.joined(), context: context) },
            translate: { _, _, _ in XCTFail("No translation"); return "" })
        let text = try await worker.process(checkpoint, shouldContinue: { true }, onStage: { _ in })
        let bodies = await network.bodies
        XCTAssertEqual(text, "合成结果")
        XCTAssertEqual(bodies.count, 2)
        XCTAssertTrue(bodies[0].contains("SYNTHETIC_CONTEXT"))
        XCTAssertFalse(bodies[1].contains("SYNTHETIC_CONTEXT"))
    }

    func testHTTPRetryAfterDelaysTheActualSecondSend() async throws {
        for status in [429, 503] {
            let network = RetryAfterNetwork(status: status)
            let provider = LLMProvider(baseURL: "https://example.invalid", apiKey: "synthetic", model: "test",
                omitThinkingParameter: true, requestSender: { try await network.send($0) })
            _ = try await ServiceRequestRetry.perform { try await provider.polish(text: "合成转写") }
            let sends = await network.sends
            XCTAssertEqual(sends.count, 2)
            XCTAssertGreaterThanOrEqual(sends[0].duration(to: sends[1]), .seconds(1))
        }
    }

    func testASRRetryAlsoHonorsRetryAfter() async throws {
        let network = RetryAfterNetwork(status: 429)
        let provider = OpenAICompatibleASRProvider(config: .init(baseURL: "https://example.invalid",
            apiKey: "synthetic", model: "test"), httpClient: network)
        let result = try await ServiceRequestRetry.perform {
            try await provider.recognize(audioData: Data([0, 1]), timeout: 15)
        }
        let sends = await network.sends
        XCTAssertEqual(result.text, "合成结果")
        XCTAssertEqual(sends.count, 2)
        XCTAssertGreaterThanOrEqual(sends[0].duration(to: sends[1]), .seconds(1))
    }
}

@MainActor
private final class RetryContextPreference {
    var enabled = true
    func disable() { enabled = false }
}

private actor RetryContextNetwork {
    let preference: RetryContextPreference
    private(set) var bodies: [String] = []
    init(preference: RetryContextPreference) { self.preference = preference }
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        bodies.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
        if bodies.count == 1 {
            await preference.disable()
            throw URLError(.networkConnectionLost)
        }
        let content = #"{"mode":"plain_text","text":"合成结果","correction_applied":false}"#
        let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private actor RetryAfterNetwork: OpenAIASRHTTPClient {
    let status: Int
    private(set) var sends: [ContinuousClock.Instant] = []
    init(status: Int) { self.status = status }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) { try await send(request) }
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        sends.append(.now)
        if sends.count == 1 {
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Retry-After": "1"])!)
        }
        let content = #"{"mode":"plain_text","text":"合成结果","correction_applied":false}"#
        return (try JSONSerialization.data(withJSONObject: ["text": "合成结果", "choices": [["message": ["content": content]]]]),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
