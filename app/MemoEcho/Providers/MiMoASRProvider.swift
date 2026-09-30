import Foundation

/// MiMo speech recognition uses a single audio message, not Audio Transcriptions.
final class MiMoASRProvider: ASRProvider, CloudASRValidating, Sendable {
    private let config: MiMoASRConfig
    private let httpClient: any OpenAIASRHTTPClient
    private static let providerName = "mimo"

    init(config: MiMoASRConfig, httpClient: any OpenAIASRHTTPClient = OpenAIASRURLSessionClient.shared) {
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
        request.httpBody = try JSONEncoder().encode(ChatRequest(model: config.normalizedModel, messages: [
            .init(content: [.init(input_audio: .init(data: audioData.base64EncodedString()))])
        ]))
        try Task.checkCancellation()
        CloudASRRequestLogger.requestPrepared(.init(
            provider: Self.providerName, endpoint: "chatCompletions",
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
        CloudASRRequestLogger.requestCompleted(provider: Self.providerName, endpoint: "chatCompletions",
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
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              envelope["error"] == nil || envelope["error"] is NSNull else { throw ParseError.invalid }
        let response = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard response.choices.count == 1, let choice = response.choices.first,
              choice.finish_reason == "stop" else { throw ParseError.invalid }
        return choice.message.content
    }

    private func logFailure(phase: String, status: Int? = nil, reason: String) {
        CloudASRRequestLogger.requestFailed(provider: Self.providerName, endpoint: "chatCompletions",
            phase: phase, statusCode: status, message: reason)
    }

    private enum ParseError: Error { case invalid }
    private struct ChatResponse: Decodable {
        let choices: [Choice]
        struct Choice: Decodable {
            let finish_reason: String?
            let message: Message
        }
        struct Message: Decodable { let content: String }
    }
    private struct ChatRequest: Encodable {
        let model: String
        let messages: [Message]
        let stream = false
        struct Message: Encodable {
            let role = "user"
            let content: [Content]
        }
        struct Content: Encodable {
            let type = "input_audio"
            let input_audio: Audio
        }
        struct Audio: Encodable {
            let data: String
            let format = "wav"
        }
    }
}
