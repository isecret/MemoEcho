import Foundation

/// 个人词典存储，管理用户维护的专有名词、术语等词条
///
/// 存储位置：`~/.memoecho/dictionary.json`（文件权限 0600）
/// 词条字段：`term`（必填）、`pronunciationHint`、`category`
/// 不存储历史输入文本或 ASR/LLM 响应正文
@MainActor
@Observable
final class PersonalDictionaryStore {

    private(set) var entries: [DictionaryEntry] = []
    private(set) var latestLearnedEntryID: String?

    var latestLearnedEntry: DictionaryEntry? {
        entries.first { $0.id == latestLearnedEntryID && $0.source == .autoLearned }
    }

    private let directoryURL: URL
    private let dictionaryURL: URL

    // MARK: - 存储路径

    private static let defaultDirectoryURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".memoecho", isDirectory: true)
    }()

    // MARK: - 初始化

    init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL ?? Self.defaultDirectoryURL
        self.dictionaryURL = self.directoryURL.appendingPathComponent("dictionary.json")
        loadEntries()
    }

    // MARK: - CRUD

    func addEntry(_ entry: DictionaryEntry) throws {
        let previousEntries = entries
        entries.append(entry)
        do {
            try save()
        } catch {
            entries = previousEntries
            throw error
        }
    }

    @discardableResult
    func addLearnedTermIfNeeded(_ term: String) throws -> Bool {
        let normalized = normalizedTerm(term)
        guard !normalized.isEmpty,
              !entries.contains(where: { normalizedTermKey($0.term) == normalizedTermKey(normalized) }) else { return false }
        let previous = entries
        let entry = DictionaryEntry(term: normalized, source: .autoLearned)
        entries.append(entry)
        do { try save() }
        catch { entries = previous; throw error }
        latestLearnedEntryID = entry.id
        return true
    }

    func removeEntry(id: String) throws {
        let previousEntries = entries
        entries.removeAll { $0.id == id }
        do {
            try save()
            if latestLearnedEntryID == id { latestLearnedEntryID = nil }
        } catch {
            entries = previousEntries
            throw error
        }
    }

    func updateEntry(_ entry: DictionaryEntry) throws {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let previousEntries = entries
        var updated = entry
        updated.source = .manual
        entries[index] = updated
        do {
            try save()
        } catch {
            entries = previousEntries
            throw error
        }
    }

    @discardableResult
    func importEntries(from fileURL: URL) throws -> DictionaryImportSummary {
        let terms = try DictionaryCSV.decode(String(contentsOf: fileURL, encoding: .utf8))
        let previousEntries = entries
        var mergedEntries = entries
        var indices = Dictionary(entries.enumerated().map { (normalizedTermKey($0.element.term), $0.offset) },
                                 uniquingKeysWith: { first, _ in first })
        var importedCount = 0
        var skippedDuplicateCount = 0

        for term in terms {
            let termKey = normalizedTermKey(term)
            if let index = indices[termKey] {
                if mergedEntries[index].source == .autoLearned {
                    mergedEntries[index].source = .manual
                    importedCount += 1
                } else {
                    skippedDuplicateCount += 1
                }
                continue
            }
            indices[termKey] = mergedEntries.count
            mergedEntries.append(DictionaryEntry(term: term, source: .manual))
            importedCount += 1
        }

        entries = mergedEntries
        do {
            try save()
        } catch {
            entries = previousEntries
            throw error
        }

        return DictionaryImportSummary(
            importedCount: importedCount,
            skippedDuplicateCount: skippedDuplicateCount
        )
    }

    func exportEntries(to fileURL: URL) throws {
        let csv = try DictionaryCSV.encode(entries.map(\.term))
        try csv.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Hotwords 生成

    /// 为本地 ASR 生成 hotwords 参数字符串（空格分隔）
    ///
    /// 优先使用 `pronunciationHint`（帮助 ASR 识别发音），若缺失则退回 `term`。
    func hotwordsForLocalASR() -> String {
        entries
            .compactMap { entry -> String? in
                let hint = entry.pronunciationHint?.trimmingCharacters(in: .whitespaces)
                if let hint, !hint.isEmpty {
                    return hint
                }
                return entry.term.isEmpty ? nil : entry.term
            }
            .joined(separator: " ")
    }

    /// 为 LLM Prompt 提供结构化术语参考（包含 term 和 pronunciationHint）
    func termsForPrompt() -> [TermReference] {
        entries
            .filter { !$0.term.isEmpty }
            .map { TermReference(term: $0.term, pronunciationHint: $0.pronunciationHint) }
    }

    // MARK: - 持久化

    private func loadEntries() {
        let url = dictionaryURL

        guard FileManager.default.fileExists(atPath: url.path) else {
            entries = []
            return
        }

        do {
            entries = try Self.decodeEntries(from: url)
        } catch {
            // 文件损坏时重置为空词典，不阻止应用启动
            entries = []
        }
    }

    private func save() throws {
        let fm = FileManager.default
        let dirURL = directoryURL
        let fileURL = dictionaryURL

        if !fm.fileExists(atPath: dirURL.path) {
            try fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dirURL.path)

        let encoder = Self.makeEncoder()
        let data = try encoder.encode(entries)

        try data.write(to: fileURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func decodeEntries(from fileURL: URL) throws -> [DictionaryEntry] {
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([DictionaryEntry].self, from: data)
    }

    private func normalizedTermKey(_ term: String) -> String {
        normalizedTerm(term).precomposedStringWithCanonicalMapping.lowercased()
    }

    private func normalizedTerm(_ term: String) -> String {
        term.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct DictionaryImportSummary: Equatable, Sendable {
    let importedCount: Int
    let skippedDuplicateCount: Int
}

// MARK: - Dictionary Entry Model

enum DictionaryEntrySource: String, Codable, Equatable, Sendable {
    case manual
    case autoLearned = "auto_learned"
}

struct DictionaryEntry: Codable, Identifiable, Equatable, Sendable {
    var id: String = UUID().uuidString
    var term: String
    var pronunciationHint: String?
    var category: String?
    var source: DictionaryEntrySource

    enum CodingKeys: String, CodingKey {
        case id, term, pronunciationHint, category, source
    }

    init(
        id: String = UUID().uuidString,
        term: String,
        pronunciationHint: String? = nil,
        category: String? = nil,
        source: DictionaryEntrySource = .manual
    ) {
        self.id = id
        self.term = term
        self.pronunciationHint = pronunciationHint
        self.category = category
        self.source = source
    }
}

// MARK: - Term Reference for LLM

/// 传递给 LLM 的术语参考，包含目标写法和发音提示
struct TermReference: Sendable, Equatable {
    let term: String
    let pronunciationHint: String?
}

/// UTF-8, one column, no header. A term occupies exactly one physical line.
private enum DictionaryCSV {
    enum FormatError: Error { case invalidRow(Int) }

    static func decode(_ text: String) throws -> [String] {
        var text = text
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        return try lines.enumerated().compactMap { index, line in
            let row = line.trimmingCharacters(in: .whitespaces)
            guard !row.isEmpty else { return nil }
            let term: String
            if row.first == "\"" {
                guard row.count >= 2, row.last == "\"" else { throw FormatError.invalidRow(index + 1) }
                let content = Array(row.dropFirst().dropLast())
                var decoded = ""
                var position = 0
                while position < content.count {
                    let character = content[position]
                    if character == "\"" {
                        guard position + 1 < content.count, content[position + 1] == "\"" else {
                            throw FormatError.invalidRow(index + 1)
                        }
                        position += 1
                    }
                    decoded.append(character)
                    position += 1
                }
                term = decoded.trimmingCharacters(in: .whitespaces)
            } else {
                guard !row.contains(","), !row.contains("\"") else { throw FormatError.invalidRow(index + 1) }
                term = row
            }
            return term.isEmpty ? nil : term
        }
    }

    static func encode(_ terms: [String]) throws -> String {
        let rows = try terms.enumerated().map { index, term in
            guard !term.contains("\n"), !term.contains("\r") else { throw FormatError.invalidRow(index + 1) }
            if term.contains(",") || term.contains("\"") {
                return "\"" + term.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return term
        }
        return rows.isEmpty ? "" : rows.joined(separator: "\n") + "\n"
    }
}
