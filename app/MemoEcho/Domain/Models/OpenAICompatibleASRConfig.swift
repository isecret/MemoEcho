import Darwin
import Foundation

enum OpenAIASRFormat: String, Codable, CaseIterable, Sendable {
    case audioTranscriptions
    // Decode legacy configurations only; no request may use this protocol.
    case chatCompletions

    var displayName: String {
        switch self {
        case .audioTranscriptions: "Audio Transcriptions"
        case .chatCompletions: "Chat Completions"
        }
    }

    var endpointSuffix: String {
        switch self {
        case .audioTranscriptions: "/audio/transcriptions"
        case .chatCompletions: "/chat/completions"
        }
    }
}

struct OpenAICompatibleASRConfig: Codable, Equatable, Sendable, CloudASRConfigState {
    var apiFormat: OpenAIASRFormat = .audioTranscriptions
    var baseURL = ""
    var apiKey = ""
    var model = ""
    var validationStatus: CloudASRValidationStatus = .unvalidated
    var lastValidationError: String?

    private enum CodingKeys: String, CodingKey { case apiFormat, baseURL, apiKey, model }

    init(apiFormat: OpenAIASRFormat = .audioTranscriptions, baseURL: String = "", apiKey: String = "", model: String = "") {
        self.apiFormat = apiFormat
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        apiFormat = try values.decodeIfPresent(OpenAIASRFormat.self, forKey: .apiFormat) ?? .audioTranscriptions
        baseURL = try values.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        apiKey = try values.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? ""
    }

    var normalizedBaseURL: String {
        var result = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }
    var normalizedAPIKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    var normalizedModel: String { model.trimmingCharacters(in: .whitespacesAndNewlines) }

    var requestURL: URL? {
        guard apiFormat == .audioTranscriptions else { return nil }
        let value = normalizedBaseURL
        guard !value.contains(where: { $0.isWhitespace }),
              var parts = URLComponents(string: value),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host?.lowercased(), !host.isEmpty, !host.contains("%"),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        guard scheme == "https" || Self.isLocalHost(host) else { return nil }
        parts.scheme = scheme
        parts.host = host
        if let endpoint = OpenAIASRFormat.allCases.first(where: { parts.path.hasSuffix($0.endpointSuffix) }) {
            guard endpoint == apiFormat else { return nil }
        } else {
            parts.path += apiFormat.endpointSuffix
        }
        return parts.url
    }

    var isComplete: Bool {
        requestURL != nil && !normalizedModel.isEmpty
            && normalizedModel.rangeOfCharacter(from: .controlCharacters) == nil
            && normalizedAPIKey.rangeOfCharacter(from: .controlCharacters) == nil
    }
    var hasUserConfiguration: Bool {
        apiFormat != .audioTranscriptions || !baseURL.isEmpty || !apiKey.isEmpty || !model.isEmpty
    }
    var connectionIdentity: [String] {
        [apiFormat.rawValue, requestURL?.absoluteString ?? normalizedBaseURL, normalizedModel, normalizedAPIKey]
    }
    func incompleteReason(platformName: String) -> String {
        if apiFormat == .chatCompletions {
            return "原 Chat Completions 语音配置已停用。MiMo 请在独立入口重新配置；其他服务请重新配置 Audio Transcriptions"
        }
        if !normalizedBaseURL.isEmpty, requestURL == nil {
            return "地址或接口格式不匹配，请填写 HTTPS 地址，或本机、局域网 HTTP 地址"
        }
        return "\(platformName) ASR 配置不完整，请填写 Base URL 和 Model，API Key 可选"
    }

    private static func isLocalHost(_ host: String) -> Bool {
        let name = host.hasSuffix(".") ? String(host.dropLast()) : host
        if name == "localhost" || (name.hasSuffix(".local") && name.count > 6) { return true }
        let pieces = name.split(separator: ".", omittingEmptySubsequences: false)
        if pieces.count == 4 {
            let octets = pieces.compactMap { part -> Int? in
                guard let value = Int(part), (0...255).contains(value), String(value) == part else { return nil }
                return value
            }
            if octets.count == 4 {
                return octets[0] == 127 || octets[0] == 10
                    || (octets[0] == 172 && (16...31).contains(octets[1]))
                    || (octets[0] == 192 && octets[1] == 168)
            }
        }
        let ipv6 = name.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var address = in6_addr()
        guard inet_pton(AF_INET6, ipv6, &address) == 1 else { return false }
        return withUnsafeBytes(of: address) { bytes in
            (bytes[0] & 0xfe) == 0xfc || (bytes.prefix(15).allSatisfy { $0 == 0 } && bytes[15] == 1)
        }
    }
}
