import Foundation

/// The original file flash service: one completed WAV per segment, no realtime model version.
final class VolcengineSentenceASRProvider: ASRProvider, CloudASRValidating, Sendable {
    private static let recognizeURL = URL(string: "https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash")!
    private static let resourceID = "volc.bigasr.auc_turbo"
    private static let endpoint = "openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash"
    private let apiKey: String
    private let hotwords: VolcengineHotwords
    private let httpClient: any OpenAIASRHTTPClient
    private let validationAudioLoader: @Sendable () throws -> Data

    init(apiKey: String, hotwords: VolcengineHotwords = .empty, httpClient: any OpenAIASRHTTPClient = OpenAIASRURLSessionClient.shared,
         validationAudioLoader: @escaping @Sendable () throws -> Data = { try ASRValidationAudio.load() }) {
        self.hotwords = hotwords
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.httpClient = httpClient
        self.validationAudioLoader = validationAudioLoader
    }

    func recognize(audioData: Data, timeout: TimeInterval? = nil) async throws -> TranscriptResult {
        try Task.checkCancellation()
        guard !apiKey.isEmpty, apiKey.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw MemoEchoError.cloudASRConfigurationIncomplete
        }
        guard !audioData.isEmpty else { throw MemoEchoError.asrEmptyAudio }

        let base64Audio = audioData.base64EncodedString()
        var options: [String: Any] = ["model_name": "bigmodel"]
        let context = try hotwords.context()
        if let context { options["corpus"] = ["context": context] }
        let body: [String: Any] = [
            "user": ["uid": "memoecho"],
            "audio": ["data": base64Audio],
            "request": options,
        ]
        var request = URLRequest(url: Self.recognizeURL)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = timeout ?? 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue(Self.resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")

        CloudASRRequestLogger.requestPrepared(.init(
            provider: "volcengine", endpoint: Self.endpoint, transport: "json_base64_wav",
            audioBytes: audioData.count, uploadBytes: request.httpBody?.count ?? 0,
            timeoutMs: Int(request.timeoutInterval * 1000), base64Bytes: base64Audio.utf8.count,
            frameCount: nil, minFrameBytes: nil, maxFrameBytes: nil, extra: "hotword_count=\(hotwords.terms.count) context_bytes=\(context?.utf8.count ?? 0)"
        ))
        let start = ContinuousClock.now
        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await httpClient.data(for: request)
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            let timedOut = (error as? URLError)?.code == .timedOut
            logFailure(phase: "network", reason: timedOut ? "timeout" : "network_failure")
            throw MemoEchoError.cloudASRNetworkFailure(message: timedOut ? "asr_timeout" : "network_failure")
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            logFailure(phase: "http", reason: "invalid_response")
            throw MemoEchoError.cloudASRInvalidResponse(detail: "语音服务未返回 HTTP 响应")
        }
        guard (200...299).contains(http.statusCode) else {
            logFailure(phase: "http", status: http.statusCode, reason: "request_failed")
            if http.statusCode == 401 || http.statusCode == 403 {
                throw MemoEchoError.cloudASRAuthenticationFailure
            }
            throw MemoEchoError.cloudASRNetworkFailure(message: "HTTP \(http.statusCode)")
        }

        let statusCode = http.value(forHTTPHeaderField: "X-Api-Status-Code") ?? ""
        switch statusCode {
        case "", "20000000": break
        case "20000003", "45000002":
            logFailure(phase: "api", status: http.statusCode, reason: "empty_audio")
            throw MemoEchoError.cloudASREmptyResponse
        case "401", "403":
            logFailure(phase: "api", status: http.statusCode, reason: "authentication_failed")
            throw MemoEchoError.cloudASRAuthenticationFailure
        default:
            let safeCode = statusCode.count <= 12 && statusCode.allSatisfy(\.isNumber) ? statusCode : "unknown"
            logFailure(phase: "api", status: http.statusCode, reason: "api_error_\(safeCode)")
            throw MemoEchoError.cloudASRInvalidResponse(detail: "火山引擎识别服务返回错误，请检查产品开通状态")
        }

        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let result = json["result"] as? [String: Any] else {
            logFailure(phase: "parse", status: http.statusCode, reason: "invalid_json")
            throw MemoEchoError.cloudASRInvalidResponse(detail: "火山引擎 ASR 响应 JSON 无法解析")
        }
        guard let text = (result["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            logFailure(phase: "parse", status: http.statusCode, reason: "empty_text")
            throw MemoEchoError.cloudASREmptyResponse
        }
        try Task.checkCancellation()
        let elapsed = start.duration(to: .now).components
        let durationMs = Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
        let requestID = http.value(forHTTPHeaderField: "X-Tt-Logid")
        CloudASRRequestLogger.requestCompleted(provider: "volcengine", endpoint: Self.endpoint,
            durationMs: durationMs, responseBytes: responseData.count, statusCode: http.statusCode, requestID: requestID)
        return TranscriptResult(text: text, requestId: requestID, durationMs: durationMs)
    }

    func validateCredentials() async throws {
        do {
            _ = try await recognize(audioData: validationAudioLoader(), timeout: 15)
        } catch MemoEchoError.cloudASREmptyResponse {
            throw MemoEchoError.cloudASRInvalidResponse(detail: "文件极速版未识别出测试语音，请检查产品开通状态")
        }
    }

    private func logFailure(phase: String, status: Int? = nil, reason: String) {
        CloudASRRequestLogger.requestFailed(provider: "volcengine", endpoint: Self.endpoint,
            phase: phase, statusCode: status, message: reason)
    }
}
