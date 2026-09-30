import Foundation

/// A bundled synthetic phrase, never captured from the user's microphone.
enum ASRValidationAudio {
    static func load(bundle: Bundle = .main) throws -> Data {
        guard let url = bundle.url(forResource: "asr-validation", withExtension: "wav"),
              let data = try? Data(contentsOf: url), !data.isEmpty else {
            throw MemoEchoError.cloudASRInvalidResponse(detail: "语音验证音频缺失，请重新安装应用")
        }
        return data
    }
}
