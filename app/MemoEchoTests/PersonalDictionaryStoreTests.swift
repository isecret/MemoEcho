import XCTest
@testable import MemoEcho

final class PersonalDictionaryStoreTests: XCTestCase {

    @MainActor
    func testImportRequiresCurrentDictionaryEntryFormat() throws {
        let store = PersonalDictionaryStore(directoryURL: tempDirectory)
        let importURL = tempDirectory.appendingPathComponent("old-format.json")
        try Data(#"[{"id":"entry-1","term":"词条"}]"#.utf8).write(to: importURL)
        XCTAssertThrowsError(try store.importEntries(from: importURL))
        XCTAssertTrue(store.entries.isEmpty)
    }
    private var tempDirectory: URL!
    private var dictionaryFileURL: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        dictionaryFileURL = tempDirectory.appendingPathComponent("dictionary.json")
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    @MainActor
    func testAddEntryPersistsAtTopWithNilOptionalFields() throws {
        let store = PersonalDictionaryStore(directoryURL: tempDirectory)

        try store.addEntry(DictionaryEntry(term: "MemoEcho"))
        try store.addEntry(DictionaryEntry(term: "SenseVoice"))

        XCTAssertEqual(store.entries.map(\.term), ["MemoEcho", "SenseVoice"])
        XCTAssertNil(store.entries[0].pronunciationHint)
        XCTAssertNil(store.entries[0].category)
        XCTAssertEqual(store.entries[0].source, .manual)

        let reloaded = PersonalDictionaryStore(directoryURL: tempDirectory)
        XCTAssertEqual(reloaded.entries.map(\.term), ["MemoEcho", "SenseVoice"])
        XCTAssertNil(reloaded.entries[0].pronunciationHint)
        XCTAssertNil(reloaded.entries[0].category)
        XCTAssertEqual(reloaded.entries[0].source, .manual)
    }

    @MainActor
    func testUpdateAndDeletePersistAfterReload() throws {
        let store = PersonalDictionaryStore(directoryURL: tempDirectory)
        let entry = DictionaryEntry(term: "旧词")
        try store.addEntry(entry)

        var updated = entry
        updated.term = "新词"
        try store.updateEntry(updated)

        var reloaded = PersonalDictionaryStore(directoryURL: tempDirectory)
        XCTAssertEqual(reloaded.entries, [DictionaryEntry(id: entry.id, term: "新词")])

        try reloaded.removeEntry(id: entry.id)
        reloaded = PersonalDictionaryStore(directoryURL: tempDirectory)
        XCTAssertTrue(reloaded.entries.isEmpty)
    }

    @MainActor
    func testAllEntriesParticipateInHotwordsAndPromptTerms() throws {
        let store = PersonalDictionaryStore(directoryURL: tempDirectory)
        try store.addEntry(DictionaryEntry(term: "张三", pronunciationHint: "zhang san"))
        try store.addEntry(DictionaryEntry(term: "李四"))
        try store.addEntry(DictionaryEntry(term: "王五", pronunciationHint: nil))

        XCTAssertEqual(store.hotwordsForLocalASR(), "zhang san 李四 王五")
        XCTAssertEqual(
            store.termsForPrompt(),
            [
                TermReference(term: "张三", pronunciationHint: "zhang san"),
                TermReference(term: "李四", pronunciationHint: nil),
                TermReference(term: "王五", pronunciationHint: nil)
            ]
        )
    }

    @MainActor
    func testEmptyTermsAreExcludedFromHotwordsAndPromptTerms() throws {
        let store = PersonalDictionaryStore(directoryURL: tempDirectory)
        try store.addEntry(DictionaryEntry(term: ""))
        try store.addEntry(DictionaryEntry(term: "MemoEcho"))

        XCTAssertEqual(store.hotwordsForLocalASR(), "MemoEcho")
        XCTAssertEqual(store.termsForPrompt(), [TermReference(term: "MemoEcho", pronunciationHint: nil)])
    }

    @MainActor
    func testImportEntriesMergesJSONFileAndSkipsDuplicateTerms() throws {
        let store = PersonalDictionaryStore(directoryURL: tempDirectory)
        try store.addEntry(DictionaryEntry(id: "existing-id", term: "MemoEcho"))

        let importURL = tempDirectory.appendingPathComponent("import.json")
        let importJSON = """
        [
          {
            "id": "duplicate-id",
            "term": "MemoEcho",
            "source": "manual"
          },
          {
            "id": "existing-id",
            "term": "FunASR",
            "pronunciationHint": "fun a s r",
            "category": "ASR",
            "source": "manual"
          }
        ]
        """
        try importJSON.write(to: importURL, atomically: true, encoding: .utf8)

        let summary = try store.importEntries(from: importURL)

        XCTAssertEqual(summary, DictionaryImportSummary(importedCount: 1, skippedDuplicateCount: 1))
        XCTAssertEqual(store.entries.map(\.term), ["MemoEcho", "FunASR"])
        XCTAssertEqual(store.entries[1].pronunciationHint, "fun a s r")
        XCTAssertEqual(store.entries[1].category, "ASR")
        XCTAssertNotEqual(store.entries[1].id, "existing-id")

        let reloaded = PersonalDictionaryStore(directoryURL: tempDirectory)
        XCTAssertEqual(reloaded.entries.map(\.term), ["MemoEcho", "FunASR"])
    }

    @MainActor
    func testImportInvalidJSONThrowsAndKeepsExistingEntries() throws {
        let store = PersonalDictionaryStore(directoryURL: tempDirectory)
        try store.addEntry(DictionaryEntry(term: "MemoEcho"))

        let importURL = tempDirectory.appendingPathComponent("invalid.json")
        try "{ invalid".write(to: importURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try store.importEntries(from: importURL))
        XCTAssertEqual(store.entries.map(\.term), ["MemoEcho"])
    }

    @MainActor
    func testExportEntriesWritesDictionaryJSONFile() throws {
        let store = PersonalDictionaryStore(directoryURL: tempDirectory)
        try store.addEntry(DictionaryEntry(id: "entry-1", term: "MemoEcho"))
        try store.addEntry(DictionaryEntry(id: "entry-2", term: "FunASR", pronunciationHint: "fun a s r", category: "ASR"))

        let exportURL = tempDirectory.appendingPathComponent("export.json")
        try store.exportEntries(to: exportURL)

        let exportedEntries = try JSONDecoder().decode([DictionaryEntry].self, from: Data(contentsOf: exportURL))
        XCTAssertEqual(
            exportedEntries,
            [
                DictionaryEntry(id: "entry-1", term: "MemoEcho"),
                DictionaryEntry(id: "entry-2", term: "FunASR", pronunciationHint: "fun a s r", category: "ASR")
            ]
        )
    }

    @MainActor
    func testAutoLearnedTermPersistsWithSourceAndDeduplicates() throws {
        let store = PersonalDictionaryStore(directoryURL: tempDirectory)

        XCTAssertTrue(try store.addLearnedTermIfNeeded("朴邻"))
        XCTAssertFalse(try store.addLearnedTermIfNeeded("  朴邻  "))

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.term, "朴邻")
        XCTAssertEqual(store.entries.first?.source, .autoLearned)

        let reloaded = PersonalDictionaryStore(directoryURL: tempDirectory)
        XCTAssertEqual(reloaded.entries.first?.source, .autoLearned)
    }

    @MainActor
    func testAddEntryRollsBackWhenSaveFails() throws {
        let store = PersonalDictionaryStore(directoryURL: tempDirectory)
        if FileManager.default.fileExists(atPath: dictionaryFileURL.path) {
            try FileManager.default.removeItem(at: dictionaryFileURL)
        }
        try FileManager.default.createDirectory(at: dictionaryFileURL, withIntermediateDirectories: true)

        XCTAssertThrowsError(try store.addEntry(DictionaryEntry(term: "MemoEcho")))
        XCTAssertTrue(store.entries.isEmpty)
    }
}
