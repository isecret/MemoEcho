import Foundation
import XCTest
@testable import MemoEcho

final class VolcengineSentenceASRProviderTests: XCTestCase {
    func testHistoricalFileRequestAndCompleteTranscript() async throws {
        let client = FileFlashTestClient(body: #"{"result":{"text":"  合成测试结果  "}}"#,
                                         headers: ["X-Api-Status-Code": "20000000", "X-Tt-Logid": "synthetic-log-id"])
        let provider = VolcengineSentenceASRProvider(apiKey: " synthetic-key ", httpClient: client)
        let audio = WAVAudioEncoder.encodePCM16(pcmData: Data(repeating: 0, count: 1600), sampleRate: 16000, channels: 1)
        let result = try await provider.recognize(audioData: audio, timeout: 72)
        XCTAssertEqual(result.text, "合成测试结果")
        XCTAssertEqual(result.requestId, "synthetic-log-id")
        let captured = await client.request
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.url?.absoluteString, "https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 72)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), "synthetic-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Resource-Id"), "volc.bigasr.auc_turbo")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Sequence"), "-1")
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(request.value(forHTTPHeaderField: "X-Api-Request-Id"))))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["audio"] as? [String: String], ["data": audio.base64EncodedString()])
        XCTAssertEqual(body["request"] as? [String: String], ["model_name": "bigmodel"])
        XCTAssertEqual(body["user"] as? [String: String], ["uid": "memoecho"])
    }

    func testInvalidCredentialsAndEmptyAudioNeverReachNetwork() async throws {
        let client = FileFlashTestClient()
        for key in ["", " \n ", "synthetic\nInjected: value"] {
            let provider = VolcengineSentenceASRProvider(apiKey: key, httpClient: client)
            do { _ = try await provider.recognize(audioData: Data([1])); XCTFail("Expected incomplete credentials") }
            catch MemoEchoError.cloudASRConfigurationIncomplete { }
        }
        do {
            _ = try await VolcengineSentenceASRProvider(apiKey: "synthetic", httpClient: client).recognize(audioData: Data())
            XCTFail("Expected empty audio")
        } catch MemoEchoError.asrEmptyAudio { }
        let calls = await client.calls
        XCTAssertEqual(calls, 0)
    }

    func testHTTPFailuresNeverExposeResponseBodyOrRetry() async throws {
        for status in [307, 401, 403, 429, 500] {
            let client = FileFlashTestClient(body: "private-response-sentinel", status: status)
            do {
                _ = try await VolcengineSentenceASRProvider(apiKey: "synthetic", httpClient: client).recognize(audioData: Data([1]))
                XCTFail("Expected HTTP failure")
            } catch let error as MemoEchoError {
                XCTAssertFalse(error.userMessage.contains("private-response-sentinel"))
                if status == 401 || status == 403 { XCTAssertEqual(error, .cloudASRAuthenticationFailure) }
            }
            let calls = await client.calls
            XCTAssertEqual(calls, 1)
        }
    }

    func testAPIErrorCannotReturnTextOrExposeMessage() async throws {
        for code in ["45000001", "50000000", "private-header-sentinel"] {
            let client = FileFlashTestClient(body: #"{"result":{"text":"must not escape"}}"#,
                headers: ["X-Api-Status-Code": code, "X-Api-Message": "private-message-sentinel"])
            do {
                _ = try await VolcengineSentenceASRProvider(apiKey: "synthetic", httpClient: client).recognize(audioData: Data([1]))
                XCTFail("Expected service failure")
            } catch MemoEchoError.cloudASRInvalidResponse(let detail) {
                XCTAssertFalse(detail.contains("sentinel"))
                XCTAssertFalse(detail.contains("must not escape"))
            }
        }
    }

    func testAPIAuthenticationAndEmptyAudioStatuses() async throws {
        for code in ["401", "403", "20000003", "45000002"] {
            let client = FileFlashTestClient(headers: ["X-Api-Status-Code": code])
            do {
                _ = try await VolcengineSentenceASRProvider(apiKey: "synthetic", httpClient: client).recognize(audioData: Data([1]))
                XCTFail("Expected service status failure")
            } catch let error as MemoEchoError {
                XCTAssertEqual(error, code == "401" || code == "403" ? .cloudASRAuthenticationFailure : .cloudASREmptyResponse)
            }
        }
    }

    func testMalformedAndEmptyResultsCannotReturnTranscript() async throws {
        for body in ["private-response-sentinel", "{}", #"{"result":[]}"#,
                     #"{"result":{}}"#, #"{"result":{"text":"  "}}"#] {
            let client = FileFlashTestClient(body: body)
            do {
                _ = try await VolcengineSentenceASRProvider(apiKey: "synthetic", httpClient: client).recognize(audioData: Data([1]))
                XCTFail("Expected invalid or empty result")
            } catch let error as MemoEchoError {
                XCTAssertFalse(error.userMessage.contains("private-response-sentinel"))
                switch error {
                case .cloudASRInvalidResponse, .cloudASREmptyResponse: break
                default: XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }

    func testValidationUploadsProvidedSyntheticAudioAndRequiresText() async throws {
        let audio = WAVAudioEncoder.encodePCM16(pcmData: Data([1, 0, 2, 0]), sampleRate: 16000, channels: 1)
        for text in ["测试", " "] {
            let client = FileFlashTestClient(body: try String(decoding: JSONSerialization.data(withJSONObject: ["result": ["text": text]]), as: UTF8.self))
            let provider = VolcengineSentenceASRProvider(apiKey: "synthetic", httpClient: client, validationAudioLoader: { audio })
            if text == "测试" {
                try await provider.validateCredentials()
            } else {
                do { try await provider.validateCredentials(); XCTFail("Empty text must not validate") }
                catch MemoEchoError.cloudASRInvalidResponse { }
            }
            let captured = await client.request
            let request = try XCTUnwrap(captured)
            XCTAssertEqual(request.timeoutInterval, 15)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(body["audio"] as? [String: String], ["data": audio.base64EncodedString()])
        }
    }

    func testTimeoutAndCancellationRemainDistinct() async throws {
        for code in [URLError.Code.timedOut, .cancelled] {
            let client = FileFlashTestClient(error: URLError(code))
            let provider = VolcengineSentenceASRProvider(apiKey: "synthetic", httpClient: client)
            do { _ = try await provider.recognize(audioData: Data([1])); XCTFail("Expected transport failure") }
            catch is CancellationError { XCTAssertEqual(code, .cancelled) }
            catch MemoEchoError.cloudASRNetworkFailure(let message) { XCTAssertEqual(message, "asr_timeout") }
        }
    }

    func testCancellationDiscardsLateSuccessfulResponse() async throws {
        let requestStarted = expectation(description: "HTTP request started")
        let client = FileFlashDelayedClient(onStart: { requestStarted.fulfill() })
        let provider = VolcengineSentenceASRProvider(apiKey: "synthetic", httpClient: client)
        let task = Task { try await provider.recognize(audioData: Data([1])) }
        await fulfillment(of: [requestStarted], timeout: 3)
        task.cancel()
        await client.release()
        do { _ = try await task.value; XCTFail("Cancelled results must not be returned") }
        catch is CancellationError { }
    }
}

private actor FileFlashTestClient: OpenAIASRHTTPClient {
    let body: String
    let status: Int
    let headers: [String: String]
    let error: URLError?
    var request: URLRequest?
    var calls = 0

    init(body: String = #"{"result":{"text":"synthetic"}}"#, status: Int = 200,
         headers: [String: String] = [:], error: URLError? = nil) {
        self.body = body
        self.status = status
        self.headers = headers
        self.error = error
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.request = request
        calls += 1
        if let error { throw error }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}

private actor FileFlashDelayedClient: OpenAIASRHTTPClient {
    private let onStart: @Sendable () -> Void
    init(onStart: @escaping @Sendable () -> Void) { self.onStart = onStart }
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        onStart()
        if !released { await withCheckedContinuation { continuation = $0 } }
        return (Data(#"{"result":{"text":"late result"}}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
