import Foundation

struct AliyunBailianASRConfig: Codable, Equatable, Sendable, CloudASRConfigState {
    static let defaultBaseURL = "wss://dashscope.aliyuncs.com/api-ws/v1/inference"
    static let defaultModel = "paraformer-realtime-v2"
    static let endpointSuffix = "/api-ws/v1/inference"

    var baseURL: String = "wss://dashscope.aliyuncs.com/api-ws/v1/inference"
    var apiKey: String = ""
    var model: String = Self.defaultModel
    var validationStatus: CloudASRValidationStatus = .unvalidated
    var lastValidationError: String?

    // Runtime state must never be encoded with credentials.
    private enum CodingKeys: String, CodingKey { case baseURL, apiKey, model }

    init(baseURL: String = "wss://dashscope.aliyuncs.com/api-ws/v1/inference", apiKey: String = "", model: String = Self.defaultModel) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try values.decodeIfPresent(String.self, forKey: .baseURL) ?? Self.defaultBaseURL
        apiKey = try values.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? Self.defaultModel
    }

    var normalizedBaseURL: String {
        var value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    var normalizedAPIKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    var normalizedModel: String { model.trimmingCharacters(in: .whitespacesAndNewlines) }

    var requestURL: URL? {
        let value = normalizedBaseURL
        guard !value.contains(where: { $0.isWhitespace }),
              var parts = URLComponents(string: value),
              parts.scheme?.lowercased() == "wss",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { return nil }
        parts.scheme = "wss"
        parts.host = host.lowercased()
        guard parts.path == Self.endpointSuffix else { return nil }
        return parts.url
    }

    var isComplete: Bool {
        requestURL != nil && !normalizedModel.isEmpty && !normalizedAPIKey.isEmpty
            && normalizedAPIKey.rangeOfCharacter(from: .newlines) == nil
    }

    var hasUserConfiguration: Bool {
        baseURL != Self.defaultBaseURL || !apiKey.isEmpty || model != Self.defaultModel
    }

    // Use the actual request identity, so equivalent base/full URLs share validation.
    var connectionIdentity: [String] {
        [requestURL?.absoluteString ?? normalizedBaseURL, normalizedModel, normalizedAPIKey]
    }

    func incompleteReason(platformName: String) -> String {
        if !normalizedBaseURL.isEmpty, requestURL == nil {
            return "\(platformName)地址无效，请填写以 /api-ws/v1/inference 结尾的 WSS 地址"
        }
        return "\(platformName) ASR 配置不完整，请填写实时 WSS 地址、API Key 和 Model"
    }
}
