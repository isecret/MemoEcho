import XCTest
@testable import MemoEcho

final class BailianHotwordsTests: XCTestCase {
    func testLiveRealtimeSyntheticHotwords() async throws {
        try await verifyLive(.aliyunBailianASR)
    }

    func testLiveHTTPSyntheticHotwords() async throws {
        try await verifyLive(.aliyunBailianHTTPASR)
    }

    private func verifyLive(_ platform: ASRPlatform) async throws {
        guard let path = ProcessInfo.processInfo.environment["MEMOECHO_TEST_BAILIAN_CONFIG"] else {
            throw XCTSkip("Set MEMOECHO_TEST_BAILIAN_CONFIG for synthetic live verification")
        }
        struct Config: Decodable { let asr: ASRConfig }
        var config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: path))).asr
        config.selectedPlatform = platform
        let wav = try ASRValidationAudio.load()
        for count in [1, 2000] {
            let terms = ["语音识别"] + (1..<count).map { "合成词\($0)" }
            let snapshot = ASRHotwords(terms: terms, platform: platform)
            XCTAssertEqual(snapshot.terms.count, count)
            let model = platform.isRealtime ? config.aliyunBailian.normalizedModel : config.aliyunBailianHTTP.normalizedModel
            XCTAssertNotNil(snapshot.bailianVocabulary(model: model, realtime: platform.isRealtime))
            let text: String
            if platform.isRealtime {
                let pcm = try WAVAudioDataExtractor.extractPCMData(from: wav)
                text = try await RealtimeRecognitionPipeline.replay(.init(processedPCM: pcm, rawPCM: Data()),
                    config: config, hotwords: snapshot).joined()
            } else {
                let provider = try XCTUnwrap(ASRProviderFactory.makeSentenceProvider(for: config, hotwords: snapshot))
                text = try await provider.recognize(audioData: wav, timeout: 30).text
            }
            XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            print("Bailian synthetic verification: realtime=\(platform.isRealtime) hotword_count=\(count) final_received=true")
        }
    }

    func testSelectionValidatesBeforeTakingLimitAndDeduplicates() {
        let validChinese = String(repeating: "中", count: 15)
        let input = [" ", "MemoEcho", "memoecho", validChinese, validChinese + "中",
                     "one two three four five six seven", "one two three four five six seven eight", "line\nfeed"]
        for platform in [ASRPlatform.aliyunBailianASR, .aliyunBailianHTTPASR] {
            let words = ASRHotwords(terms: input, platform: platform)
            XCTAssertEqual(words.terms, ["MemoEcho", validChinese, "one two three four five six seven"])
            let large = ASRHotwords(terms: [validChinese + "中"] + (0..<5000).map { "词\($0)" }, platform: platform)
            XCTAssertEqual(large.terms.count, 2000)
            XCTAssertEqual(large.terms.last, "词1999")
        }
    }

    func testRealtimeFactorySendsVocabularyOnlyForSupportedModels() throws {
        for model in ["qwen-audio-3.1-asr-flash-streaming", "qwen-audio-3.0-asr-flash-streaming", "paraformer-realtime-v2", "custom-model"] {
            for terms in [[], ["MemoEcho", "测试词"]] {
                var config = ASRConfig()
                config.selectedPlatform = .aliyunBailianASR
                config.aliyunBailian = .init(apiKey: "synthetic", model: model)
                let words = ASRHotwords(terms: terms, platform: config.selectedPlatform)
                var codec = RealtimeWireCodec(configuration: try ASRProviderFactory.realtimeConfiguration(for: config, hotwords: words))
                guard case .text(let text) = try codec.startMessage() else { return XCTFail("Missing start message") }
                let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
                let payload = try XCTUnwrap(root["payload"] as? [String: Any])
                let parameters = try XCTUnwrap(payload["parameters"] as? [String: Any])
                if model.hasPrefix("qwen-audio-") && !terms.isEmpty {
                    XCTAssertEqual(parameters["vocabulary"] as? [String: Int], ["MemoEcho": 4, "测试词": 4])
                } else { XCTAssertNil(parameters["vocabulary"]) }
                XCTAssertNil(parameters["vocabulary_id"])
            }
        }
    }

    func testRealtimeModelMustBeExplicitAndSavedChoiceSurvives() throws {
        XCTAssertEqual(AliyunBailianASRConfig.defaultModel, "")
        let missing = try JSONDecoder().decode(AliyunBailianASRConfig.self, from: Data(#"{"apiKey":"synthetic"}"#.utf8))
        XCTAssertEqual(missing.model, "")
        XCTAssertFalse(missing.isComplete)
        for model in ["paraformer-realtime-v2", "qwen-audio-3.1-asr-flash-streaming", "custom"] {
            let original = AliyunBailianASRConfig(apiKey: "synthetic", model: model)
            XCTAssertEqual(try JSONDecoder().decode(AliyunBailianASRConfig.self, from: JSONEncoder().encode(original)).model, model)
        }
        var config = ASRConfig()
        config.selectedPlatform = .aliyunBailianASR
        config.aliyunBailian = missing
        XCTAssertThrowsError(try ASRProviderFactory.realtimeConfiguration(for: config))
    }
}
