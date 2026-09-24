import Foundation

/// 统一的 ASR Provider 协议，所有语音识别实现需遵循此接口
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
