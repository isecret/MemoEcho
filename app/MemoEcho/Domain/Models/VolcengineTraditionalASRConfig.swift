import Foundation

/// Traditional ASR uses console-issued application credentials, not the large-model API Key.
struct VolcengineTraditionalASRConfig: Codable, Equatable, Sendable {
    static let defaultSentenceCluster = "volcengine_input"
    static let defaultRealtimeCluster = "volcengine_streaming"

    var appID = ""
    var accessToken = ""
    var sentenceCluster = Self.defaultSentenceCluster
    var realtimeCluster = Self.defaultRealtimeCluster
    var sentenceValidationStatus: CloudASRValidationStatus = .unvalidated
    var sentenceLastValidationError: String?
    var realtimeValidationStatus: CloudASRValidationStatus = .unvalidated
    var realtimeLastValidationError: String?

    private enum CodingKeys: String, CodingKey { case appID, accessToken, sentenceCluster, realtimeCluster }

    init(appID: String = "", accessToken: String = "", sentenceCluster: String = Self.defaultSentenceCluster,
         realtimeCluster: String = Self.defaultRealtimeCluster) {
        self.appID = appID
        self.accessToken = accessToken
        self.sentenceCluster = sentenceCluster
        self.realtimeCluster = realtimeCluster
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        appID = try values.decodeIfPresent(String.self, forKey: .appID) ?? ""
        accessToken = try values.decodeIfPresent(String.self, forKey: .accessToken) ?? ""
        sentenceCluster = try values.decodeIfPresent(String.self, forKey: .sentenceCluster) ?? Self.defaultSentenceCluster
        realtimeCluster = try values.decodeIfPresent(String.self, forKey: .realtimeCluster) ?? Self.defaultRealtimeCluster
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(appID, forKey: .appID)
        try values.encode(accessToken, forKey: .accessToken)
        if normalizedSentenceCluster != Self.defaultSentenceCluster {
            try values.encode(normalizedSentenceCluster, forKey: .sentenceCluster)
        }
        if normalizedRealtimeCluster != Self.defaultRealtimeCluster {
            try values.encode(normalizedRealtimeCluster, forKey: .realtimeCluster)
        }
    }

    var normalizedAppID: String { appID.trimmingCharacters(in: .whitespacesAndNewlines) }
    var normalizedAccessToken: String { accessToken.trimmingCharacters(in: .whitespacesAndNewlines) }
    var normalizedSentenceCluster: String {
        let value = sentenceCluster.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? Self.defaultSentenceCluster : value
    }
    var normalizedRealtimeCluster: String {
        let value = realtimeCluster.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? Self.defaultRealtimeCluster : value
    }
    var hasUserConfiguration: Bool {
        !appID.isEmpty || !accessToken.isEmpty || normalizedSentenceCluster != Self.defaultSentenceCluster
            || normalizedRealtimeCluster != Self.defaultRealtimeCluster
    }
    var sentenceConnectionIdentity: [String] { [normalizedAppID, normalizedAccessToken, normalizedSentenceCluster] }
    var realtimeConnectionIdentity: [String] { [normalizedAppID, normalizedAccessToken, normalizedRealtimeCluster] }

    var sentenceState: SentenceASRState {
        .init(isComplete: Self.valid(sentenceConnectionIdentity), validationStatus: sentenceValidationStatus,
              lastValidationError: sentenceLastValidationError, requiredFields: " AppID 和 Access Token")
    }
    var realtimeState: SentenceASRState {
        .init(isComplete: Self.valid(realtimeConnectionIdentity), validationStatus: realtimeValidationStatus,
              lastValidationError: realtimeLastValidationError, requiredFields: " AppID 和 Access Token")
    }

    private static func valid(_ values: [String]) -> Bool {
        values.allSatisfy { !$0.isEmpty && $0.rangeOfCharacter(from: .controlCharacters) == nil }
    }
}
