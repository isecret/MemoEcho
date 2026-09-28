import XCTest
@testable import MemoEcho

final class PersonalDictionaryStoreTests: XCTestCase {

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
    func testCSVImportNormalizesDuplicatesAndMakesAllImportedWordsManual() throws {
        let store = PersonalDictionaryStore(directoryURL: tempDirectory)
        try store.addEntry(DictionaryEntry(term: "MemoEcho"))
        _ = try store.addLearnedTermIfNeeded("SenseVoice")
        let originalID = store.entries[1].id
        let file = tempDirectory.appendingPathComponent("terms.csv")
        try "\u{FEFF}memoecho\r\nSENSEVOICE\r\n FunASR \r\nfunasr\r\n\r\n\"ACME, Inc.\"\r\n\"Say \"\"Hi\"\"\"\r\n".write(to: file, atomically: true, encoding: .utf8)
        let summary = try store.importEntries(from: file)
        XCTAssertEqual(summary, DictionaryImportSummary(importedCount: 4, skippedDuplicateCount: 2))
        XCTAssertEqual(store.entries.map(\.term), ["MemoEcho", "SenseVoice", "FunASR", "ACME, Inc.", "Say \"Hi\""])
        XCTAssertTrue(store.entries.allSatisfy { $0.source == .manual })
        XCTAssertEqual(store.entries[1].id, originalID)
        XCTAssertEqual(PersonalDictionaryStore(directoryURL: tempDirectory).entries, store.entries)
    }

    @MainActor
    func testMalformedCSVRejectsEntireImportWithoutChangingExistingEntries() throws {
        let store = PersonalDictionaryStore(directoryURL: tempDirectory)
        try store.addEntry(DictionaryEntry(term: "MemoEcho"))
        let file = tempDirectory.appendingPathComponent("invalid.csv")
        for malformed in ["Valid\nwrong,column\n", "Valid\n\"unclosed", "\"a\",\"b\"", "\"line\nbreak\"", "unescaped\"quote"] {
            try malformed.write(to: file, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try store.importEntries(from: file))
            XCTAssertEqual(store.entries.map(\.term), ["MemoEcho"])
        }
    }

    @MainActor
    func testCSVExportContainsOnlyTermsAndRoundTripsAsManualWords() throws {
        let store = PersonalDictionaryStore(directoryURL: tempDirectory)
        try store.addEntry(DictionaryEntry(term: "MemoEcho", pronunciationHint: "memo", category: "Product"))
        _ = try store.addLearnedTermIfNeeded("ACME, Inc.")
        _ = try store.addLearnedTermIfNeeded("Say \"Hi\"")
        let file = tempDirectory.appendingPathComponent("export.csv")
        try store.exportEntries(to: file)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "MemoEcho\n\"ACME, Inc.\"\n\"Say \"\"Hi\"\"\"\n")
        let imported = PersonalDictionaryStore(directoryURL: tempDirectory.appendingPathComponent("other"))
        XCTAssertEqual(try imported.importEntries(from: file).importedCount, 3)
        XCTAssertEqual(imported.entries.map(\.term), store.entries.map(\.term))
        XCTAssertTrue(imported.entries.allSatisfy { $0.source == .manual && $0.pronunciationHint == nil && $0.category == nil })
    }

    @MainActor
    func testCSVImportRollsBackNewAndConvertedTermsOnSaveFailure() throws {
        let store = PersonalDictionaryStore(directoryURL: tempDirectory)
        _ = try store.addLearnedTermIfNeeded("MemoEcho")
        let original = store.entries
        try FileManager.default.removeItem(at: dictionaryFileURL)
        try FileManager.default.createDirectory(at: dictionaryFileURL, withIntermediateDirectories: true)
        let file = tempDirectory.appendingPathComponent("import.csv")
        try "MemoEcho\nNew Word\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.importEntries(from: file))
        XCTAssertEqual(store.entries, original)
    }

    @MainActor
    func testEmptyCSVHasNoHeaderOrWords() throws {
        let store = PersonalDictionaryStore(directoryURL: tempDirectory)
        let file = tempDirectory.appendingPathComponent("empty.csv")
        try store.exportEntries(to: file)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "")
        XCTAssertEqual(try store.importEntries(from: file).importedCount, 0)
        try "\u{FEFF}\r\n  \n\"\"\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try store.importEntries(from: file).importedCount, 0)
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
    @MainActor
    func testDeleteLearnedTermPersistsAndAllowsLearningAgain() throws {
        let store = PersonalDictionaryStore(directoryURL: tempDirectory)
        XCTAssertTrue(try store.addLearnedTermIfNeeded("MemoEcho"))
        let entry = try XCTUnwrap(store.latestLearnedEntry)
        try store.removeEntry(id: entry.id)
        XCTAssertNil(store.latestLearnedEntry)
        XCTAssertTrue(store.termsForPrompt().isEmpty)
        XCTAssertEqual(store.hotwordsForLocalASR(), "")
        let reloaded = PersonalDictionaryStore(directoryURL: tempDirectory)
        XCTAssertTrue(reloaded.entries.isEmpty)
        XCTAssertTrue(try reloaded.addLearnedTermIfNeeded("MemoEcho"))
        XCTAssertEqual(reloaded.termsForPrompt().map(\.term), ["MemoEcho"])
    }

    @MainActor
    func testAutoLearnAndDeleteRollBackOnWriteFailure() throws {
        let store = PersonalDictionaryStore(directoryURL: tempDirectory)
        XCTAssertTrue(try store.addLearnedTermIfNeeded("MemoEcho"))
        let previous = store.entries
        let id = try XCTUnwrap(store.latestLearnedEntryID)
        try FileManager.default.removeItem(at: dictionaryFileURL)
        try FileManager.default.createDirectory(at: dictionaryFileURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.addLearnedTermIfNeeded("SwiftUI"))
        XCTAssertEqual(store.entries, previous)
        XCTAssertEqual(store.latestLearnedEntryID, id)
        XCTAssertThrowsError(try store.removeEntry(id: id))
        XCTAssertEqual(store.entries, previous)
        XCTAssertNotNil(store.latestLearnedEntry)
    }

    @MainActor
    func testDeletedLearnedTermCanBeImported() throws {
        let store = PersonalDictionaryStore(directoryURL: tempDirectory)
        _ = try store.addLearnedTermIfNeeded("MemoEcho")
        try store.removeEntry(id: XCTUnwrap(store.latestLearnedEntryID))
        let file = tempDirectory.appendingPathComponent("import.csv")
        let data = Data("MEMOECHO\n".utf8)
        try data.write(to: file)
        XCTAssertEqual(try store.importEntries(from: file).importedCount, 1)
        XCTAssertEqual(store.termsForPrompt().map(\.term), ["MEMOECHO"])
    }

}
