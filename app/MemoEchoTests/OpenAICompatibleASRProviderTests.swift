import XCTest
@testable import MemoEcho

final class OpenAICompatibleASRProviderTests: XCTestCase {
    private func config(_ format: OpenAIASRFormat = .audioTranscriptions, key: String = "") -> OpenAICompatibleASRConfig {
        .init(apiFormat: format, baseURL: "http://localhost:8000/v1", apiKey: key, model: "test-asr")
    }

    func testMultipartPreservesBinaryAndOmitsEmptyAuthorization() async throws {
        let client = StubOpenAIASRClient(body: #"{"text":"  测试文本\n"}"#)
        let provider = OpenAICompatibleASRProvider(config: config(), httpClient: client)
        let audio = Data([0, 255, 13, 10, 128, 42])
        let result = try await provider.recognize(audioData: audio, timeout: 81.5)
        XCTAssertEqual(result.text, "测试文本")
        let recorded = await client.request
        let request = try XCTUnwrap(recorded)
        XCTAssertEqual(request.url?.path, "/v1/audio/transcriptions")
        XCTAssertEqual(request.timeoutInterval, 81.5)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        let boundary = try XCTUnwrap(contentType.components(separatedBy: "boundary=").last)
        let body = try XCTUnwrap(request.httpBody)
        var expected = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\ntest-asr\r\n".utf8)
        expected.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n".utf8))
        expected.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        expected.append(audio)
        expected.append(Data("\r\n--\(boundary)--\r\n".utf8))
        XCTAssertEqual(body, expected)
    }

    func testLegacyChatConfigurationFailsWithoutNetworkRequest() async throws {
        let client = StubOpenAIASRClient(body: "{}")
        let provider = OpenAICompatibleASRProvider(config: config(.chatCompletions), httpClient: client)
        do { _ = try await provider.recognize(audioData: Data([1])); XCTFail() }
        catch MemoEchoError.cloudASRInvalidResponse(let detail) {
            XCTAssertTrue(detail.contains("MiMo"))
            XCTAssertTrue(detail.contains("重新配置"))
        }
        let calls = await client.calls
        XCTAssertEqual(calls, 0)
    }

    func testRejectsInvalidAndChatResponses() async throws {
        let bodies = ["{}", "<html>error</html>", #"{"error":{"message":"private-error"},"text":"text"}"#,
                      #"{"text":null}"#, #"{"text":42}"#, #"{"choices":[{"message":{"content":"text"}}]}"#]
        for body in bodies {
            let provider = OpenAICompatibleASRProvider(config: config(), httpClient: StubOpenAIASRClient(body: body))
            do { _ = try await provider.recognize(audioData: Data([1])); XCTFail("Must reject malformed response") }
            catch MemoEchoError.cloudASRInvalidResponse(let detail) { XCTAssertFalse(detail.contains("private-error")) }
        }
    }

    func testEmptyTextFailsBothRecognitionAndCredentialValidation() async throws {
        let provider = OpenAICompatibleASRProvider(config: config(), httpClient: StubOpenAIASRClient(body: #"{"text":" \n "}"#))
        do { _ = try await provider.recognize(audioData: Data([1])); XCTFail() }
        catch let error as MemoEchoError { XCTAssertEqual(error, .cloudASREmptyResponse) }
        do { try await provider.validateCredentials(); XCTFail() }
        catch MemoEchoError.cloudASRInvalidResponse { }
    }

    func testHTTPFailuresAreSanitizedAndDoNotSwitchProtocol() async throws {
        for status in [302, 307, 401, 403, 404, 429, 500] {
            let client = StubOpenAIASRClient(body: "private-error", status: status)
            let provider = OpenAICompatibleASRProvider(config: config(), httpClient: client)
            do { _ = try await provider.recognize(audioData: Data([1])); XCTFail() }
            catch let error as MemoEchoError {
                XCTAssertFalse(error.userMessage.contains("private-error"))
                if [401, 403].contains(status) { XCTAssertEqual(error, .cloudASRAuthenticationFailure) }
            }
            let calls = await client.calls
            XCTAssertEqual(calls, 1)
        }
    }

    func testNetworkErrorsAreSanitizedAndCancellationPropagates() async throws {
        for code in [URLError.timedOut, .cannotConnectToHost, .notConnectedToInternet, .cancelled] {
            let client = StubOpenAIASRClient(body: "", error: URLError(code, userInfo: [NSLocalizedDescriptionKey: "private-address"]))
            let provider = OpenAICompatibleASRProvider(config: config(), httpClient: client)
            do { _ = try await provider.recognize(audioData: Data([1])); XCTFail() }
            catch is CancellationError { XCTAssertEqual(code, .cancelled) }
            catch let error as MemoEchoError {
                XCTAssertFalse(error.userMessage.contains("private-address"))
                if code == .notConnectedToInternet { XCTAssertTrue(error.userMessage.contains("本地网络")) }
            }
        }
    }

    func testIncompleteConfigurationAndEmptyAudioNeverReachNetwork() async throws {
        let client = StubOpenAIASRClient(body: "{}")
        for (connection, audio) in [(OpenAICompatibleASRConfig(), Data([1])), (config(), Data())] {
            let provider = OpenAICompatibleASRProvider(config: connection, httpClient: client)
            do { _ = try await provider.recognize(audioData: audio); XCTFail() }
            catch is MemoEchoError { }
        }
        let calls = await client.calls
        XCTAssertEqual(calls, 0)
    }

    func testCancelledTaskDiscardsLateSuccess() async throws {
        let client = SuspendedOpenAIASRClient()
        let provider = OpenAICompatibleASRProvider(config: config(), httpClient: client)
        let task = Task { try await provider.recognize(audioData: Data([1])) }
        await client.waitForStart()
        task.cancel()
        await client.finish()
        do { _ = try await task.value; XCTFail("Cancelled task must not publish success") }
        catch is CancellationError { }
    }

    func testRedirectDelegateDeclinesRedirect() async throws {
        let original = URL(string: "https://example.com/v1/audio/transcriptions")!
        let redirected = URLRequest(url: URL(string: "https://other.example/upload")!)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: original)
        let response = HTTPURLResponse(url: original, statusCode: 307, httpVersion: nil, headerFields: nil)!
        let accepted: URLRequest? = await withCheckedContinuation { continuation in
            OpenAIASRRedirectBlocker().urlSession(session, task: task, willPerformHTTPRedirection: response,
                newRequest: redirected, completionHandler: { continuation.resume(returning: $0) })
        }
        XCTAssertNil(accepted)
    }
}

private actor StubOpenAIASRClient: OpenAIASRHTTPClient {
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

private actor SuspendedOpenAIASRClient: OpenAIASRHTTPClient {
    private var continuation: CheckedContinuation<(Data, URLResponse), Never>?
    private var started: CheckedContinuation<Void, Never>?
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started?.resume(); started = nil
        }
    }
    func waitForStart() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish() {
        continuation?.resume(returning: (Data(#"{"text":"late success"}"#.utf8), HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!))
        continuation = nil
    }
}
