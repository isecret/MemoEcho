import Foundation

enum DictionaryFilter: CaseIterable, Identifiable {
    case all, autoAdded, manualAdded

    var id: Self { self }
    var title: String {
        switch self {
        case .all: "全部"
        case .autoAdded: "自动添加"
        case .manualAdded: "手动添加"
        }
    }
    func includes(_ entry: DictionaryEntry) -> Bool {
        switch self {
        case .all: true
        case .autoAdded: entry.source == .autoLearned
        case .manualAdded: entry.source == .manual
        }
    }
}

@MainActor
@Observable
final class PersonalDictionaryViewModel {
    enum ValidationError: String, Equatable {
        case empty = "请输入词条"
        case duplicate = "词条已存在"
        case saveFailed = "保存失败"
        case importFailed = "导入失败，请使用 UTF-8 单列 CSV，每行一个词，无表头"
        case exportFailed = "导出失败"
    }

    var selectedFilter: DictionaryFilter = .all
    var errorMessage: String?
    var statusMessage: String?

    private let store: PersonalDictionaryStore

    init(store: PersonalDictionaryStore) {
        self.store = store
    }

    var entries: [DictionaryEntry] {
        store.entries
    }

    var totalCount: Int {
        entries.count
    }

    func filteredEntries(matching query: String) -> [DictionaryEntry] {
        let query = normalizedTerm(query)
        return entries.filter { selectedFilter.includes($0) && (query.isEmpty || $0.term.localizedCaseInsensitiveContains(query)) }
    }

    @discardableResult
    func addTerm(_ term: String) -> Bool {
        let term = normalizedTerm(term)
        guard validateTerm(term, editingID: nil) else { return false }

        do {
            try store.addEntry(DictionaryEntry(term: term))
            statusMessage = nil
            clearError()
            return true
        } catch {
            showError(.saveFailed)
            return false
        }
    }

    func neighboringEntryID(afterDeleting id: String, matching query: String = "") -> String? {
        let entries = filteredEntries(matching: query)
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        if index + 1 < entries.count {
            return entries[index + 1].id
        }
        if index > 0 {
            return entries[index - 1].id
        }
        return nil
    }

    @discardableResult
    func deleteEntry(_ entry: DictionaryEntry) -> Bool {
        do {
            try store.removeEntry(id: entry.id)
            statusMessage = nil
            clearError()
            return true
        } catch {
            showError(.saveFailed)
            return false
        }
    }

    func importEntries(from fileURL: URL) {
        do {
            let summary = try store.importEntries(from: fileURL)
            clearError()
            if summary.importedCount == 0 {
                statusMessage = summary.skippedDuplicateCount > 0 ? "没有导入新词条，重复词条已跳过" : "没有可导入的词条"
            } else if summary.skippedDuplicateCount > 0 {
                statusMessage = "已导入 \(summary.importedCount) 个词条，跳过 \(summary.skippedDuplicateCount) 个重复词条"
            } else {
                statusMessage = "已导入 \(summary.importedCount) 个词条"
            }
        } catch {
            showError(.importFailed)
        }
    }

    func exportEntries(to fileURL: URL) {
        do {
            try store.exportEntries(to: fileURL)
            clearError()
            statusMessage = "已导出 \(entries.count) 个词条"
        } catch {
            showError(.exportFailed)
        }
    }

    @discardableResult
    func commitTermUpdate(id: String, term: String) -> Bool {
        let term = normalizedTerm(term)
        guard let entry = entries.first(where: { $0.id == id }) else { return false }
        guard term != normalizedTerm(entry.term) else {
            clearError()
            return true
        }

        if term.isEmpty {
            showError(.empty)
            return false
        }

        guard validateTerm(term, editingID: id) else { return false }

        var updated = entry
        updated.term = term

        do {
            try store.updateEntry(updated)
            statusMessage = nil
            clearError()
            return true
        } catch {
            showError(.saveFailed)
            return false
        }
    }

    private func validateTerm(_ term: String, editingID: String?) -> Bool {
        guard !term.isEmpty else {
            showError(.empty)
            return false
        }

        let hasDuplicate = entries.contains { entry in
            entry.id != editingID && normalizedTerm(entry.term).precomposedStringWithCanonicalMapping.lowercased() == term.precomposedStringWithCanonicalMapping.lowercased()
        }
        guard !hasDuplicate else {
            showError(.duplicate)
            return false
        }

        return true
    }

    private func normalizedTerm(_ term: String) -> String {
        term.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func showError(_ error: ValidationError) {
        errorMessage = error.rawValue
        statusMessage = nil
    }

    private func clearError() {
        errorMessage = nil
    }
}
