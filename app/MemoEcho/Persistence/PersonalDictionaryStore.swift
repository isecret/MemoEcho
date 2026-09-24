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
        guard !normalized.isEmpty else { return false }

        let alreadyExists = entries.contains { normalizedTerm($0.term) == normalized }
        guard !alreadyExists else { return false }

        entries.append(DictionaryEntry(term: normalized, source: .autoLearned))
        try save()
        return true
    }

    func removeEntry(id: String) throws {
        let previousEntries = entries
        entries.removeAll { $0.id == id }
        do {
            try save()
        } catch {
            entries = previousEntries
            throw error
        }
    }

    func updateEntry(_ entry: DictionaryEntry) throws {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let previousEntries = entries
        entries[index] = entry
        do {
            try save()
        } catch {
            entries = previousEntries
            throw error
        }
    }

    @discardableResult
    func importEntries(from fileURL: URL) throws -> DictionaryImportSummary {
        let importedEntries = try Self.decodeEntries(from: fileURL)
        let previousEntries = entries
        let existingTerms = Set(entries.map { normalizedTermKey($0.term) })
        var knownTerms = existingTerms
        var knownIDs = Set(entries.map(\.id))
        var mergedEntries = entries
        var addedCount = 0
        var skippedDuplicateCount = 0

        for importedEntry in importedEntries {
            let termKey = normalizedTermKey(importedEntry.term)
            guard !termKey.isEmpty else { continue }

            if knownTerms.contains(termKey) {
                skippedDuplicateCount += 1
                continue
            }

            var entry = importedEntry
            entry.term = termKey
            if knownIDs.contains(entry.id) {
                entry.id = UUID().uuidString
            }

            mergedEntries.append(entry)
            knownTerms.insert(termKey)
            knownIDs.insert(entry.id)
            addedCount += 1
        }

        entries = mergedEntries
        do {
            try save()
        } catch {
            entries = previousEntries
            throw error
        }

        return DictionaryImportSummary(
            importedCount: addedCount,
            skippedDuplicateCount: skippedDuplicateCount
        )
    }

    func exportEntries(to fileURL: URL) throws {
        let encoder = Self.makeEncoder()
        let data = try encoder.encode(entries)
        try data.write(to: fileURL, options: .atomic)
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
        normalizedTerm(term)
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
