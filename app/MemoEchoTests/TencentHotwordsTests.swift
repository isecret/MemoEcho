import CryptoKit
import XCTest
@testable import MemoEcho

final class TencentHotwordsTests: XCTestCase {
    func testSelectionLimitsAndSeparators() {
        for platform in [ASRPlatform.tencentCloudRealtime, .tencentCloudSentence] {
            let chinese = String(repeating: "中", count: 10)
            let english = String(repeating: "a", count: 30)
            let words = ASRHotwords(terms: [" ", " MemoEcho ", "memoecho", chinese, chinese + "中",
                english, english + "a", "中English", "a,b", "a|9", "a\nb"], platform: platform)
            XCTAssertEqual(words.terms, ["MemoEcho", chinese, english, "中English"])
            for count in [128, 129, 5000] {
                let selected = ASRHotwords(terms: ["invalid|9"] + (0..<count).map { "词\($0)" }, platform: platform)
                XCTAssertEqual(selected.terms.count, 128)
                XCTAssertEqual(selected.terms.last, "词127")
            }
            XCTAssertNil(ASRHotwords(terms: [], platform: platform).tencentList())
        }
    }

    func testRealtimeFactorySignsAndEncodesInlineList() async throws {
        for terms in [[], ["腾讯云", "A&B?=+%"]] {
            var config = ASRConfig()
            config.selectedPlatform = .tencentCloudRealtime
            config.tencentCloud.appID = "123"
            config.tencentCloud.secretId = "test-id"
            config.tencentCloud.secretKey = "test-key"
            let snapshot = ASRHotwords(terms: terms, platform: config.selectedPlatform)
            let request = try await RealtimeWireCodec.makeRequest(configuration:
                ASRProviderFactory.realtimeConfiguration(for: config, hotwords: snapshot))
            let url = try XCTUnwrap(request.url)
            let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            let params = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(params["hotword_list"], snapshot.tencentList())
            XCTAssertNil(params["hotword_id"])
            let raw = params.filter { $0.key != "signature" }.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: "&")
            XCTAssertEqual(params["signature"], RealtimeWireCodec.hmacSHA1("test-key", "asr.cloud.tencent.com/asr/v2/123?" + raw))
        }
    }

    func testSentenceSignsExactBodyAndReusesSnapshot() async throws {
        for terms in [[], ["腾讯云", "MemoEcho"]] {
            let client = TencentHotwordsClient()
            let snapshot = ASRHotwords(terms: terms, platform: .tencentCloudSentence)
            let provider = TencentSentenceASRProvider(secretId: "test-id", secretKey: "test-key", hotwords: snapshot, httpClient: client)
            for _ in 0..<2 {
                _ = try await provider.recognize(audioData: Data([1, 2]), timeout: 27)
                let captured = await client.request
                let request = try XCTUnwrap(captured)
                let data = try XCTUnwrap(request.httpBody)
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                XCTAssertEqual(body["HotwordList"] as? String, snapshot.tencentList())
                XCTAssertNil(body["HotwordId"])
                XCTAssertEqual(body["EngSerViceType"] as? String, "16k_zh-PY")
                XCTAssertEqual(request.timeoutInterval, 27)
                let timestamp = try XCTUnwrap(request.value(forHTTPHeaderField: "X-TC-Timestamp"))
                let auth = try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization"))
                let date = String(auth.split(separator: "/")[1])
                let scope = "\(date)/asr/tc3_request"
                let canonical = "POST\n/\n\ncontent-type:application/json\nhost:asr.tencentcloudapi.com\n\ncontent-type;host\n" + hash(data)
                let toSign = "TC3-HMAC-SHA256\n\(timestamp)\n\(scope)\n" + hash(Data(canonical.utf8))
                let key = hmac(hmac(hmac(Data("TC3test-key".utf8), date), "asr"), "tc3_request")
                let signature = hmac(key, toSign).map { String(format: "%02x", $0) }.joined()
                XCTAssertEqual(auth, "TC3-HMAC-SHA256 Credential=test-id/\(scope), SignedHeaders=content-type;host, Signature=\(signature)")
            }
        }
    }

    func testSentenceErrorsDoNotEchoDictionary() async throws {
        for status in [200, 400] {
            let client = TencentHotwordsClient(status: status, body: #"{"Response":{"Error":{"Code":"InvalidParameter.HotwordList","Message":"private-term|5"}}}"#)
            let provider = TencentSentenceASRProvider(secretId: "test-id", secretKey: "test-key", httpClient: client)
            do {
                _ = try await provider.recognize(audioData: Data([1]))
                XCTFail("Expected service failure")
            } catch {
                switch error {
                case MemoEchoError.cloudASRInvalidResponse(let detail):
                    XCTAssertEqual(status, 200)
                    XCTAssertEqual(detail, "腾讯云请求失败（InvalidParameter.HotwordList）")
                case MemoEchoError.cloudASRNetworkFailure(let message):
                    XCTAssertEqual(status, 400)
                    XCTAssertEqual(message, "HTTP 400")
                default: XCTFail("Unexpected error type")
                }
            }
        }
    }

    func testLiveRealtimeSyntheticHotwords() async throws { try await verifyLive(.tencentCloudRealtime) }
    func testLiveSentenceSyntheticHotwords() async throws { try await verifyLive(.tencentCloudSentence) }

    private func verifyLive(_ platform: ASRPlatform) async throws {
        guard let path = ProcessInfo.processInfo.environment["MEMOECHO_TEST_TENCENT_CONFIG"] else {
            throw XCTSkip("Set MEMOECHO_TEST_TENCENT_CONFIG for synthetic live verification")
        }
        struct Config: Decodable { let asr: ASRConfig }
        var config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: path))).asr
        config.selectedPlatform = platform
        let wav = try ASRValidationAudio.load()
        for count in [1, 128] {
            let words = ASRHotwords(terms: ["语音识别"] + (1..<count).map { "合成词\($0)" }, platform: platform)
            XCTAssertEqual(words.terms.count, count)
            let text: String
            if platform.isRealtime {
                let pcm = try WAVAudioDataExtractor.extractPCMData(from: wav)
                text = try await RealtimeRecognitionPipeline.replay(.init(processedPCM: pcm, rawPCM: Data()), config: config, hotwords: words).joined()
            } else {
                let provider = try XCTUnwrap(ASRProviderFactory.makeSentenceProvider(for: config, hotwords: words))
                text = try await provider.recognize(audioData: wav, timeout: 30).text
            }
            XCTAssertTrue(text.contains("语音识别"), "Synthetic target phrase should survive transcription")
            print("Tencent synthetic verification: realtime=\(platform.isRealtime) hotword_count=\(count) final_received=true")
        }
    }

    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func hmac(_ key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }
}

private actor TencentHotwordsClient: OpenAIASRHTTPClient {
    private(set) var request: URLRequest?
    let status: Int
    let body: String
    init(status: Int = 200, body: String = #"{"Response":{"Result":"合成测试","RequestId":"synthetic"}}"#) {
        self.status = status
        self.body = body
    }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.request = request
        return (Data(body.utf8),
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
