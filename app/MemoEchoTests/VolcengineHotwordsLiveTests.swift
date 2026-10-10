import XCTest
@testable import MemoEcho

/// Opt-in: audio is synthetic. Personal dictionary upload requires its separate explicit path.
final class VolcengineHotwordsLiveTests: XCTestCase {
    func testStreamingAcceptsHotwordsAndReturnsFinal() async throws {
        for count in [1, 128, 1000, 5000] { try await verify(.volcengineRealtime, count: count) }
    }
    func testSentenceAcceptsHotwordsAndReturnsFinal() async throws {
        try await verify(.volcengineBigModelSentence, count: 5000)
    }
    func testFlashAcceptsHotwordsAndReturnsFinal() async throws {
        try await verify(.volcengineSentence, count: 5000)
    }

    func testExplicitlySelectedPersonalDictionary() async throws {
        guard let path = ProcessInfo.processInfo.environment["MEMOECHO_TEST_VOLCENGINE_DICTIONARY"] else {
            throw XCTSkip("Set MEMOECHO_TEST_VOLCENGINE_DICTIONARY to authorize personal dictionary upload")
        }
        let entries = try JSONDecoder().decode([DictionaryEntry].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        try await verify(.volcengineRealtime, count: entries.count, suppliedTerms: entries.map(\.term))
    }

    private func verify(_ platform: ASRPlatform, count: Int, suppliedTerms: [String]? = nil) async throws {
        guard let path = ProcessInfo.processInfo.environment["MEMOECHO_TEST_VOLCENGINE_CONFIG"] else {
            throw XCTSkip("Set MEMOECHO_TEST_VOLCENGINE_CONFIG to opt into synthetic live verification")
        }
        struct Config: Decodable { let asr: ASRConfig }
        var config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: path))).asr
        config.selectedPlatform = platform
        let terms = suppliedTerms ?? (["语音识别"] + (1..<count).map { "合成热词容量验证条目\($0)" })
        let hotwords = VolcengineHotwords(terms: terms, platform: platform)
        XCTAssertEqual(hotwords.terms.count, count)
        print("Hotword probe: platform=\(platform.rawValue) model=\(config.volcengine.modelVersion) words=\(count) contextBytes=\(try XCTUnwrap(hotwords.context()).utf8.count)")
        let wav = try ASRValidationAudio.load()
        let text: String
        if platform.isRealtime {
            let pcm = try WAVAudioDataExtractor.extractPCMData(from: wav)
            text = try await RealtimeRecognitionPipeline.replay(.init(processedPCM: pcm, rawPCM: Data()),
                config: config, hotwords: hotwords).joined()
        } else {
            let provider = try XCTUnwrap(ASRProviderFactory.makeSentenceProvider(for: config, hotwords: hotwords))
            text = try await provider.recognize(audioData: wav, timeout: 30).text
        }
        XCTAssertTrue(text.contains("语音"), "Synthetic speech must reach a final transcript")
    }
}
