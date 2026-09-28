import CryptoKit
import Foundation

/// Restart-persistent application state. Credentials and transient errors never enter this file.
@MainActor
@Observable
final class AppStateStore {
    struct State: Codable, Equatable {
        var onboarding = OnboardingProgress()
        var confirmedHotkeyFingerprint: String?
        var verifiedCloudConfigurations: [String: String] = [:]
        var llmWithoutThinkingParameter: String?
    }

    private(set) var value = State()
    private let fileURL: URL

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("state.json")
        reload()
    }

    func reload() {
        // A damaged state file must not discard otherwise valid user settings or credentials.
        value = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: fileURL))) ?? State()
    }

    func reset() throws {
        try save(State())
    }

    func save(_ state: State) throws {
        try PrivateJSONFile.write(state, to: fileURL)
        value = state
    }

    static func fingerprint(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Both files use atomic replacement and owner-only access.
enum PrivateJSONFile {
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
