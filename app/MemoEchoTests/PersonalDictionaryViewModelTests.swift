import XCTest
@testable import MemoEcho

final class PersonalDictionaryViewModelTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    @MainActor
    func testAddTermCreatesTermWithNilOptionalFields() {
        let viewModel = makeViewModel()

        XCTAssertTrue(viewModel.addTerm("  MemoEcho  "))

        XCTAssertEqual(viewModel.entries.count, 1)
        XCTAssertEqual(viewModel.entries[0].term, "MemoEcho")
        XCTAssertNil(viewModel.entries[0].pronunciationHint)
        XCTAssertNil(viewModel.entries[0].category)
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testAddTermRejectsEmptyAndDuplicateTerms() {
        let viewModel = makeViewModel()

        XCTAssertFalse(viewModel.addTerm(" "))
        XCTAssertEqual(viewModel.errorMessage, PersonalDictionaryViewModel.ValidationError.empty.rawValue)
        XCTAssertTrue(viewModel.entries.isEmpty)

        XCTAssertTrue(viewModel.addTerm("MemoEcho"))
        XCTAssertFalse(viewModel.addTerm("  MemoEcho  "))
        XCTAssertEqual(viewModel.errorMessage, PersonalDictionaryViewModel.ValidationError.duplicate.rawValue)
        XCTAssertEqual(viewModel.entries.map(\.term), ["MemoEcho"])
    }

    @MainActor
    func testAddTermSaveFailureKeepsEntriesUnchangedAndShowsError() throws {
        let dictionaryURL = tempDirectory.appendingPathComponent("dictionary.json")
        try FileManager.default.createDirectory(at: dictionaryURL, withIntermediateDirectories: true)
        let viewModel = makeViewModel()

        XCTAssertFalse(viewModel.addTerm("MemoEcho"))
        XCTAssertTrue(viewModel.entries.isEmpty)
        XCTAssertEqual(viewModel.errorMessage, PersonalDictionaryViewModel.ValidationError.saveFailed.rawValue)
    }

    @MainActor
    func testSearchIsCaseInsensitiveAndDoesNotChangePersistedOrder() {
        let viewModel = makeViewModel()
        XCTAssertTrue(viewModel.addTerm("MemoEcho"))
        XCTAssertTrue(viewModel.addTerm("SenseVoice"))
        XCTAssertTrue(viewModel.addTerm("企业微信"))

        XCTAssertEqual(viewModel.filteredEntries(matching: "memo").map(\.term), ["MemoEcho"])
        XCTAssertEqual(viewModel.filteredEntries(matching: "VOICE").map(\.term), ["SenseVoice"])
        XCTAssertEqual(viewModel.filteredEntries(matching: "  ").map(\.term), ["MemoEcho", "SenseVoice", "企业微信"])
        XCTAssertEqual(viewModel.filteredEntries(matching: "不存在").map(\.term), [])
        XCTAssertEqual(viewModel.entries.map(\.term), ["MemoEcho", "SenseVoice", "企业微信"])
        XCTAssertEqual(viewModel.totalCount, 3)
    }

    @MainActor
    func testCommittedEditPersistsImmediately() {
        let viewModel = makeViewModel()
        viewModel.addTerm("旧词")
        let id = viewModel.entries[0].id

        let didCommit = viewModel.commitTermUpdate(id: id, term: " 新词 ")

        XCTAssertTrue(didCommit)
        XCTAssertEqual(viewModel.entries[0].term, "新词")
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testEditRejectsEmptyAndDuplicateTerms() {
        let viewModel = makeViewModel()
        viewModel.addTerm("MemoEcho")
        viewModel.addTerm("SenseVoice")
        let editedID = viewModel.entries[0].id

        XCTAssertFalse(viewModel.commitTermUpdate(id: editedID, term: " "))
        XCTAssertEqual(viewModel.errorMessage, PersonalDictionaryViewModel.ValidationError.empty.rawValue)
        XCTAssertEqual(viewModel.entries.map(\.term), ["MemoEcho", "SenseVoice"])

        XCTAssertFalse(viewModel.commitTermUpdate(id: editedID, term: "SenseVoice"))
        XCTAssertEqual(viewModel.errorMessage, PersonalDictionaryViewModel.ValidationError.duplicate.rawValue)
        XCTAssertEqual(viewModel.entries.first(where: { $0.id == editedID })?.term, "MemoEcho")
        XCTAssertEqual(viewModel.entries.map(\.term), ["MemoEcho", "SenseVoice"])
    }

    @MainActor
    func testDeleteEntryRemovesPersistedTerm() {
        let viewModel = makeViewModel()
        viewModel.addTerm("MemoEcho")
        let entry = viewModel.entries[0]

        XCTAssertEqual(viewModel.entries.count, 1)

        XCTAssertTrue(viewModel.deleteEntry(entry))
        XCTAssertTrue(viewModel.entries.isEmpty)

        let reloaded = PersonalDictionaryStore(directoryURL: tempDirectory)
        XCTAssertTrue(reloaded.entries.isEmpty)
    }

    @MainActor
    func testNeighboringSelectionAfterDeletingFirstMiddleAndLastEntries() {
        let viewModel = makeViewModel()
        XCTAssertTrue(viewModel.addTerm("甲"))
        XCTAssertTrue(viewModel.addTerm("乙"))
        XCTAssertTrue(viewModel.addTerm("丙"))
        let firstID = viewModel.entries[0].id
        let middleID = viewModel.entries[1].id
        let lastID = viewModel.entries[2].id

        XCTAssertEqual(viewModel.neighboringEntryID(afterDeleting: firstID), middleID)
        XCTAssertEqual(viewModel.neighboringEntryID(afterDeleting: middleID), lastID)
        XCTAssertEqual(viewModel.neighboringEntryID(afterDeleting: lastID), middleID)

        XCTAssertTrue(viewModel.deleteEntry(viewModel.entries[1]))
        XCTAssertEqual(viewModel.neighboringEntryID(afterDeleting: viewModel.entries[0].id), viewModel.entries[1].id)
        XCTAssertTrue(viewModel.deleteEntry(viewModel.entries[0]))
        XCTAssertEqual(viewModel.neighboringEntryID(afterDeleting: viewModel.entries[0].id), nil)
    }

    @MainActor
    func testEmptyEditKeepsOriginalTerm() {
        let viewModel = makeViewModel()
        viewModel.addTerm("MemoEcho")
        let id = viewModel.entries[0].id

        XCTAssertFalse(viewModel.commitTermUpdate(id: id, term: " "))

        XCTAssertEqual(viewModel.errorMessage, PersonalDictionaryViewModel.ValidationError.empty.rawValue)
        XCTAssertEqual(viewModel.entries.map(\.term), ["MemoEcho"])

        let reloaded = PersonalDictionaryStore(directoryURL: tempDirectory)
        XCTAssertEqual(reloaded.entries.map(\.term), ["MemoEcho"])
    }

    @MainActor
    func testImportEntriesUpdatesListAndStatusMessage() throws {
        let viewModel = makeViewModel()
        viewModel.addTerm("MemoEcho")

        let importURL = tempDirectory.appendingPathComponent("import.csv")
        try "MemoEcho\nFunASR\n".write(to: importURL, atomically: true, encoding: .utf8)

        viewModel.importEntries(from: importURL)

        XCTAssertEqual(viewModel.entries.map(\.term), ["MemoEcho", "FunASR"])
        XCTAssertEqual(viewModel.statusMessage, "已导入 1 个词条，跳过 1 个重复词条")
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testImportInvalidCSVShowsError() throws {
        let viewModel = makeViewModel()
        viewModel.addTerm("MemoEcho")

        let importURL = tempDirectory.appendingPathComponent("invalid.csv")
        try "wrong,column".write(to: importURL, atomically: true, encoding: .utf8)

        viewModel.importEntries(from: importURL)

        XCTAssertEqual(viewModel.entries.map(\.term), ["MemoEcho"])
        XCTAssertEqual(viewModel.errorMessage, PersonalDictionaryViewModel.ValidationError.importFailed.rawValue)
        XCTAssertNil(viewModel.statusMessage)
    }

    @MainActor
    func testExportEntriesWritesFileAndStatusMessage() throws {
        let viewModel = makeViewModel()
        viewModel.addTerm("MemoEcho")

        let exportURL = tempDirectory.appendingPathComponent("export.csv")
        viewModel.exportEntries(to: exportURL)

        XCTAssertEqual(try String(contentsOf: exportURL, encoding: .utf8), "MemoEcho\n")
        XCTAssertEqual(viewModel.statusMessage, "已导出 1 个词条")
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testValidEditAfterEmptyEditPersistsAndClearsError() {
        let viewModel = makeViewModel()
        viewModel.addTerm("新词条")
        let id = viewModel.entries[0].id

        XCTAssertFalse(viewModel.commitTermUpdate(id: id, term: " "))
        XCTAssertEqual(viewModel.errorMessage, PersonalDictionaryViewModel.ValidationError.empty.rawValue)

        XCTAssertTrue(viewModel.commitTermUpdate(id: id, term: "MemoEcho"))
        XCTAssertEqual(viewModel.entries[0].term, "MemoEcho")
        XCTAssertNil(viewModel.errorMessage)

        let reloaded = PersonalDictionaryStore(directoryURL: tempDirectory)
        XCTAssertEqual(reloaded.entries.map(\.term), ["MemoEcho"])
    }

    @MainActor
    func testRepeatedCommitsKeepLatestTerm() {
        let viewModel = makeViewModel()
        viewModel.addTerm("旧词")
        let id = viewModel.entries[0].id

        XCTAssertTrue(viewModel.commitTermUpdate(id: id, term: "第一次"))
        XCTAssertTrue(viewModel.commitTermUpdate(id: id, term: "第二次"))

        XCTAssertEqual(viewModel.entries[0].term, "第二次")
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testExternalLearnedTermAppearsWithoutManualRefresh() throws {
        let store = PersonalDictionaryStore(directoryURL: tempDirectory)
        let viewModel = PersonalDictionaryViewModel(store: store)

        XCTAssertTrue(viewModel.entries.isEmpty)

        XCTAssertTrue(try store.addLearnedTermIfNeeded("朴邻"))

        XCTAssertEqual(viewModel.entries.map(\.term), ["朴邻"])
        XCTAssertEqual(viewModel.entries.first?.source, .autoLearned)
    }

    @MainActor
    func testDeletedAutomaticTermCanBeLearnedAgain() throws {
        let store = PersonalDictionaryStore(directoryURL: tempDirectory)
        let viewModel = PersonalDictionaryViewModel(store: store)
        _ = try store.addLearnedTermIfNeeded("MemoEcho")
        XCTAssertTrue(viewModel.deleteEntry(try XCTUnwrap(viewModel.entries.first)))
        XCTAssertEqual(viewModel.totalCount, 0)
        XCTAssertTrue(PersonalDictionaryStore(directoryURL: tempDirectory).entries.isEmpty)
        XCTAssertTrue(try store.addLearnedTermIfNeeded("MemoEcho"))
        XCTAssertEqual(viewModel.entries.first?.source, .autoLearned)
        XCTAssertFalse(viewModel.addTerm("memoecho"))
    }

    @MainActor
    func testSourceNavigationCombinesWithSearchAndKeepsGlobalOrder() throws {
        let store = PersonalDictionaryStore(directoryURL: tempDirectory)
        let viewModel = PersonalDictionaryViewModel(store: store)
        try store.addEntry(DictionaryEntry(term: "Manual Alpha"))
        _ = try store.addLearnedTermIfNeeded("Auto Alpha")
        _ = try store.addLearnedTermIfNeeded("Auto Beta")
        XCTAssertEqual(viewModel.filteredEntries(matching: "").count, 3)
        viewModel.selectedFilter = .autoAdded
        XCTAssertEqual(viewModel.filteredEntries(matching: "alpha").map(\.term), ["Auto Alpha"])
        XCTAssertEqual(viewModel.filteredEntries(matching: "").count, 2)
        viewModel.selectedFilter = .manualAdded
        XCTAssertEqual(viewModel.filteredEntries(matching: "ALPHA").map(\.term), ["Manual Alpha"])
        XCTAssertTrue(viewModel.filteredEntries(matching: "Beta").isEmpty)
        viewModel.selectedFilter = .all
        XCTAssertEqual(viewModel.filteredEntries(matching: "").map(\.term), ["Manual Alpha", "Auto Alpha", "Auto Beta"])
    }

    @MainActor
    func testDeleteNeighborStaysWithinFilterAndSearchResults() throws {
        let store = PersonalDictionaryStore(directoryURL: tempDirectory)
        let viewModel = PersonalDictionaryViewModel(store: store)
        _ = try store.addLearnedTermIfNeeded("Auto One")
        try store.addEntry(DictionaryEntry(term: "Manual One"))
        _ = try store.addLearnedTermIfNeeded("Auto Two")
        viewModel.selectedFilter = .autoAdded
        XCTAssertEqual(viewModel.neighboringEntryID(afterDeleting: store.entries[0].id), store.entries[2].id)
        XCTAssertNil(viewModel.neighboringEntryID(afterDeleting: store.entries[0].id, matching: "One"))
    }

    @MainActor
    func testEditedAndImportedAutoTermsMoveToManualFilter() throws {
        let store = PersonalDictionaryStore(directoryURL: tempDirectory)
        let viewModel = PersonalDictionaryViewModel(store: store)
        _ = try store.addLearnedTermIfNeeded("Auto One")
        _ = try store.addLearnedTermIfNeeded("Auto Two")
        XCTAssertTrue(viewModel.commitTermUpdate(id: store.entries[0].id, term: "Edited One"))
        let file = tempDirectory.appendingPathComponent("import.csv")
        try "Auto Two\n".write(to: file, atomically: true, encoding: .utf8)
        viewModel.importEntries(from: file)
        viewModel.selectedFilter = .manualAdded
        XCTAssertEqual(viewModel.filteredEntries(matching: "").count, 2)
        viewModel.selectedFilter = .autoAdded
        XCTAssertTrue(viewModel.filteredEntries(matching: "").isEmpty)
    }

    @MainActor
    private func makeViewModel() -> PersonalDictionaryViewModel {
        PersonalDictionaryViewModel(
            store: PersonalDictionaryStore(directoryURL: tempDirectory)
        )
    }
}
