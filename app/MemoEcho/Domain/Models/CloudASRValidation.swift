import Foundation

enum CloudASRValidationDisplayStatus: Equatable, Sendable {
    case incomplete
    case checking
    case ready
    case failed
}

struct CloudASRValidationInput: Equatable, Sendable {
    var platform: ASRPlatform
    var asrConfig: ASRConfig

    var isCloudPlatform: Bool {
        platform != .localSenseVoice
    }

    var isComplete: Bool {
        switch platform {
        case .localSenseVoice:
            return false
        case .tencentCloudSentence:
            return asrConfig.tencentCloud.sentenceState.isComplete
        case .tencentCloudRealtime:
            return asrConfig.tencentCloud.isComplete
        case .aliyunSentence:
            return asrConfig.aliyun.sentenceState.isComplete
        case .aliyunRealtime:
            return asrConfig.aliyun.isComplete
        case .aliyunBailianHTTPASR:
            return asrConfig.aliyunBailianHTTP.isComplete
        case .aliyunBailianASR:
            return asrConfig.aliyunBailian.isComplete
        case .volcengineRealtime:
            return asrConfig.volcengine.isComplete
        case .volcengineBigModelSentence:
            return asrConfig.volcengine.bigModelSentenceState.isComplete
        case .volcengineSentence:
            return asrConfig.volcengine.fileState.isComplete
        case .volcengineTraditionalSentence:
            return asrConfig.volcengineTraditional.sentenceState.isComplete
        case .volcengineTraditionalRealtime:
            return asrConfig.volcengineTraditional.realtimeState.isComplete
        case .xunfeiIAT:
            return asrConfig.xunfei.iatState.isComplete
        case .xunfeiRealtime:
            return asrConfig.xunfei.isComplete
        case .mimoASR:
            return asrConfig.mimo.isComplete
        case .openAICompatibleASR:
            return asrConfig.openAICompatible.isComplete
        }
    }

    var fingerprint: String {
        switch platform {
        case .localSenseVoice:
            return platform.rawValue
        case .tencentCloudSentence:
            return "\(platform.rawValue)\n\(asrConfig.tencentCloud.secretId)\n\(asrConfig.tencentCloud.secretKey)"
        case .tencentCloudRealtime:
            return "\(platform.rawValue)\n\(asrConfig.tencentCloud.appID)\n\(asrConfig.tencentCloud.secretId)\n\(asrConfig.tencentCloud.secretKey)"
        case .aliyunSentence:
            return "\(platform.rawValue)\n\(asrConfig.aliyun.accessKeyId)\n\(asrConfig.aliyun.accessKeySecret)\n\(asrConfig.aliyun.appKey)"
        case .aliyunRealtime:
            return "\(platform.rawValue)\n\(asrConfig.aliyun.accessKeyId)\n\(asrConfig.aliyun.accessKeySecret)\n\(asrConfig.aliyun.appKey)"
        case .aliyunBailianHTTPASR:
            return String(decoding: try! JSONEncoder().encode([platform.rawValue] + asrConfig.aliyunBailianHTTP.connectionIdentity), as: UTF8.self)
        case .aliyunBailianASR:
            let identity = [platform.rawValue] + asrConfig.aliyunBailian.connectionIdentity
            return String(decoding: try! JSONEncoder().encode(identity), as: UTF8.self)
        case .volcengineRealtime, .volcengineBigModelSentence:
            return String(decoding: try! JSONEncoder().encode([platform.rawValue, asrConfig.volcengine.apiKey,
                asrConfig.volcengine.modelVersion.rawValue]), as: UTF8.self)
        case .volcengineSentence:
            // Keep the original identity so matching legacy success records remain valid.
            return "\(platform.rawValue)\n\(asrConfig.volcengine.apiKey)"
        case .volcengineTraditionalSentence:
            return String(decoding: try! JSONEncoder().encode([platform.rawValue] + asrConfig.volcengineTraditional.sentenceConnectionIdentity), as: UTF8.self)
        case .volcengineTraditionalRealtime:
            return String(decoding: try! JSONEncoder().encode([platform.rawValue] + asrConfig.volcengineTraditional.realtimeConnectionIdentity), as: UTF8.self)
        case .xunfeiIAT:
            return "\(platform.rawValue)\n\(asrConfig.xunfei.appID)\n\(asrConfig.xunfei.apiKey)\n\(asrConfig.xunfei.apiSecret)"
        case .xunfeiRealtime:
            return "\(platform.rawValue)\n\(asrConfig.xunfei.appID)\n\(asrConfig.xunfei.realtimeAPIKey)"
        case .mimoASR:
            return String(decoding: try! JSONEncoder().encode([platform.rawValue] + asrConfig.mimo.connectionIdentity), as: UTF8.self)
        case .openAICompatibleASR:
            let identity = [platform.rawValue] + asrConfig.openAICompatible.connectionIdentity
            return String(decoding: try! JSONEncoder().encode(identity), as: UTF8.self)
        }
    }
}
