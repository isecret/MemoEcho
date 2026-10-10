import Foundation

/// Immutable, request-ready selection from a recording's personal dictionary.
/// This is never persisted and contains only terms, not pronunciation hints or user context.
struct VolcengineHotwords: Sendable, Equatable {
    let terms: [String]
    static let empty = VolcengineHotwords(terms: [], platform: .localSenseVoice)

    init(terms: [String], platform: ASRPlatform) {
        let maximumWords: Int
        let maximumBytes: Int
        switch platform {
        case .volcengineRealtime, .volcengineBigModelSentence, .volcengineSentence:
            maximumWords = 5000
            // Shared client limit, validated with 5000 synthetic terms on all three endpoints.
            // Request acceptance does not establish that every term affects recognition.
            // Keep a separate memory/payload bound.
            maximumBytes = 256 * 1024
        default:
            self.terms = []
            return
        }
        var selected: [String] = []
        var seen: Set<String> = []
        var bytes = 15 // {"hotwords":[]}
        for original in terms {
            let term = original.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = term.precomposedStringWithCanonicalMapping.lowercased()
            guard !term.isEmpty, seen.insert(key).inserted else { continue }
            // JSONEncoder below does not escape slashes. Count JSON string escaping too.
            let stringBytes = term.unicodeScalars.reduce(0) { count, scalar in
                switch scalar.value {
                case 0..<0x20: count + 6 // conservative even for short escapes (\n etc.)
                case 0x22, 0x5c: count + 2
                default: count + String(scalar).utf8.count
                }
            }
            let entryBytes = 11 + stringBytes + (selected.isEmpty ? 0 : 1)
            guard selected.count < maximumWords, entryBytes <= maximumBytes - bytes else { break }
            selected.append(term)
            bytes += entryBytes
        }
        self.terms = selected
    }

    /// Context must be a JSON STRING nested within the outer request JSON.
    func context() throws -> String? {
        guard !terms.isEmpty else { return nil }
        struct Word: Encodable { let word: String }
        struct Context: Encodable { let hotwords: [Word] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(Context(hotwords: terms.map { Word(word: $0) })), as: UTF8.self)
    }
}
