import Foundation

struct ASRProviderFactory {
    let runtimeManager: SenseVoiceRuntimeManager

    func makeProvider(for config: ASRConfig) -> any ASRProvider {
        if let provider = Self.makeSentenceProvider(for: config) { return provider }
        return switch config.selectedPlatform {
        case .localSenseVoice: SenseVoiceASRProvider(runtimeManager: runtimeManager)
        case .openAICompatibleASR: OpenAICompatibleASRProvider(config: config.openAICompatible)
        case .mimoASR: MiMoASRProvider(config: config.mimo)
        default: RealtimeOnlyASRProvider()
        }
    }

    static func makeSentenceProvider(for config: ASRConfig) -> (any ASRProvider & CloudASRValidating)? {
        switch config.selectedPlatform {
        case .tencentCloudSentence:
            TencentSentenceASRProvider(secretId: config.tencentCloud.secretId, secretKey: config.tencentCloud.secretKey)
        case .aliyunBailianHTTPASR:
            AliyunBailianHTTPASRProvider(config: config.aliyunBailianHTTP)
        case .volcengineSentence:
            VolcengineSentenceASRProvider(apiKey: config.volcengine.apiKey)
        case .aliyunSentence:
            AliyunSentenceASRProvider(accessKeyId: config.aliyun.accessKeyId,
                accessKeySecret: config.aliyun.accessKeySecret, appKey: config.aliyun.appKey)
        default: nil
        }
    }

    static func realtimeConfiguration(for config: ASRConfig) throws -> RealtimeCloudASRConfiguration {
        switch config.selectedPlatform {
        case .tencentCloudRealtime:
            return .tencent(appID: config.tencentCloud.appID, secretID: config.tencentCloud.secretId,
                            secretKey: config.tencentCloud.secretKey)
        case .aliyunRealtime:
            return .aliyun(accessKeyID: config.aliyun.accessKeyId, accessKeySecret: config.aliyun.accessKeySecret,
                           appKey: config.aliyun.appKey)
        case .aliyunBailianASR:
            guard config.aliyunBailian.isComplete, let url = config.aliyunBailian.requestURL else {
                throw MemoEchoError.cloudASRConfigurationIncomplete
            }
            return .bailian(apiKey: config.aliyunBailian.normalizedAPIKey, endpoint: url,
                            model: config.aliyunBailian.normalizedModel)
        case .volcengineRealtime:
            return .volcengine(apiKey: config.volcengine.apiKey, resourceID: config.volcengine.modelVersion.resourceID, mode: .streaming)
        case .volcengineBigModelSentence:
            return .volcengine(apiKey: config.volcengine.apiKey, resourceID: config.volcengine.modelVersion.resourceID, mode: .sentence)
        case .volcengineTraditionalSentence, .volcengineTraditionalRealtime:
            let traditional = config.volcengineTraditional
            let sentence = config.selectedPlatform == .volcengineTraditionalSentence
            guard (sentence ? traditional.sentenceState : traditional.realtimeState).isComplete else {
                throw MemoEchoError.cloudASRConfigurationIncomplete
            }
            return .volcengineTraditional(appID: traditional.normalizedAppID,
                accessToken: traditional.normalizedAccessToken,
                cluster: sentence ? traditional.normalizedSentenceCluster : traditional.normalizedRealtimeCluster,
                mode: sentence ? .sentence : .streaming)
        case .xunfeiIAT:
            return .xunfeiIAT(appID: config.xunfei.appID, apiKey: config.xunfei.apiKey, apiSecret: config.xunfei.apiSecret)
        case .xunfeiRealtime: return .xunfei(appID: config.xunfei.appID, apiKey: config.xunfei.realtimeAPIKey)
        default: throw RealtimeASRError.configuration
        }
    }

    static func makeRealtimeSession(for config: ASRConfig) throws -> any RealtimeASRSession {
        RealtimeCloudASRSession(configuration: try realtimeConfiguration(for: config))
    }
}

/// Prevent a realtime selection from accidentally entering the completed-WAV path.
private struct RealtimeOnlyASRProvider: ASRProvider {
    func recognize(audioData: Data, timeout: TimeInterval?) async throws -> TranscriptResult {
        throw MemoEchoError.asrPlatformNotReady(detail: "此引擎需要实时识别会话")
    }
}

struct RealtimeASRValidator: CloudASRValidating {
    let config: ASRConfig
    func validateCredentials() async throws {
        let session = try ASRProviderFactory.makeRealtimeSession(for: config)
        try await withTaskCancellationHandler {
            do {
                let pcm = try WAVAudioDataExtractor.extractPCMData(from: ASRValidationAudio.load())
                try await session.connect()
                let start = ContinuousClock.now
                let frame = session.capabilities.preferredFrameBytes
                for offset in stride(from: 0, to: pcm.count, by: frame) {
                    try Task.checkCancellation()
                    let deadline = start.advanced(by: .seconds(Double(offset) / 32_000))
                    if ContinuousClock.now < deadline { try await ContinuousClock().sleep(until: deadline) }
                    try await session.send(pcm.subdata(in: offset..<min(offset + frame, pcm.count)))
                }
                let text = try await session.finish()
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw MemoEchoError.cloudASRInvalidResponse(detail: "实时服务未识别出测试语音")
                }
                await session.cancel()
            } catch {
                await session.cancel()
                throw error
            }
        } onCancel: { Task { await session.cancel() } }
    }
}
