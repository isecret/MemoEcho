import Foundation

/// DashScope synchronous audio recognition; sends one completed WAV per segment.
final class AliyunBailianHTTPASRProvider: ASRProvider, CloudASRValidating, Sendable {
    private let config: AliyunBailianHTTPASRConfig
    private let httpClient: any OpenAIASRHTTPClient
    private static let providerName = "aliyunBailianHTTP"

    init(config: AliyunBailianHTTPASRConfig, httpClient: any OpenAIASRHTTPClient = OpenAIASRURLSessionClient.shared) {
        self.config = config
        self.httpClient = httpClient
    }

    func recognize(audioData: Data, timeout: TimeInterval? = nil) async throws -> TranscriptResult {
        try Task.checkCancellation()
        guard config.isComplete, let url = config.requestURL else { throw MemoEchoError.cloudASRConfigurationIncomplete }
        guard !audioData.isEmpty else { throw MemoEchoError.asrEmptyAudio }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout ?? 15
        if !config.normalizedAPIKey.isEmpty {
            request.setValue("Bearer \(config.normalizedAPIKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("disable", forHTTPHeaderField: "X-DashScope-SSE")
        let audio = RecognitionRequest.Audio(data: "data:audio/wav;base64," + audioData.base64EncodedString())
        let message = RecognitionRequest.Message(content: [.init(input_audio: audio)])
        request.httpBody = try JSONEncoder().encode(RecognitionRequest(
            model: config.normalizedModel, input: .init(messages: [message])
        ))
        try Task.checkCancellation()
        CloudASRRequestLogger.requestPrepared(.init(
            provider: Self.providerName, endpoint: "multimodalGeneration",
            transport: "json_base64_wav",
            audioBytes: audioData.count, uploadBytes: request.httpBody?.count ?? 0,
            timeoutMs: Int(request.timeoutInterval * 1000), base64Bytes: nil,
            frameCount: nil, minFrameBytes: nil, maxFrameBytes: nil, extra: nil
        ))
        let start = ContinuousClock.now
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await httpClient.data(for: request)
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            let timedOut = (error as? URLError)?.code == .timedOut
            logFailure(phase: "network", reason: timedOut ? "timeout" : "network_failure")
            let message: String
            if timedOut {
                message = "asr_timeout"
            } else if (error as? URLError)?.code == .notConnectedToInternet {
                message = "local_network_unavailable"
            } else {
                message = "network_failure"
            }
            throw MemoEchoError.cloudASRNetworkFailure(message: message)
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw MemoEchoError.cloudASRInvalidResponse(detail: "语音服务未返回 HTTP 响应")
        }
        guard (200...299).contains(http.statusCode) else {
            logFailure(phase: "http", status: http.statusCode, reason: "request_failed")
            switch http.statusCode {
            case 401, 403: throw MemoEchoError.cloudASRAuthenticationFailure
            case 404: throw MemoEchoError.cloudASRInvalidResponse(detail: "识别接口不存在，请检查 Base URL 和接口格式")
            case 300...399: throw MemoEchoError.cloudASRInvalidResponse(detail: "语音服务返回重定向，请直接填写最终接口地址")
            default: throw MemoEchoError.cloudASRNetworkFailure(message: "HTTP \(http.statusCode)")
            }
        }
        let text: String
        do {
            text = try parseText(data).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            logFailure(phase: "parse", status: http.statusCode, reason: "invalid_response")
            throw MemoEchoError.cloudASRInvalidResponse(detail: "响应不符合所选接口格式，或未返回完整转写")
        }
        guard !text.isEmpty else {
            logFailure(phase: "parse", status: http.statusCode, reason: "empty_text")
            throw MemoEchoError.cloudASREmptyResponse
        }
        try Task.checkCancellation()
        let elapsed = start.duration(to: .now).components
        let durationMs = Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
        CloudASRRequestLogger.requestCompleted(provider: Self.providerName, endpoint: "multimodalGeneration",
            durationMs: durationMs, responseBytes: data.count, statusCode: http.statusCode, requestID: nil)
        return TranscriptResult(text: text, requestId: nil, durationMs: durationMs)
    }

    func validateCredentials() async throws {
        do {
            _ = try await recognize(audioData: ASRValidationAudio.load(), timeout: 15)
        } catch MemoEchoError.cloudASREmptyResponse {
            // The shared validation service tolerates silence for older providers; this voiced sample must not.
            throw MemoEchoError.cloudASRInvalidResponse(detail: "服务未识别出测试语音，请检查模型和接口格式")
        }
    }

    private func parseText(_ data: Data) throws -> String {
        let response = try JSONDecoder().decode(RecognitionResponse.self, from: data)
        guard response.code == nil, let output = response.output,
              let text = output.text, output.sentence?.sentence_end != false else { throw ParseError.invalid }
        return text
    }

    private func logFailure(phase: String, status: Int? = nil, reason: String) {
        CloudASRRequestLogger.requestFailed(provider: Self.providerName, endpoint: "multimodalGeneration",
            phase: phase, statusCode: status, message: reason)
    }

    private enum ParseError: Error { case invalid }
    private struct RecognitionResponse: Decodable {
        let code: String?
        let output: Output?
        struct Output: Decodable {
            let text: String?
            let sentence: Sentence?
        }
        struct Sentence: Decodable { let sentence_end: Bool? }
    }
    private struct RecognitionRequest: Encodable {
        let model: String
        let input: Input
        let parameters = Parameters()
        struct Input: Encodable { let messages: [Message] }
        struct Message: Encodable {
            let role = "user"
            let content: [Content]
        }
        struct Content: Encodable {
            let type = "input_audio"
            let input_audio: Audio
        }
        struct Audio: Encodable { let data: String }
        struct Parameters: Encodable {
            let format = "wav"
            let sample_rate = "16000"
        }
    }
}
