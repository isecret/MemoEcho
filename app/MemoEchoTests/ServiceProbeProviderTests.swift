import XCTest
@testable import MemoEcho

final class ServiceProbeProviderTests: XCTestCase {
    func testVoicedFixtureIsValidAndRejectsSilentOrMalformedLocalResources() throws {
        try ASRValidationAudio.validate(ASRValidationAudio.load())
        let silence = WAVAudioEncoder.encodePCM16(pcmData: Data(repeating: 0, count: 3_200), sampleRate: 16_000, channels: 1)
        for data in [Data(), Data([1, 2, 3]), silence] {
            XCTAssertThrowsError(try ASRValidationAudio.validate(data)) {
                XCTAssertEqual(($0 as? ServiceProbeFailure)?.kind, .localFixture)
            }
        }
    }

    func testTencentValidationUsesVoicedFixtureWithoutUserHotwords() async throws {
        let client = ProbeHTTPClient(replies: [.init(body: #"{"Response":{"Result":"合成测试"}}"#)])
        let provider = TencentSentenceASRProvider(secretId: "synthetic", secretKey: "synthetic",
            hotwords: ASRHotwords(terms: ["PRIVATE_TERM"], platform: .tencentCloudSentence), httpClient: client)
        try await provider.validateCredentials()
        let requests = await client.requests
        let body = try object(XCTUnwrap(requests.first?.httpBody))
        XCTAssertNil(body["HotwordList"])
        let encoded = try XCTUnwrap(body["Data"] as? String)
        XCTAssertEqual(Data(base64Encoded: encoded), try ASRValidationAudio.load())
    }

    func testAliyunValidationRequiresRecognitionAfterTokenAndCountsOnlyInference() async throws {
        let client = ProbeHTTPClient(replies: [.init(body: #"{"Token":{"Id":"synthetic-token"}}"#),
            .init(body: #"{"status":20000000,"result":"合成测试"}"#)])
        let provider = AliyunSentenceASRProvider(accessKeyId: "synthetic", accessKeySecret: "synthetic",
            appKey: "synthetic", httpClient: client)
        let budget = ServiceProbeBudget(maximumRequests: 1)
        try await ServiceProbeContext.$budget.withValue(budget) { try await provider.validateCredentials() }
        let requests = await client.requests
        let used = await budget.requestsUsed
        XCTAssertEqual(used, 1)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertEqual(requests[1].url?.path, "/stream/v1/asr")
        XCTAssertEqual(requests[1].httpBody, try ASRValidationAudio.load())
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "X-NLS-Token"), "synthetic-token")
    }

    func testSentenceValidationCannotPassWithEmptyVoicedResponse() async throws {
        let tencent = TencentSentenceASRProvider(secretId: "synthetic", secretKey: "synthetic",
            httpClient: ProbeHTTPClient(replies: [.init(body: #"{"Response":{"Result":""}}"#)]))
        let aliyun = AliyunSentenceASRProvider(accessKeyId: "synthetic", accessKeySecret: "synthetic", appKey: "synthetic",
            httpClient: ProbeHTTPClient(replies: [.init(body: #"{"Token":{"Id":"synthetic"}}"#),
                .init(body: #"{"status":20000000,"result":""}"#)]))
        for provider in [tencent as any CloudASRValidating, aliyun as any CloudASRValidating] {
            do {
                try await provider.validateCredentials()
                XCTFail("A token or empty voiced transcription cannot prove readiness")
            } catch {
                XCTAssertEqual(ServiceProbeFailure.classify(error).kind, .invalidResponse)
            }
        }
    }

    func testLLMPolishProbeUsesFixedInputAndNoPrivateDictionaryOrContextPreference() async throws {
        let client = ProbeHTTPClient(replies: [.init(body: Self.polishResponse)])
        let provider = LLMProvider(baseURL: "https://example.invalid/v1", apiKey: "synthetic", model: "test",
            omitThinkingParameter: true,
            dictionaryTerms: [.init(term: "PRIVATE_TERM", pronunciationHint: "PRIVATE_HINT")],
            windowContextEnabled: { XCTFail("Probes must not read window context settings"); return true },
            requestSender: { try await client.data(for: $0) })
        try await provider.validateConfiguration(purpose: .polish)
        let requests = await client.requests
        let body = try object(XCTUnwrap(requests.first?.httpBody))
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages[0]["content"], LLMProvider.systemPrompt(terms: []))
        XCTAssertEqual(messages[1]["content"], ValidationFixture.text)
        XCTAssertFalse(String(decoding: requests[0].httpBody!, as: UTF8.self).contains("PRIVATE_"))
    }

    func testLLMTranslationProbeUsesTranslationPromptAndFixedTarget() async throws {
        let client = ProbeHTTPClient(replies: [.init(body: #"{"choices":[{"message":{"content":"Meet tomorrow at three."}}]}"#)])
        let provider = makeLLM(client: client)
        try await provider.validateConfiguration(purpose: .translation)
        let requests = await client.requests
        let body = try object(XCTUnwrap(requests.first?.httpBody))
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages[0]["content"], LLMProvider.translateSystemPrompt(targetLanguage: .english, context: nil))
        XCTAssertTrue(messages[1]["content"]?.contains(ValidationFixture.text) == true)
        XCTAssertNil(body["thinking"])
    }

    @MainActor
    func testTranslationProbeThinkingFallbackPreservesPrivacyAndValidationMetrics() async throws {
        let client = ProbeHTTPClient(replies: [
            .init(status: 400, body: #"{"error":{"message":"***.type `disabled` is not supported by this model"}}"#),
            .init(body: #"{"choices":[{"message":{"content":"Meet tomorrow at three."}}]}"#)
        ])
        let metrics = ProbeMetricsRecorder()
        var cacheWrites = 0
        let provider = LLMProvider(baseURL: "https://example.invalid/v1", apiKey: "synthetic", model: "test",
            omitThinkingParameter: false,
            dictionaryTerms: [.init(term: "PRIVATE_TERM", pronunciationHint: "PRIVATE_HINT")],
            onThinkingUnsupported: { cacheWrites += 1 }, onRequestMetrics: { metrics.append($0) },
            windowContextEnabled: { XCTFail("Probes must not read window context settings"); return true },
            requestSender: { try await client.data(for: $0) })
        let budget = ServiceProbeBudget(maximumRequests: 2)
        try await ServiceProbeContext.$budget.withValue(budget) {
            try await provider.validateConfiguration(purpose: .translation)
        }
        let requests = await client.requests
        let used = await budget.requestsUsed
        XCTAssertEqual(used, 2)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(cacheWrites, 1)
        XCTAssertEqual(metrics.values.map(\.purpose), [.validation, .validation])
        XCTAssertEqual(metrics.values.map(\.thinkingDisabled), [true, false])
        for request in requests {
            let body = try object(XCTUnwrap(request.httpBody))
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            XCTAssertEqual(messages[0]["content"], LLMProvider.translateSystemPrompt(targetLanguage: .english, context: nil))
            XCTAssertTrue(messages[1]["content"]?.contains(ValidationFixture.text) == true)
            XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains("PRIVATE_"))
        }
        XCTAssertEqual(metrics.values.map(\.contextCharacters), [0, 0])
        XCTAssertEqual(metrics.values.map(\.dictionaryTerms), [0, 0])
    }

    func testTranslationProbeThinkingFallbackCannotExceedBudget() async throws {
        let client = ProbeHTTPClient(replies: [
            .init(status: 400, body: #"{"error":{"message":"unsupported thinking"}}"#),
            .init(body: #"{"choices":[{"message":{"content":"Meet tomorrow at three."}}]}"#)
        ])
        let provider = makeLLM(client: client, omitThinking: false)
        let budget = ServiceProbeBudget(maximumRequests: 1)
        do {
            try await ServiceProbeContext.$budget.withValue(budget) {
                try await provider.validateConfiguration(purpose: .translation)
            }
            XCTFail("Fallback must use the same request budget")
        } catch { XCTAssertEqual((error as? ServiceProbeFailure)?.kind, .budgetExhausted) }
        let requests = await client.requests
        let used = await budget.requestsUsed
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(used, 1)
    }

    func testLLMProbesRejectWrongPolishStructureAndEmptyTranslation() async throws {
        for purpose in [LLMValidationPurpose.polish, .translation] {
            let body = purpose == .polish
                ? #"{"choices":[{"message":{"content":"ok"}}]}"#
                : #"{"choices":[{"message":{"content":" "}}]}"#
            let provider = makeLLM(client: ProbeHTTPClient(replies: [.init(body: body)]))
            do { try await provider.validateConfiguration(purpose: purpose); XCTFail("Invalid response must fail") }
            catch { XCTAssertEqual(ServiceProbeFailure.classify(error).kind, .invalidResponse) }
        }
    }

    func testThinkingFallbackConsumesSameThreeRequestBudgetAcrossAttempts() async throws {
        let client = ProbeHTTPClient(replies: [
            .init(status: 400, body: #"{"error":{"message":"unsupported thinking"}}"#),
            .init(status: 503, body: "private response"),
            .init(status: 503, body: "private response"),
            .init(body: Self.polishResponse)
        ])
        let provider = makeLLM(client: client, omitThinking: false)
        let budget = ServiceProbeBudget(maximumRequests: 3)
        await ServiceProbeContext.$budget.withValue(budget) {
            do { try await provider.validateConfiguration(); XCTFail("503 must fail this attempt") }
            catch { XCTAssertEqual((error as? ServiceProbeFailure)?.kind, .transient) }
            do { try await provider.validateConfiguration(); XCTFail("503 must fail this attempt") }
            catch { XCTAssertEqual((error as? ServiceProbeFailure)?.kind, .transient) }
            do { try await provider.validateConfiguration(); XCTFail("Fourth send must be denied") }
            catch { XCTAssertEqual((error as? ServiceProbeFailure)?.kind, .budgetExhausted) }
        }
        let requests = await client.requests
        let used = await budget.requestsUsed
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(used, 3)
        XCTAssertNotNil(try object(requests[0].httpBody!)["thinking"])
        XCTAssertNil(try object(requests[1].httpBody!)["thinking"])
        XCTAssertNil(try object(requests[2].httpBody!)["thinking"])
    }

    func testHTTPProbeClassificationAndRetryAfterArePreservedWithoutServerText() async throws {
        for (status, code, expected) in [
            (429, "rate_limit", ServiceProbeFailure.Kind.transient),
            (503, "busy", .transient), (401, "unauthorized", .confirmedBlocker),
            (400, "model_not_found", .confirmedBlocker), (400, "bad_content", .invalidResponse),
            (404, "gateway", .invalidResponse)
        ] {
            let client = ProbeHTTPClient(replies: [.init(status: status,
                body: "{\"error\":{\"code\":\"\(code)\",\"message\":\"PRIVATE_RESPONSE\"}}",
                headers: ["Retry-After": "17"])])
            let provider = makeLLM(client: client)
            do {
                try await ServiceProbeContext.$budget.withValue(ServiceProbeBudget()) { try await provider.validateConfiguration() }
                XCTFail("HTTP error must fail")
            } catch {
                let failure = try XCTUnwrap(error as? ServiceProbeFailure)
                XCTAssertEqual(failure.kind, expected)
                XCTAssertEqual(failure.httpStatus, status)
                XCTAssertEqual(failure.retryAfter, 17)
                XCTAssertFalse(failure.message.contains("PRIVATE_RESPONSE"))
            }
        }
    }

    func testRetryAfterHTTPDateAndInvalidValues() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(ServiceProbeFailure.retryDelay("Thu, 01 Jan 1970 00:01:00 GMT", now: now), 60)
        XCTAssertEqual(ServiceProbeFailure.retryDelay("Thu, 01 Jan 1970 00:01:00 GMT", now: now.addingTimeInterval(120)), 0)
        for value in ["-1", "NaN", "invalid"] { XCTAssertNil(ServiceProbeFailure.retryDelay(value)) }
    }

    func testOnlyAllowlistedNetworkAndHTTPFailuresAreRetried() throws {
        for code in [URLError.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet] {
            XCTAssertEqual(ServiceProbeFailure.classify(URLError(code)).kind, .transient)
        }
        for code in [URLError.serverCertificateUntrusted, .secureConnectionFailed, .cannotFindHost, .unknown] {
            XCTAssertEqual(ServiceProbeFailure.classify(URLError(code)).kind, .invalidResponse)
        }
        for status in [501, 505] {
            let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://example.invalid")!, statusCode: status,
                httpVersion: nil, headerFields: nil))
            XCTAssertEqual(ServiceProbeFailure.http(response)?.kind, .invalidResponse)
        }
        let limited = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://example.invalid")!, statusCode: 429,
            httpVersion: nil, headerFields: nil))
        XCTAssertEqual(ServiceProbeFailure.http(limited, data: Data(#"{"error":{"code":"insufficient_quota"}}"#.utf8))?.kind,
                       .confirmedBlocker)
    }

    func testUnsupportedNonThinkingParameterDoesNotTriggerProbeFallback() async throws {
        let client = ProbeHTTPClient(replies: [.init(status: 400, body: #"{"error":{"message":"unsupported input format"}}"#)])
        let provider = makeLLM(client: client, omitThinking: false)
        do {
            try await ServiceProbeContext.$budget.withValue(ServiceProbeBudget()) { try await provider.validateConfiguration() }
            XCTFail("Unrelated unsupported input must fail")
        } catch { XCTAssertEqual((error as? ServiceProbeFailure)?.kind, .invalidResponse) }
        let requests = await client.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testThinkingFallbackCannotBypassServerRetryAfter() async throws {
        for purpose in [LLMValidationPurpose.polish, .translation] {
            let client = ProbeHTTPClient(replies: [.init(status: 400, body: #"{"error":{"message":"unsupported thinking"}}"#,
                                                       headers: ["Retry-After": "30"])])
            let provider = makeLLM(client: client, omitThinking: false)
            do {
                try await ServiceProbeContext.$budget.withValue(ServiceProbeBudget()) { try await provider.validateConfiguration(purpose: purpose) }
                XCTFail("Compatibility fallback must respect the server deadline")
            } catch { XCTAssertEqual((error as? ServiceProbeFailure)?.retryAfter, 30) }
            let requests = await client.requests
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testProviderCancellationIsNeverConvertedToServiceFailure() async throws {
        let provider = LLMProvider(baseURL: "https://example.invalid", apiKey: "synthetic", model: "test",
            omitThinkingParameter: true, requestSender: { _ in throw URLError(.cancelled) })
        for purpose in [LLMValidationPurpose.polish, .translation] {
            do {
                try await ServiceProbeContext.$budget.withValue(ServiceProbeBudget()) {
                    try await provider.validateConfiguration(purpose: purpose)
                }
                XCTFail("Cancelled request must throw")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
    }

    func testBusinessRequestKeepsExistingErrorSemanticsWithoutProbeContext() async throws {
        let provider = makeLLM(client: ProbeHTTPClient(replies: [.init(status: 503)]))
        do { _ = try await provider.polish(text: "合成测试"); XCTFail("Expected failure") }
        catch { XCTAssertEqual(error as? MemoEchoError, .llmNetworkFailure(message: "HTTP 503")) }
    }

    func testRealtimeConnectConsumesOneRequestAndFramesDoNotConsumeMore() async throws {
        let transport = ProbeRealtimeTransport()
        let session = RealtimeCloudASRSession(configuration: .xunfeiIAT(appID: "synthetic", apiKey: "synthetic", apiSecret: "synthetic"),
            transport: transport, requestBuilder: { _ in URLRequest(url: URL(string: "wss://example.invalid")!) })
        let budget = ServiceProbeBudget(maximumRequests: 1)
        try await ServiceProbeContext.$budget.withValue(budget) {
            try await session.connect()
            try await session.send(Data(repeating: 0, count: 1_280))
            try await session.send(Data(repeating: 0, count: 1_280))
            await session.cancel()
        }
        let used = await budget.requestsUsed
        let sends = await transport.sendCount
        XCTAssertEqual(used, 1)
        XCTAssertEqual(sends, 2)
    }

    func testRealtimeConnectionPreservesStructuredProbeFailureAndCloses() async throws {
        let failure = ServiceProbeFailure(kind: .transient, message: "服务限流", retryAfter: 19, httpStatus: 429)
        let transport = ProbeRealtimeTransport(connectFailure: failure)
        let session = RealtimeCloudASRSession(configuration: .xunfeiIAT(appID: "synthetic", apiKey: "synthetic", apiSecret: "synthetic"),
            transport: transport, requestBuilder: { _ in URLRequest(url: URL(string: "wss://example.invalid")!) })
        do {
            try await ServiceProbeContext.$budget.withValue(ServiceProbeBudget()) { try await session.connect() }
            XCTFail("Expected connection failure")
        } catch { XCTAssertEqual(error as? ServiceProbeFailure, failure) }
        let closed = await transport.closed
        XCTAssertTrue(closed)
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func makeLLM(client: ProbeHTTPClient, omitThinking: Bool = true) -> LLMProvider {
        LLMProvider(baseURL: "https://example.invalid/v1", apiKey: "synthetic", model: "test",
            omitThinkingParameter: omitThinking, requestSender: { try await client.data(for: $0) })
    }

    private static let polishResponse = #"{"choices":[{"message":{"content":"{\"mode\":\"plain_text\",\"text\":\"明天下午三点开会。\",\"correction_applied\":false}"}}]}"#
}

private final class ProbeMetricsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [LLMRequestMetrics] = []
    var values: [LLMRequestMetrics] { lock.withLock { stored } }
    func append(_ value: LLMRequestMetrics) { lock.withLock { stored.append(value) } }
}

private actor ProbeHTTPClient: OpenAIASRHTTPClient {
    struct Reply: Sendable {
        var status = 200
        var body = "{}"
        var headers: [String: String] = [:]
    }
    var replies: [Reply]
    private(set) var requests: [URLRequest] = []
    init(replies: [Reply]) { self.replies = replies }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        let reply = replies.removeFirst()
        return (Data(reply.body.utf8), HTTPURLResponse(url: request.url!, statusCode: reply.status,
            httpVersion: nil, headerFields: reply.headers)!)
    }
}

private actor ProbeRealtimeTransport: RealtimeWebSocketTransport {
    let connectFailure: ServiceProbeFailure?
    private(set) var sendCount = 0
    private(set) var closed = false
    init(connectFailure: ServiceProbeFailure? = nil) { self.connectFailure = connectFailure }
    func connect(_ request: URLRequest) async throws { if let connectFailure { throw connectFailure } }
    func send(_ message: RealtimeWebSocketMessage) async throws { sendCount += 1 }
    func receive() async throws -> RealtimeWebSocketMessage {
        while !closed { try await Task.sleep(for: .milliseconds(10)) }
        throw CancellationError()
    }
    func close() async { closed = true }
}
