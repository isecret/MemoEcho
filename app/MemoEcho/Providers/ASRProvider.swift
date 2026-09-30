import Foundation

/// 分段 ASR 接口（本地、云端一句话／文件、Audio Transcriptions、MiMo）。实时入口使用 RealtimeASRSession。
protocol ASRProvider: Sendable {
    /// 对音频数据执行语音识别，返回转写结果
    /// - Parameters:
    ///   - audioData: WAV 格式音频数据
    ///   - timeout: 可选超时时间（秒），nil 时使用 provider 内部默认值
    func recognize(audioData: Data, timeout: TimeInterval?) async throws -> TranscriptResult
}

protocol CloudASRValidating: Sendable {
    func validateCredentials() async throws
}
