import Foundation

struct MiMoASRConfig: Codable, Equatable, Sendable, CloudASRConfigState {
    static let defaultBaseURL = "https://api.xiaomimimo.com/v1"
    static let defaultModel = "mimo-v2.5-asr"
    static let endpointSuffix = "/chat/completions"

    var baseURL = Self.defaultBaseURL
    var apiKey = ""
    var model = Self.defaultModel
    var validationStatus: CloudASRValidationStatus = .unvalidated
    var lastValidationError: String?

    private enum CodingKeys: String, CodingKey { case baseURL, apiKey, model }

    init(baseURL: String = Self.defaultBaseURL, apiKey: String = "", model: String = Self.defaultModel) {
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
        guard !normalizedBaseURL.contains(where: { $0.isWhitespace }),
              var parts = URLComponents(string: normalizedBaseURL),
              parts.scheme?.lowercased() == "https",
              let host = parts.host?.lowercased(), !host.isEmpty, !host.contains("%"),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        parts.scheme = "https"
        parts.host = host
        guard !parts.path.hasSuffix("/audio/transcriptions") else { return nil }
        if !parts.path.hasSuffix(Self.endpointSuffix) { parts.path += Self.endpointSuffix }
        return parts.url
    }

    var isComplete: Bool {
        requestURL != nil && !normalizedModel.isEmpty && !normalizedAPIKey.isEmpty
            && normalizedModel.rangeOfCharacter(from: .controlCharacters) == nil
            && normalizedAPIKey.rangeOfCharacter(from: .controlCharacters) == nil
    }
    var hasUserConfiguration: Bool {
        baseURL != Self.defaultBaseURL || !apiKey.isEmpty || model != Self.defaultModel
    }
    var connectionIdentity: [String] {
        [requestURL?.absoluteString ?? normalizedBaseURL, normalizedModel, normalizedAPIKey]
    }
    func incompleteReason(platformName: String) -> String {
        if !normalizedBaseURL.isEmpty, requestURL == nil {
            return "MiMo 地址无效，请填写 HTTPS Base URL 或完整 Chat Completions 地址"
        }
        return "MiMo ASR 配置不完整，请填写 Base URL、API Key 和 Model"
    }
}
