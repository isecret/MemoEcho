import AppKit
import Foundation

// MARK: - LLM 配置（不含密钥）

struct LLMConfig: Codable, Equatable, Sendable {
    var baseURL: String = ""
    var model: String = ""
}

// MARK: - ASR 平台配置

/// ASR 平台类型
enum ASRPlatform: String, Codable, Equatable, Sendable, CaseIterable {
    case localSenseVoice = "localSenseVoice"
    case tencentCloudSentence = "tencentCloudSentence"
    case tencentCloudRealtime = "tencentCloudRealtime"
    case aliyunSentence = "aliyunSentence"
    case aliyunRealtime = "aliyunRealtime"
    case aliyunBailianHTTPASR = "aliyunBailianHTTPASR"
    case aliyunBailianASR = "aliyunBailianASR"
    case volcengineRealtime = "volcengineRealtime"
    case volcengineBigModelSentence = "volcengineBigModelSentence"
    case volcengineSentence = "volcengineSentence"
    case volcengineTraditionalSentence = "volcengineTraditionalSentence"
    case volcengineTraditionalRealtime = "volcengineTraditionalRealtime"
    case xunfeiIAT = "xunfeiIAT"
    case xunfeiRealtime = "xunfeiRealtime"
    case openAICompatibleASR = "openAICompatibleASR"
    case mimoASR = "mimoASR"

    var isRealtime: Bool {
        switch self {
        case .tencentCloudRealtime, .aliyunRealtime, .aliyunBailianASR, .volcengineRealtime, .volcengineBigModelSentence, .volcengineTraditionalSentence, .volcengineTraditionalRealtime, .xunfeiIAT, .xunfeiRealtime: true
        default: false
        }
    }

    var displayName: String {
        switch self {
        case .localSenseVoice:
            "本地 · SenseVoice"
        case .tencentCloudSentence:
            "腾讯云 · 一句话识别"
        case .tencentCloudRealtime:
            "腾讯云 · 实时语音识别"
        case .aliyunSentence:
            "阿里云 · 一句话识别"
        case .aliyunRealtime:
            "阿里云 · 实时语音识别"
        case .aliyunBailianHTTPASR:
            "阿里云 · 百炼语音识别"
        case .aliyunBailianASR:
            "阿里云 · 百炼实时语音识别"
        case .volcengineRealtime:
            "火山引擎 · 大模型流式语音识别"
        case .volcengineBigModelSentence:
            "火山引擎 · 大模型一句话识别"
        case .volcengineSentence:
            "火山引擎 · 录音文件极速版"
        case .volcengineTraditionalSentence:
            "火山引擎 · 一句话识别"
        case .volcengineTraditionalRealtime:
            "火山引擎 · 流式语音识别"
        case .xunfeiIAT:
            "科大讯飞 · 语音听写"
        case .xunfeiRealtime:
            "科大讯飞 · 实时语音转写"
        case .mimoASR:
            "小米 · MiMo"
        case .openAICompatibleASR:
            "OpenAI 兼容"
        }
    }

    var cloudConfigSummary: String {
        switch self {
        case .localSenseVoice:
            "语音在本机识别，转写文本由 AI 整理。"
        case .tencentCloudSentence, .aliyunSentence, .mimoASR:
            "音频会发送到所选服务，识别后由 AI 整理。"
        case .tencentCloudRealtime, .aliyunRealtime:
            "录音时会上传音频，请先开通对应的实时识别服务。"
        case .aliyunBailianHTTPASR:
            "音频会上传到百炼。地址可填 /api/v1 或完整接口地址。"
        case .aliyunBailianASR:
            "录音时会上传音频，模型需支持当前百炼实时接口。"
        case .volcengineRealtime, .volcengineBigModelSentence:
            "录音时会上传音频，请开通所选模型版本对应的服务。"
        case .volcengineSentence:
            "音频分段上传到火山引擎，识别后由 AI 整理。"
        case .volcengineTraditionalSentence, .volcengineTraditionalRealtime:
            "录音时会上传音频，请开通所选的语音识别服务。"
        case .xunfeiIAT, .xunfeiRealtime:
            "录音时会上传音频。语音听写与实时语音转写的 API Key 不能混用。"
        case .openAICompatibleASR:
            "音频会发送到所选服务。使用 Audio Transcriptions，地址通常以 /v1 结尾。"
        }
    }

    var documentationURL: URL {
        switch self {
        case .localSenseVoice:
            URL(string: "https://k2-fsa.github.io/sherpa/onnx/sense-voice/index.html")!
        case .tencentCloudSentence:
            URL(string: "https://cloud.tencent.com/document/product/1093/35646")!
        case .tencentCloudRealtime:
            URL(string: "https://cloud.tencent.com/document/product/1093/48982")!
        case .aliyunSentence:
            URL(string: "https://help.aliyun.com/zh/isi/developer-reference/short-sentence-recognition")!
        case .aliyunRealtime:
            URL(string: "https://help.aliyun.com/zh/isi/developer-reference/real-time-speech-recognition")!
        case .aliyunBailianHTTPASR:
            URL(string: "https://help.aliyun.com/zh/model-studio/fun-asr-flash-recorded-speech-recognition-http-api")!
        case .aliyunBailianASR:
            URL(string: "https://help.aliyun.com/zh/model-studio/paraformer-real-time-speech-recognition")!
        case .volcengineRealtime:
            URL(string: "https://docs.volcengine.com/docs/DoubaoVoice/LargemodelstreamingautomaticspeechrecognitionAPI?lang=zh")!
        case .volcengineBigModelSentence:
            URL(string: "https://docs.volcengine.com/docs/DoubaoVoice/unidirectional-streaming-automatic-speech-recognition-websocket?lang=zh")!
        case .volcengineSentence:
            URL(string: "https://docs.volcengine.com/docs/DoubaoVoice/recording-file-recognition-lite-http?lang=zh")!
        case .volcengineTraditionalSentence:
            URL(string: "https://docs.volcengine.com/docs/DoubaoVoice/One-sentencerecognition?lang=zh")!
        case .volcengineTraditionalRealtime:
            URL(string: "https://docs.volcengine.com/docs/DoubaoVoice/Streamingautomaticspeechrecognition?lang=zh")!
        case .xunfeiIAT:
            URL(string: "https://www.xfyun.cn/doc/asr/voicedictation/API.html")!
        case .xunfeiRealtime:
            URL(string: "https://www.xfyun.cn/doc/asr/rtasr/API.html")!
        case .mimoASR:
            URL(string: "https://mimo.mi.com/docs/en-US/api/audio/Speech-Recognition")!
        case .openAICompatibleASR:
            URL(string: "https://github.com/isecret/MemoEcho/blob/main/docs/USAGE.md#openai-兼容")!
        }
    }
}

/// ASR 总配置
struct ASRConfig: Codable, Equatable, Sendable {
    var selectedPlatform: ASRPlatform = .localSenseVoice
    var local: LocalASRConfig = LocalASRConfig()
    var tencentCloud: TencentASRConfig = TencentASRConfig()
    var aliyun: AliyunASRConfig = AliyunASRConfig()
    var aliyunBailianHTTP = AliyunBailianHTTPASRConfig()
    var aliyunBailian = AliyunBailianASRConfig()
    var volcengine: VolcengineASRConfig = VolcengineASRConfig()
    var volcengineTraditional = VolcengineTraditionalASRConfig()
    var xunfei: XunfeiASRConfig = XunfeiASRConfig()
    var openAICompatible = OpenAICompatibleASRConfig()
    var mimo = MiMoASRConfig()

    init() {}

    private enum CodingKeys: String, CodingKey {
        case selectedPlatform, local, tencentCloud, aliyun, aliyunBailian, aliyunBailianHTTP, volcengine, volcengineTraditional, xunfei, openAICompatible, mimo
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let platform = try container.decode(String.self, forKey: .selectedPlatform)
        if platform == "xunfeiSentence" { selectedPlatform = .xunfeiIAT }
        else if let current = ASRPlatform(rawValue: platform) { selectedPlatform = current }
        else { throw DecodingError.dataCorruptedError(forKey: .selectedPlatform, in: container, debugDescription: "Unsupported ASR platform") }
        mimo = try container.decodeIfPresent(MiMoASRConfig.self, forKey: .mimo) ?? MiMoASRConfig()
        local = try container.decodeIfPresent(LocalASRConfig.self, forKey: .local) ?? LocalASRConfig()
        tencentCloud = try container.decodeIfPresent(TencentASRConfig.self, forKey: .tencentCloud) ?? TencentASRConfig()
        aliyun = try container.decodeIfPresent(AliyunASRConfig.self, forKey: .aliyun) ?? AliyunASRConfig()
        aliyunBailianHTTP = try container.decodeIfPresent(AliyunBailianHTTPASRConfig.self, forKey: .aliyunBailianHTTP) ?? AliyunBailianHTTPASRConfig()
        aliyunBailian = try container.decodeIfPresent(AliyunBailianASRConfig.self, forKey: .aliyunBailian) ?? AliyunBailianASRConfig()
        volcengine = try container.decodeIfPresent(VolcengineASRConfig.self, forKey: .volcengine) ?? VolcengineASRConfig()
        volcengineTraditional = try container.decodeIfPresent(VolcengineTraditionalASRConfig.self, forKey: .volcengineTraditional) ?? VolcengineTraditionalASRConfig()
        xunfei = try container.decodeIfPresent(XunfeiASRConfig.self, forKey: .xunfei) ?? XunfeiASRConfig()
        openAICompatible = try container.decodeIfPresent(OpenAICompatibleASRConfig.self, forKey: .openAICompatible) ?? OpenAICompatibleASRConfig()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(selectedPlatform, forKey: .selectedPlatform)
        if mimo.hasUserConfiguration { try container.encode(mimo, forKey: .mimo) }
        if let source = local.mirrorSource, !source.isEmpty { try container.encode(local, forKey: .local) }
        if !tencentCloud.appID.isEmpty || !tencentCloud.secretId.isEmpty || !tencentCloud.secretKey.isEmpty { try container.encode(tencentCloud, forKey: .tencentCloud) }
        if !aliyun.accessKeyId.isEmpty || !aliyun.accessKeySecret.isEmpty || !aliyun.appKey.isEmpty { try container.encode(aliyun, forKey: .aliyun) }
        if aliyunBailianHTTP.hasUserConfiguration { try container.encode(aliyunBailianHTTP, forKey: .aliyunBailianHTTP) }
        if aliyunBailian.hasUserConfiguration { try container.encode(aliyunBailian, forKey: .aliyunBailian) }
        if volcengine.hasUserConfiguration { try container.encode(volcengine, forKey: .volcengine) }
        if volcengineTraditional.hasUserConfiguration { try container.encode(volcengineTraditional, forKey: .volcengineTraditional) }
        if !xunfei.realtimeAPIKey.isEmpty || !xunfei.appID.isEmpty || !xunfei.apiKey.isEmpty || !xunfei.apiSecret.isEmpty { try container.encode(xunfei, forKey: .xunfei) }
        if openAICompatible.hasUserConfiguration { try container.encode(openAICompatible, forKey: .openAICompatible) }
    }

    func isReady(localModelsAvailable: Bool) -> Bool {
        switch selectedPlatform {
        case .localSenseVoice:
            return localModelsAvailable
        case .tencentCloudSentence:
            return tencentCloud.sentenceState.isReady
        case .tencentCloudRealtime:
            return tencentCloud.isReady
        case .aliyunSentence:
            return aliyun.sentenceState.isReady
        case .aliyunRealtime:
            return aliyun.isReady
        case .aliyunBailianHTTPASR:
            return aliyunBailianHTTP.isReady
        case .aliyunBailianASR:
            return aliyunBailian.isReady
        case .volcengineRealtime:
            return volcengine.isReady
        case .volcengineBigModelSentence:
            return volcengine.bigModelSentenceState.isReady
        case .volcengineSentence:
            return volcengine.fileState.isReady
        case .volcengineTraditionalSentence:
            return volcengineTraditional.sentenceState.isReady
        case .volcengineTraditionalRealtime:
            return volcengineTraditional.realtimeState.isReady
        case .xunfeiIAT:
            return xunfei.iatState.isReady
        case .xunfeiRealtime:
            return xunfei.isReady
        case .mimoASR:
            return mimo.isReady
        case .openAICompatibleASR:
            return openAICompatible.isReady
        }
    }

    func notReadyReason(localModelsAvailable: Bool) -> String? {
        guard !isReady(localModelsAvailable: localModelsAvailable) else { return nil }

        switch selectedPlatform {
        case .localSenseVoice:
            return "本地模型未下载，请在设置页下载"
        case .tencentCloudSentence:
            return tencentCloud.sentenceState.notReadyReason(platformName: "腾讯云一句话")
        case .tencentCloudRealtime:
            return tencentCloud.notReadyReason(platformName: "腾讯云")
        case .aliyunSentence:
            return aliyun.sentenceState.notReadyReason(platformName: "阿里云一句话")
        case .aliyunRealtime:
            return aliyun.notReadyReason(platformName: "阿里云")
        case .aliyunBailianHTTPASR:
            return aliyunBailianHTTP.notReadyReason(platformName: "阿里云百炼语音识别")
        case .aliyunBailianASR:
            return aliyunBailian.notReadyReason(platformName: "阿里云百炼")
        case .volcengineRealtime:
            return volcengine.notReadyReason(platformName: "火山引擎")
        case .volcengineBigModelSentence:
            return volcengine.bigModelSentenceState.notReadyReason(platformName: "火山引擎大模型一句话")
        case .volcengineSentence:
            return volcengine.fileState.notReadyReason(platformName: "火山引擎录音文件极速版")
        case .volcengineTraditionalSentence:
            return volcengineTraditional.sentenceState.notReadyReason(platformName: "火山引擎传统一句话")
        case .volcengineTraditionalRealtime:
            return volcengineTraditional.realtimeState.notReadyReason(platformName: "火山引擎传统实时")
        case .xunfeiIAT:
            return xunfei.iatState.notReadyReason(platformName: "科大讯飞语音听写")
        case .xunfeiRealtime:
            return xunfei.notReadyReason(platformName: "科大讯飞")
        case .mimoASR:
            return mimo.notReadyReason(platformName: "小米 MiMo")
        case .openAICompatibleASR:
            return openAICompatible.notReadyReason(platformName: "OpenAI 兼容")
        }
    }
}

/// 本地 ASR 模型状态
enum LocalModelStatus: String, Codable, Equatable, Sendable {
    case notDownloaded = "notDownloaded"
    case downloading = "downloading"
    case ready = "ready"
    case failed = "failed"
}

enum CloudASRValidationStatus: String, Codable, Equatable, Sendable {
    case unvalidated = "unvalidated"
    case validating = "validating"
    case verified = "verified"
    case failed = "failed"
}

protocol CloudASRConfigState: Sendable {
    var isComplete: Bool { get }
    var validationStatus: CloudASRValidationStatus { get set }
    var lastValidationError: String? { get set }
    func incompleteReason(platformName: String) -> String
}

extension CloudASRConfigState {
    var isReady: Bool {
        isComplete && validationStatus == .verified
    }

    func notReadyReason(platformName: String) -> String {
        if !isComplete {
            return incompleteReason(platformName: platformName)
        }

        switch validationStatus {
        case .verified:
            return "\(platformName) ASR 未知未就绪状态"
        case .validating:
            return "\(platformName) ASR 正在验证，请稍候"
        case .unvalidated:
            return "\(platformName) ASR 尚未通过真实请求验证，请先在设置页完成验证"
        case .failed:
            if let lastValidationError,
               !lastValidationError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "\(platformName) ASR 验证失败：\(lastValidationError)"
            }
            return "\(platformName) ASR 验证失败，请检查配置并重试"
        }
    }

    func incompleteReason(platformName: String) -> String {
        "\(platformName) ASR 配置不完整，请补全必填字段"
    }
}

/// 本地 ASR 配置
struct LocalASRConfig: Codable, Equatable, Sendable {
    // Persist user input only; status and errors belong to the current process.
    private enum CodingKeys: String, CodingKey { case mirrorSource }

    var modelStatus: LocalModelStatus = .notDownloaded
    var lastError: String?
    var mirrorSource: String?

    /// 模型固定版本标识
    static let modelVersion = "sensevoice-small-onnx-int8-2024-07-17"

    static let modelFileName = "model.int8.onnx"
    static let tokensFileName = "tokens.txt"

    /// 模型根目录
    static var modelRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".memoecho/models/sensevoice-small-onnx", isDirectory: true)
    }

    static var requiredFileNames: [String] {
        [modelFileName, tokensFileName]
    }
}

/// 腾讯云实时识别配置
struct TencentASRConfig: Codable, Equatable, Sendable {
    // Persist user input only; status and errors belong to the current process.
    private enum CodingKeys: String, CodingKey { case appID, secretId, secretKey }

    var appID: String = ""
    var secretId: String = ""
    var secretKey: String = ""
    var validationStatus: CloudASRValidationStatus = .unvalidated
    var lastValidationError: String?
    var sentenceValidationStatus: CloudASRValidationStatus = .unvalidated
    var sentenceLastValidationError: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appID = try c.decodeIfPresent(String.self, forKey: .appID) ?? ""
        secretId = try c.decodeIfPresent(String.self, forKey: .secretId) ?? ""
        secretKey = try c.decodeIfPresent(String.self, forKey: .secretKey) ?? ""
    }

    var isComplete: Bool {
        !appID.isEmpty && appID.allSatisfy(\.isNumber) && !secretId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !secretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// 阿里云智能语音交互实时识别配置
struct AliyunASRConfig: Codable, Equatable, Sendable {
    // Persist user input only; status and errors belong to the current process.
    private enum CodingKeys: String, CodingKey { case accessKeyId, accessKeySecret, appKey }

    var accessKeyId: String = ""
    var accessKeySecret: String = ""
    var appKey: String = ""
    var validationStatus: CloudASRValidationStatus = .unvalidated
    var lastValidationError: String?
    var sentenceValidationStatus: CloudASRValidationStatus = .unvalidated
    var sentenceLastValidationError: String?


    init() {}


    var isComplete: Bool {
        !accessKeyId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !accessKeySecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !appKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum VolcengineASRModelVersion: String, Codable, CaseIterable, Sendable {
    case v2 = "2.0"
    case v1 = "1.0"
    var resourceID: String {
        switch self {
        case .v1: "volc.bigasr.sauc.duration"
        case .v2: "volc.seedasr.sauc.duration"
        }
    }
}

/// File and large-model WebSocket services share credentials, but never verification state.
struct VolcengineASRConfig: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey { case apiKey, modelVersion }
    var apiKey = ""
    var modelVersion: VolcengineASRModelVersion = .v2
    var validationStatus: CloudASRValidationStatus = .unvalidated
    var lastValidationError: String?
    var bigModelSentenceValidationStatus: CloudASRValidationStatus = .unvalidated
    var bigModelSentenceValidationError: String?
    var fileValidationStatus: CloudASRValidationStatus = .unvalidated
    var fileLastValidationError: String?

    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        apiKey = try values.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        modelVersion = try values.decodeIfPresent(VolcengineASRModelVersion.self, forKey: .modelVersion) ?? .v2
    }
    var isComplete: Bool {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return !key.isEmpty && key.rangeOfCharacter(from: .controlCharacters) == nil
    }
    var hasUserConfiguration: Bool { !apiKey.isEmpty || modelVersion != .v2 }
    var fileState: SentenceASRState {
        .init(isComplete: isComplete, validationStatus: fileValidationStatus,
              lastValidationError: fileLastValidationError, requiredFields: " API Key")
    }
    var bigModelSentenceState: SentenceASRState {
        .init(isComplete: isComplete, validationStatus: bigModelSentenceValidationStatus,
              lastValidationError: bigModelSentenceValidationError, requiredFields: " API Key")
    }
}

/// 讯飞 IAT 与 RTASR 使用各自产品的凭据和验证状态。
struct XunfeiASRConfig: Codable, Equatable, Sendable {
    // Persist user input only; status and errors belong to the current process.
    private enum CodingKeys: String, CodingKey { case appID, apiKey, apiSecret, realtimeAPIKey }

    var appID: String = ""
    var apiKey: String = ""
    var apiSecret: String = ""
    var realtimeAPIKey: String = ""
    var validationStatus: CloudASRValidationStatus = .unvalidated
    var lastValidationError: String?
    var iatValidationStatus: CloudASRValidationStatus = .unvalidated
    var iatLastValidationError: String?


    init() {}


    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appID = try c.decodeIfPresent(String.self, forKey: .appID) ?? ""
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        apiSecret = try c.decodeIfPresent(String.self, forKey: .apiSecret) ?? ""
        realtimeAPIKey = try c.decodeIfPresent(String.self, forKey: .realtimeAPIKey) ?? ""
    }

    var isComplete: Bool {
        !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !realtimeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}


extension TencentASRConfig: CloudASRConfigState {
    func incompleteReason(platformName: String) -> String {
        "\(platformName) ASR 配置不完整，请填写 AppID、SecretId 和 SecretKey"
    }
}

extension AliyunASRConfig: CloudASRConfigState {
    func incompleteReason(platformName: String) -> String {
        "\(platformName) ASR 配置不完整，请填写 AccessKey ID、AccessKey Secret 和 AppKey"
    }
}

extension VolcengineASRConfig: CloudASRConfigState {
    func incompleteReason(platformName: String) -> String {
        "\(platformName) ASR 配置不完整，请填写 API Key"
    }
}

extension XunfeiASRConfig: CloudASRConfigState {
    func incompleteReason(platformName: String) -> String {
        "\(platformName) ASR 配置不完整，请填写 AppID 和实时转写 RTASR API Key"
    }
}


// MARK: - 通用配置

struct AudioInputConfig: Codable, Equatable, Sendable {
    var selectedDeviceID: String?

    private enum Selection: String, Codable { case automatic, systemDefault, device }
    private enum CodingKeys: String, CodingKey { case selection, deviceID }

    init(selectedDeviceID: String?) { self.selectedDeviceID = selectedDeviceID }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Selection.self, forKey: .selection) {
        case .automatic: selectedDeviceID = Self.automaticSelectionID
        case .systemDefault: selectedDeviceID = nil
        case .device: selectedDeviceID = try container.decode(String.self, forKey: .deviceID)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if usesAutomaticSelection {
            try container.encode(Selection.automatic, forKey: .selection)
        } else if let selectedDeviceID {
            try container.encode(Selection.device, forKey: .selection)
            try container.encode(selectedDeviceID, forKey: .deviceID)
        } else {
            try container.encode(Selection.systemDefault, forKey: .selection)
        }
    }

    static let automaticSelectionID = "__memoecho_automatic__"
    static let automatic = AudioInputConfig(selectedDeviceID: automaticSelectionID)

    var usesAutomaticSelection: Bool { selectedDeviceID == Self.automaticSelectionID }

    static let systemDefault = AudioInputConfig(
        selectedDeviceID: nil
    )

    var usesSystemDefault: Bool {
        selectedDeviceID == nil
    }
}

struct AudioInputDevice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    var transport: AudioDeviceTransport = .unknown
    var isUsable: Bool = true
}

enum AudioDeviceTransport: Sendable {
    case builtIn, bluetooth, external, unknown
}

struct GeneralConfig: Codable, Equatable, Sendable {
    var hotkey: HotkeyCombo = .default
    var interactionSoundEnabled: Bool = true
    var translationTargetLanguage: TranslationTargetLanguage = .english
    var windowContextEnabled: Bool = true

    init(
        hotkey: HotkeyCombo = .default,
        interactionSoundEnabled: Bool = true,
        translationTargetLanguage: TranslationTargetLanguage = .english,
        windowContextEnabled: Bool = true
    ) {
        self.hotkey = hotkey
        self.interactionSoundEnabled = interactionSoundEnabled
        self.translationTargetLanguage = translationTargetLanguage
        self.windowContextEnabled = windowContextEnabled
    }
}

// MARK: - 快捷键组合

enum HotkeyKind: String, Codable, Equatable, Sendable {
    case standard
    case special
}

enum HotkeyModifierKey: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case command
    case option
    case control
    case shift
    case function

    /// Fn／🌐 键的按住状态位；`NSEvent.ModifierFlags.function` 在新版 SDK 已废弃，改用原始值。
    static let functionFlag = NSEvent.ModifierFlags(rawValue: 0x800000)

    var genericFlags: NSEvent.ModifierFlags {
        switch self {
        case .command:
            .command
        case .option:
            .option
        case .control:
            .control
        case .shift:
            .shift
        case .function:
            Self.functionFlag
        }
    }

    var symbol: String {
        switch self {
        case .command:
            "⌘"
        case .option:
            "⌥"
        case .control:
            "⌃"
        case .shift:
            "⇧"
        case .function:
            "Fn"
        }
    }

    var displayName: String {
        switch self {
        case .command:
            "Command"
        case .option:
            "Option"
        case .control:
            "Control"
        case .shift:
            "Shift"
        case .function:
            "Fn"
        }
    }

    var shortDisplayName: String {
        symbol
    }

    var sortPriority: Int {
        switch self {
        case .control:
            0
        case .option:
            1
        case .shift:
            2
        case .command:
            3
        case .function:
            4
        }
    }
}

enum HotkeyModifierSide: String, Codable, Equatable, Hashable, Sendable {
    case left
    case right
    case either

    var prefix: String {
        switch self {
        case .left:
            "Left "
        case .right:
            "Right "
        case .either:
            ""
        }
    }

    var shortPrefix: String {
        switch self {
        case .left:
            "L "
        case .right:
            "R "
        case .either:
            ""
        }
    }
}

struct HotkeyModifierSpec: Codable, Equatable, Hashable, Sendable {
    var key: HotkeyModifierKey
    var side: HotkeyModifierSide

    init(key: HotkeyModifierKey, side: HotkeyModifierSide = .either) {
        self.key = key
        self.side = side
    }

    var displayString: String {
        "\(side.shortPrefix)\(key.shortDisplayName)"
    }
}

struct HotkeyCombo: Codable, Equatable, Sendable {
    var kind: HotkeyKind
    var keyCode: UInt16?
    var modifiers: UInt
    var specialModifiers: [HotkeyModifierSpec]
    var displayString: String

    init(
        kind: HotkeyKind,
        keyCode: UInt16?,
        modifiers: UInt,
        specialModifiers: [HotkeyModifierSpec] = [],
        displayString: String
    ) {
        self.kind = kind
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.specialModifiers = specialModifiers.sorted(by: Self.compareModifierSpecs)
        self.displayString = displayString
    }

    init(keyCode: UInt16, modifiers: UInt, displayString: String) {
        self.init(
            kind: .standard,
            keyCode: keyCode,
            modifiers: modifiers,
            displayString: displayString
        )
    }

    static func standard(
        keyCode: UInt16,
        modifiers: UInt,
        keyLabel: String,
        physicalModifiers: [HotkeyModifierSpec] = []
    ) -> HotkeyCombo {
        let sortedPhysicalModifiers = physicalModifiers.sorted(by: compareModifierSpecs)
        return HotkeyCombo(
            kind: .standard,
            keyCode: keyCode,
            modifiers: modifiers,
            specialModifiers: sortedPhysicalModifiers,
            displayString: standardDisplayString(
                modifiers: modifiers,
                physicalModifiers: sortedPhysicalModifiers,
                keyLabel: keyLabel
            )
        )
    }

    static func special(modifiers specs: [HotkeyModifierSpec]) -> HotkeyCombo {
        let sortedSpecs = specs.sorted(by: compareModifierSpecs)
        let genericModifiers = sortedSpecs.reduce(into: NSEvent.ModifierFlags()) { partialResult, spec in
            partialResult.formUnion(spec.key.genericFlags)
        }

        return HotkeyCombo(
            kind: .special,
            keyCode: nil,
            modifiers: genericModifiers.rawValue,
            specialModifiers: sortedSpecs,
            displayString: specialDisplayString(for: sortedSpecs)
        )
    }

    var isPureModifier: Bool {
        kind == .special
    }

    static let `default` = HotkeyCombo.special(
        modifiers: [HotkeyModifierSpec(key: .command, side: .right)]
    )

    private enum CodingKeys: String, CodingKey {
        case kind
        case keyCode
        case modifiers
        case specialModifiers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedKind = try container.decode(HotkeyKind.self, forKey: .kind)
        let decodedSpecialModifiers = try container.decodeIfPresent([HotkeyModifierSpec].self, forKey: .specialModifiers) ?? []
        let decodedModifiers = try container.decode(UInt.self, forKey: .modifiers)

        kind = decodedKind
        modifiers = decodedModifiers
        specialModifiers = decodedSpecialModifiers.sorted(by: Self.compareModifierSpecs)

        switch decodedKind {
        case .standard:
            let resolvedKeyCode = try container.decode(UInt16.self, forKey: .keyCode)
            keyCode = resolvedKeyCode
            let keyLabel = HotkeyPresentation.keyToken(for: resolvedKeyCode).visualLabel
            displayString = Self.standardDisplayString(
                modifiers: decodedModifiers,
                physicalModifiers: decodedSpecialModifiers,
                keyLabel: keyLabel
            )
        case .special:
            keyCode = nil
            displayString = Self.specialDisplayString(for: decodedSpecialModifiers)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(modifiers, forKey: .modifiers)
        if !specialModifiers.isEmpty {
            try container.encode(specialModifiers, forKey: .specialModifiers)
        }
        switch kind {
        case .standard:
            try container.encode(keyCode, forKey: .keyCode)
        case .special:
            break
        }
    }

    private static func standardDisplayString(
        modifiers: UInt,
        physicalModifiers: [HotkeyModifierSpec],
        keyLabel: String
    ) -> String {
        let sortedPhysicalModifiers = physicalModifiers.sorted(by: compareModifierSpecs)
        let coveredKeys = Set(sortedPhysicalModifiers.map(\.key))
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var parts = sortedPhysicalModifiers.map(\.displayString)

        if flags.contains(.control), !coveredKeys.contains(.control) {
            parts.append(HotkeyModifierKey.control.shortDisplayName)
        }
        if flags.contains(.option), !coveredKeys.contains(.option) {
            parts.append(HotkeyModifierKey.option.shortDisplayName)
        }
        if flags.contains(.shift), !coveredKeys.contains(.shift) {
            parts.append(HotkeyModifierKey.shift.shortDisplayName)
        }
        if flags.contains(.command), !coveredKeys.contains(.command) {
            parts.append(HotkeyModifierKey.command.shortDisplayName)
        }
        parts.append(keyLabel)
        return parts.joined(separator: " + ")
    }

    private static func specialDisplayString(for specs: [HotkeyModifierSpec]) -> String {
        specs
            .sorted(by: compareModifierSpecs)
            .map(\.displayString)
            .joined(separator: " + ")
    }

    private static func compareModifierSpecs(_ lhs: HotkeyModifierSpec, _ rhs: HotkeyModifierSpec) -> Bool {
        if lhs.key.sortPriority != rhs.key.sortPriority {
            return lhs.key.sortPriority < rhs.key.sortPriority
        }
        let lhsSide = sidePriority(lhs.side)
        let rhsSide = sidePriority(rhs.side)
        if lhsSide != rhsSide {
            return lhsSide < rhsSide
        }
        return lhs.key.rawValue < rhs.key.rawValue
    }

    private static func sidePriority(_ side: HotkeyModifierSide) -> Int {
        switch side {
        case .either:
            0
        case .left:
            1
        case .right:
            2
        }
    }

}


/// A service-specific view over shared credentials, with independent validation state.
struct SentenceASRState: CloudASRConfigState {
    let isComplete: Bool
    var validationStatus: CloudASRValidationStatus
    var lastValidationError: String?
    let requiredFields: String
    func incompleteReason(platformName: String) -> String {
        "\(platformName) ASR 配置不完整，请填写\(requiredFields)"
    }
}

extension TencentASRConfig {
    var sentenceState: SentenceASRState {
        .init(isComplete: !secretId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !secretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              validationStatus: sentenceValidationStatus, lastValidationError: sentenceLastValidationError,
              requiredFields: " SecretId 和 SecretKey")
    }
}
extension AliyunASRConfig {
    var sentenceState: SentenceASRState {
        .init(isComplete: isComplete, validationStatus: sentenceValidationStatus,
              lastValidationError: sentenceLastValidationError, requiredFields: " AccessKey ID、AccessKey Secret 和 AppKey")
    }
}
extension XunfeiASRConfig {
    var iatState: SentenceASRState {
        .init(isComplete: !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !apiSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              validationStatus: iatValidationStatus, lastValidationError: iatLastValidationError,
              requiredFields: " AppID、IAT API Key 和 API Secret")
    }
}

enum ASRVendorGroup: String, CaseIterable, Identifiable {
    case local = "本地", tencent = "腾讯云", aliyun = "阿里云", volcengine = "火山引擎"
    case xunfei = "科大讯飞", xiaomi = "小米", custom = "自定义"
    var id: String { rawValue }
    var platforms: [ASRPlatform] {
        switch self {
        case .tencent:
            return [.tencentCloudRealtime, .tencentCloudSentence]
        case .aliyun:
            return [.aliyunBailianASR, .aliyunBailianHTTPASR, .aliyunRealtime, .aliyunSentence]
        case .volcengine:
            return [.volcengineRealtime, .volcengineBigModelSentence,
                    .volcengineSentence,
                    .volcengineTraditionalRealtime, .volcengineTraditionalSentence]
        case .xunfei:
            return [.xunfeiRealtime, .xunfeiIAT]
        default:
            return ASRPlatform.allCases.filter { $0.vendorGroup == self }
        }
    }
}

extension ASRPlatform {
    var vendorGroup: ASRVendorGroup {
        switch self {
        case .localSenseVoice: .local
        case .tencentCloudSentence, .tencentCloudRealtime: .tencent
        case .aliyunSentence, .aliyunRealtime, .aliyunBailianHTTPASR, .aliyunBailianASR: .aliyun
        case .volcengineRealtime, .volcengineBigModelSentence, .volcengineSentence, .volcengineTraditionalSentence, .volcengineTraditionalRealtime: .volcengine
        case .xunfeiIAT, .xunfeiRealtime: .xunfei
        case .mimoASR: .xiaomi
        case .openAICompatibleASR: .custom
        }
    }
    var pickerTitle: String { displayName }
}
