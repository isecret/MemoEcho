import Foundation

/// Immutable, request-ready selection from a recording's personal dictionary.
/// This is never persisted and contains only terms, not pronunciation hints or user context.
struct ASRHotwords: Sendable, Equatable {
    let terms: [String]
    static let empty = ASRHotwords(terms: [], platform: .localSenseVoice)

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
        case .aliyunBailianASR, .aliyunBailianHTTPASR:
            var selected: [String] = []
            var seen: Set<String> = []
            for original in terms {
                let term = original.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !term.isEmpty, !term.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { continue }
                let valid = term.unicodeScalars.contains(where: { !$0.isASCII })
                    ? term.unicodeScalars.count <= 15
                    : term.split(separator: " ").count <= 7
                guard valid, seen.insert(term.precomposedStringWithCanonicalMapping.lowercased()).inserted else { continue }
                selected.append(term)
                if selected.count == 2000 { break }
            }
            self.terms = selected
            return
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

    /// Only documented Qwen-Audio models accept inline vocabulary. Custom models remain usable.
    func bailianVocabulary(model: String, realtime: Bool) -> [String: Int]? {
        let supported = realtime
            ? ["qwen-audio-3.1-asr-flash-streaming", "qwen-audio-3.0-asr-flash-streaming"]
            : ["qwen-audio-3.1-asr-flash", "qwen-audio-3.0-asr-flash"]
        guard supported.contains(model), !terms.isEmpty else { return nil }
        return Dictionary(uniqueKeysWithValues: terms.map { ($0, 4) })
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
