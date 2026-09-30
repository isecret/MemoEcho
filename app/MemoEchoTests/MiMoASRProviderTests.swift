import XCTest
@testable import MemoEcho

final class MiMoASRProviderTests: XCTestCase {
    func testSpeechRequestMatchesMiMoHTTPContract() async throws {
        let client = MiMoTestHTTPClient(body: #"{"choices":[{"finish_reason":"stop","message":{"content":" 测试转写 "}}]}"#)
        let provider = MiMoASRProvider(config: .init(apiKey: " synthetic-key "), httpClient: client)
        let audio = WAVAudioEncoder.encodePCM16(pcmData: Data(repeating: 0, count: 1600), sampleRate: 16000, channels: 1)
        let result = try await provider.recognize(audioData: audio, timeout: 72)
        XCTAssertEqual(result.text, "测试转写")
        let captured = await client.request
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.url?.absoluteString, "https://api.xiaomimimo.com/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 72)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["model", "messages", "stream"])
        XCTAssertEqual(body["model"] as? String, "mimo-v2.5-asr")
        XCTAssertEqual(body["stream"] as? Bool, false)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        let content = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content[0]["type"] as? String, "input_audio")
        let encoded = try XCTUnwrap(content[0]["input_audio"] as? [String: String])
        XCTAssertEqual(encoded["format"], "wav")
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(encoded["data"])), audio)
    }

    func testIncompleteOrTruncatedResponsesCannotPublishText() async throws {
        let bodies = ["{}", #"{"text":"wrong protocol"}"#, #"{"choices":[]}"#,
                      #"{"choices":[{"message":{"content":"no finish reason"}}]}"#,
                      #"{"error":{"message":"private-error"},"choices":[]}"#] +
            ["length", "content_filter", "tool_calls"].map {
                "{\"choices\":[{\"finish_reason\":\"\($0)\",\"message\":{\"content\":\"partial\"}}]}"
            }
        for body in bodies {
            let provider = MiMoASRProvider(config: .init(apiKey: "synthetic"), httpClient: MiMoTestHTTPClient(body: body))
            do { _ = try await provider.recognize(audioData: Data([1])); XCTFail() }
            catch MemoEchoError.cloudASRInvalidResponse(let detail) { XCTAssertFalse(detail.contains("private-error")) }
        }
    }

    func testEmptyTranscriptionCannotValidate() async throws {
        let client = MiMoTestHTTPClient(body: #"{"choices":[{"finish_reason":"stop","message":{"content":" "}}]}"#)
        let provider = MiMoASRProvider(config: .init(apiKey: "synthetic"), httpClient: client)
        do { _ = try await provider.recognize(audioData: Data([1])); XCTFail() }
        catch let error as MemoEchoError { XCTAssertEqual(error, .cloudASREmptyResponse) }
        do { try await provider.validateCredentials(); XCTFail() }
        catch MemoEchoError.cloudASRInvalidResponse { }
    }

    func testHTTPErrorDoesNotExposeBodyOrRetry() async throws {
        for status in [307, 401, 403, 404, 429, 500] {
            let client = MiMoTestHTTPClient(body: "private-error", status: status)
            let provider = MiMoASRProvider(config: .init(apiKey: "synthetic"), httpClient: client)
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
        let client = MiMoTestHTTPClient(body: "{}")
        let provider = MiMoASRProvider(config: .init(), httpClient: client)
        do { _ = try await provider.recognize(audioData: Data([1])); XCTFail() }
        catch let error as MemoEchoError { XCTAssertEqual(error, .cloudASRConfigurationIncomplete) }
        let calls = await client.calls
        XCTAssertEqual(calls, 0)
    }

    func testTimeoutAndCancellationRemainTyped() async throws {
        for code in [URLError.timedOut, .cancelled] {
            let provider = MiMoASRProvider(config: .init(apiKey: "synthetic"),
                                          httpClient: MiMoTestHTTPClient(body: "", error: URLError(code)))
            do { _ = try await provider.recognize(audioData: Data([1])); XCTFail() }
            catch is CancellationError { XCTAssertEqual(code, .cancelled) }
            catch let error as MemoEchoError { XCTAssertEqual(error, .cloudASRNetworkFailure(message: "asr_timeout")) }
        }
    }
}

private actor MiMoTestHTTPClient: OpenAIASRHTTPClient {
    let body: String
    let status: Int
    let error: URLError?
    private(set) var request: URLRequest?
    private(set) var calls = 0
    init(body: String, status: Int = 200, error: URLError? = nil) {
        self.body = body; self.status = status; self.error = error
    }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.request = request; calls += 1
        if let error { throw error }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
