import XCTest
@testable import MemoEcho

/// Opt-in only. Sends the bundled synthetic phrase; never reads user configuration or microphone data.
final class OpenAICompatibleASRLiveTests: XCTestCase {
    func testConfiguredServiceWithSyntheticSpeech() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let baseURL = environment["MEMOECHO_TEST_ASR_BASE_URL"],
              let modelList = environment["MEMOECHO_TEST_ASR_MODELS"], !modelList.isEmpty else {
            throw XCTSkip("Set MEMOECHO_TEST_ASR_BASE_URL and MEMOECHO_TEST_ASR_MODELS to run live verification")
        }
        let audio = try ASRValidationAudio.load()
        for model in modelList.split(separator: ",").map(String.init) {
            let config = OpenAICompatibleASRConfig(baseURL: baseURL,
                apiKey: environment["MEMOECHO_TEST_ASR_KEY"] ?? "", model: model)
            XCTAssertTrue(config.isComplete, "Live test requires a valid connection")
            let provider = OpenAICompatibleASRProvider(config: config)
            let result = try await provider.recognize(audioData: audio, timeout: 90)
            XCTAssertTrue(result.text.contains("语音"), "Synthetic speech must be transcribed")
            try await provider.validateCredentials()
        }
    }
}
