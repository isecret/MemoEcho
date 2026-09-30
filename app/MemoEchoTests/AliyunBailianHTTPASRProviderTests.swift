import XCTest
@testable import MemoEcho

final class AliyunBailianHTTPASRProviderTests: XCTestCase {
    func testRequestMatchesDashScopeHTTPContract() async throws {
        let client = BailianHTTPTestClient(body: #"{"output":{"text":" 完整测试结果 ","sentence":{"sentence_end":true}}}"#)
        let provider = AliyunBailianHTTPASRProvider(config: .init(apiKey: " synthetic-key ", model: " custom-model "), httpClient: client)
        let audio = WAVAudioEncoder.encodePCM16(pcmData: Data(repeating: 0, count: 1600), sampleRate: 16000, channels: 1)
        let result = try await provider.recognize(audioData: audio, timeout: 72)
        XCTAssertEqual(result.text, "完整测试结果")
        let captured = await client.request
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.url?.absoluteString, "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 72)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-DashScope-SSE"), "disable")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["model", "input", "parameters"])
        XCTAssertEqual(body["model"] as? String, "custom-model")
        XCTAssertEqual(body["parameters"] as? [String: String], ["format": "wav", "sample_rate": "16000"])
        let input = try XCTUnwrap(body["input"] as? [String: Any])
        let messages = try XCTUnwrap(input["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        let content = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content[0]["type"] as? String, "input_audio")
        let encoded = try XCTUnwrap(content[0]["input_audio"] as? [String: String])
        XCTAssertEqual(encoded["data"], "data:audio/wav;base64," + audio.base64EncodedString())
    }

    func testPartialErrorAndWrongProtocolCannotReturnText() async throws {
        for body in ["{}", #"{"output":{"sentence":{"text":"last sentence only"}}}"#,
                     #"{"output":{"text":"partial","sentence":{"sentence_end":false}}}"#,
                     #"{"code":"InvalidApiKey","message":"private-error","output":{"text":"ignored"}}"#,
                     #"{"choices":[{"message":{"content":"wrong protocol"}}]}"#] {
            let provider = AliyunBailianHTTPASRProvider(config: .init(apiKey: "synthetic"), httpClient: BailianHTTPTestClient(body: body))
            do { _ = try await provider.recognize(audioData: Data([1])); XCTFail("Expected rejection") }
            catch MemoEchoError.cloudASRInvalidResponse(let detail) { XCTAssertFalse(detail.contains("private-error")) }
        }
    }

    func testEmptyResponseCannotValidate() async throws {
        let provider = AliyunBailianHTTPASRProvider(config: .init(apiKey: "synthetic"), httpClient: BailianHTTPTestClient(body: #"{"output":{"text":" "}}"#))
        do { try await provider.validateCredentials(); XCTFail() }
        catch MemoEchoError.cloudASRInvalidResponse { }
    }

    func testHTTPFailuresAreSafeAndNeverRetried() async throws {
        for status in [307, 401, 403, 404, 429, 500] {
            let client = BailianHTTPTestClient(body: "private-error", status: status)
            let provider = AliyunBailianHTTPASRProvider(config: .init(apiKey: "synthetic"), httpClient: client)
            do { _ = try await provider.recognize(audioData: Data([1])); XCTFail() }
            catch let error as MemoEchoError {
                XCTAssertFalse(error.userMessage.contains("private-error"))
                if status == 401 || status == 403 { XCTAssertEqual(error, .cloudASRAuthenticationFailure) }
            }
            let calls = await client.calls
            XCTAssertEqual(calls, 1)
        }
    }

    func testIncompleteConfigNeverReachesNetwork() async throws {
        let client = BailianHTTPTestClient(body: "{}")
        let provider = AliyunBailianHTTPASRProvider(config: .init(), httpClient: client)
        do { _ = try await provider.recognize(audioData: Data([1])); XCTFail() }
        catch MemoEchoError.cloudASRConfigurationIncomplete { }
        let calls = await client.calls
        XCTAssertEqual(calls, 0)
    }

    func testTimeoutAndCancellationPropagate() async throws {
        for code in [URLError.Code.timedOut, .cancelled] {
            let provider = AliyunBailianHTTPASRProvider(config: .init(apiKey: "synthetic"), httpClient: BailianHTTPFailingClient(code: code))
            do { _ = try await provider.recognize(audioData: Data([1])); XCTFail() }
            catch is CancellationError { XCTAssertEqual(code, .cancelled) }
            catch MemoEchoError.cloudASRNetworkFailure(let message) { XCTAssertEqual(message, "asr_timeout") }
        }
    }

    func testHTTPConfigAcceptsCustomModelsAndCanonicalURLs() throws {
        for address in ["https://EXAMPLE.com/api/v1/", " https://example.com/api/v1/services/aigc/multimodal-generation/generation/ "] {
            var config = AliyunBailianHTTPASRConfig(baseURL: address, apiKey: "synthetic", model: "future-model")
            XCTAssertEqual(config.requestURL?.absoluteString, "https://example.com/api/v1/services/aigc/multimodal-generation/generation")
            XCTAssertTrue(config.isComplete)
            XCTAssertFalse(config.isReady)
            config.validationStatus = .verified
            config.lastValidationError = "runtime-only"
            let data = try JSONEncoder().encode(config)
            let restored = try JSONDecoder().decode(AliyunBailianHTTPASRConfig.self, from: data)
            XCTAssertEqual(restored.validationStatus, .unvalidated)
            XCTAssertNil(restored.lastValidationError)
        }
        for address in ["wss://example.com/api-ws/v1/inference", "http://example.com/api/v1", "https://user:secret@example.com/api/v1", "https://example.com/api/v1?key=secret", "https://example.com/v1"] {
            XCTAssertFalse(AliyunBailianHTTPASRConfig(baseURL: address, apiKey: "synthetic").isComplete)
        }
        XCTAssertFalse(AliyunBailianHTTPASRConfig(apiKey: "synthetic", model: " \n ").isComplete)
        XCTAssertFalse(AliyunBailianHTTPASRConfig(apiKey: "synthetic\nInjected: value").isComplete)
    }
}

private actor BailianHTTPTestClient: OpenAIASRHTTPClient {
    let body: String
    let status: Int
    private(set) var request: URLRequest?
    private(set) var calls = 0
    init(body: String, status: Int = 200) { self.body = body; self.status = status }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.request = request
        calls += 1
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private struct BailianHTTPFailingClient: OpenAIASRHTTPClient {
    let code: URLError.Code
    func data(for request: URLRequest) async throws -> (Data, URLResponse) { throw URLError(code) }
}
