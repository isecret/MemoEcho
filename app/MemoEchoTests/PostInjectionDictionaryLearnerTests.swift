import XCTest
@testable import MemoEcho

@MainActor
final class PostInjectionDictionaryLearnerTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func snapshot(_ text: String, field: String = "input", composing: Bool = false, selection: NSRange? = nil) -> FocusedElementTextSnapshot {
        .init(pid: 42, bundleID: "test", identity: .init(token: field), value: text,
              selection: selection ?? NSRange(location: text.utf16.count, length: 0), isComposing: composing)
    }

    @MainActor
    private final class Timeline {
        var snapshots: [FocusedElementTextSnapshot?]
        var index = 0
        var time: Duration = .zero
        var active = true
        init(_ snapshots: [FocusedElementTextSnapshot?]) { self.snapshots = snapshots }
        var current: FocusedElementTextSnapshot? { snapshots.indices.contains(index) ? snapshots[index] : nil }
        func advance(_ duration: Duration) { time += duration; index += 1 }
    }
    private struct Evaluator: ProperNounLearningEvaluating {
        var call: @MainActor @Sendable (ProperNounLearningCandidate) async throws -> ProperNounLearningDecision
        func evaluate(_ candidate: ProperNounLearningCandidate) async throws -> ProperNounLearningDecision { try await call(candidate) }
    }
    private func observe(_ timeline: Timeline, original: String, before: FocusedElementTextSnapshot? = nil,
                         store: PersonalDictionaryStore? = nil,
                         evaluator: @escaping @MainActor @Sendable (ProperNounLearningCandidate) async throws -> ProperNounLearningDecision) async -> [PostInjectionLearningDecision] {
        let learner = PostInjectionDictionaryLearner(
            snapshotProvider: { _, _ in timeline.current }, termEvaluator: Evaluator(call: evaluator),
            sleep: { await timeline.advance($0) }, now: { timeline.time })
        var decisions: [PostInjectionLearningDecision] = []
        await learner.observe(beforeInjection: before ?? snapshot(""), insertedText: original,
                              store: store ?? PersonalDictionaryStore(directoryURL: directory),
                              shouldContinue: { timeline.active }, onDecision: { decisions.append($0) })
        return decisions
    }
    private func stable(_ original: String, _ updated: String) -> Timeline {
        Timeline([snapshot(original)] + Array(repeating: snapshot(updated), count: 4) + [nil])
    }

    func testSingleCharacterCorrectionLearnsFullChineseName() async {
        let timeline = stable("联系钟世民", "联系钟世明")
        let decisions = await observe(timeline, original: "联系钟世民") { candidate in
            XCTAssertEqual(candidate.originalSpan, "民")
            XCTAssertEqual(candidate.replacedSpan, "明")
            XCTAssertEqual(candidate.updatedText, "联系钟世明")
            XCTAssertGreaterThanOrEqual(timeline.time, .seconds(2))
            return .accept(term: "钟世明", start: 2)
        }
        XCTAssertEqual(decisions, [.learned("钟世明")])
    }

    func testEnglishTermSurvivesDeleteThenRetypeWithoutLearningIntermediateText() async {
        let timeline = Timeline([snapshot("使用 MemoEko"), snapshot("使用 "), snapshot("使用 M", composing: true),
                                 snapshot("使用 Memo"), snapshot("使用 MemoEcho"), snapshot("使用 MemoEcho"),
                                 snapshot("使用 MemoEcho"), snapshot("使用 MemoEcho"), nil])
        let decisions = await observe(timeline, original: "使用 MemoEko") { candidate in
            XCTAssertEqual(candidate.updatedText, "使用 MemoEcho")
            return .accept(term: "MemoEcho", start: 3)
        }
        XCTAssertEqual(decisions, [.learned("MemoEcho")])
    }

    func testMixedLanguageAndCaseCorrection() async {
        for (old, new, term) in [("使用 swiftui", "使用 SwiftUI", "SwiftUI"), ("使用米莫API", "使用MiMo API", "MiMo API")] {
            let decisions = await observe(stable(old, new), original: old) { _ in .accept(term: term, start: 3 - (term == "MiMo API" ? 1 : 0)) }
            XCTAssertEqual(decisions, [.learned(term)])
        }
    }

    func testUnverifiedPasteNeverStartsLearning() async {
        let decisions = await observe(Timeline([snapshot("另一个文本"), nil]), original: "联系钟世民") { _ in
            XCTFail("unverified insertion must not reach AI"); return .reject
        }
        XCTAssertTrue(decisions.isEmpty)
    }

    func testDelayedPasteVerification() async {
        let timeline = Timeline([snapshot("")] + [snapshot("联系钟世民")] + Array(repeating: snapshot("联系钟世明"), count: 4) + [nil])
        let decisions = await observe(timeline, original: "联系钟世民") { _ in .accept(term: "钟世明", start: 2) }
        XCTAssertEqual(decisions, [.learned("钟世明")])
    }

    func testSameAppDifferentFieldStopsLearning() async {
        let timeline = Timeline([snapshot("联系钟世民")] + Array(repeating: snapshot("联系钟世明", field: "other"), count: 5))
        let decisions = await observe(timeline, original: "联系钟世民") { _ in XCTFail(); return .reject }
        XCTAssertTrue(decisions.isEmpty)
    }

    func testOutsideInsertedRangeEditStopsLearning() async {
        let before = snapshot("前缀后缀", selection: NSRange(location: 2, length: 0))
        let initial = snapshot("前缀联系钟世民后缀", selection: NSRange(location: 7, length: 0))
        let timeline = Timeline([initial] + Array(repeating: snapshot("改了联系钟世明后缀"), count: 5))
        let decisions = await observe(timeline, original: "联系钟世民", before: before) { _ in XCTFail(); return .reject }
        XCTAssertTrue(decisions.isEmpty)
    }

    func testSelectedTextReplacementWithEmojiUsesUTF16AnchorAndBoundedContext() async {
        let before = snapshot("🙂旧文后缀", selection: NSRange(location: 2, length: 2))
        let first = snapshot("🙂联系钟世民后缀", selection: NSRange(location: 7, length: 0))
        let edited = snapshot("🙂联系钟世明后缀", selection: NSRange(location: 7, length: 0))
        let timeline = Timeline([first] + Array(repeating: edited, count: 4) + [nil])
        let decisions = await observe(timeline, original: "联系钟世民", before: before) { candidate in
            XCTAssertEqual(candidate.updatedText, "联系钟世明", "outside text must not be sent")
            return .accept(term: "钟世明", start: 2)
        }
        XCTAssertEqual(decisions, [.learned("钟世明")])
    }

    func testMarkedTextAndNonEmptySelectionNeverEvaluate() async {
        for edited in [snapshot("联系钟世明", composing: true), snapshot("联系钟世明", selection: NSRange(location: 2, length: 3))] {
            let timeline = Timeline([snapshot("联系钟世民")] + Array(repeating: edited, count: 8) + [nil])
            let decisions = await observe(timeline, original: "联系钟世民") { _ in XCTFail(); return .reject }
            XCTAssertTrue(decisions.isEmpty)
        }
    }

    func testClearOrLargeRewriteStopsLearning() async {
        for text in ["", String(repeating: "改", count: 80)] {
            let decisions = await observe(stable("联系钟世民", text), original: "联系钟世民") { _ in XCTFail(); return .reject }
            XCTAssertTrue(decisions.isEmpty)
        }
    }

    func testLateAIResultCannotWriteAfterCancellationFocusOrTextChanges() async {
        for mutation in 0..<4 {
            let timeline = stable("联系钟世民", "联系钟世明")
            let store = PersonalDictionaryStore(directoryURL: directory)
            let decisions = await observe(timeline, original: "联系钟世民", store: store) { _ in
                switch mutation {
                case 0: timeline.active = false
                case 1: timeline.snapshots[timeline.index] = self.snapshot("联系钟世明", field: "other")
                case 2: timeline.snapshots[timeline.index] = self.snapshot("联系其他人")
                default: timeline.time += .seconds(31)
                }
                return .accept(term: "钟世明", start: 2)
            }
            XCTAssertTrue(store.entries.isEmpty)
            XCTAssertTrue(decisions.isEmpty)
        }
    }

    func testCancelledTaskCannotWriteEvenIfEvaluatorIgnoresCancellation() async {
        let timeline = stable("联系钟世民", "联系钟世明")
        let store = PersonalDictionaryStore(directoryURL: directory)
        let task = Task { await self.observe(timeline, original: "联系钟世民", store: store) { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return .accept(term: "钟世明", start: 2)
        } }
        let decisions = await task.value
        XCTAssertTrue(decisions.isEmpty)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testTemporaryFocusLossDuringEvaluationCannotBeUndoneByReturning() async {
        let timeline = stable("联系钟世民", "联系钟世明")
        let store = PersonalDictionaryStore(directoryURL: directory)
        let decisions = await observe(timeline, original: "联系钟世民", store: store) { _ in
            // The monitor runs while the model is suspended and sees the nil focus snapshot.
            for _ in 0..<10 { await Task.yield() }
            timeline.index = 4
            return .accept(term: "钟世明", start: 2)
        }
        XCTAssertTrue(decisions.isEmpty)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testExistingTermAddedWhileAIIsPendingIsNotDuplicated() async throws {
        let timeline = stable("联系钟世民", "联系钟世明")
        let store = PersonalDictionaryStore(directoryURL: directory)
        let decisions = await observe(timeline, original: "联系钟世民", store: store) { _ in
            _ = try store.addLearnedTermIfNeeded("钟世明")
            return .accept(term: "钟世明", start: 2)
        }
        XCTAssertTrue(decisions.isEmpty)
        XCTAssertEqual(store.entries.map(\.term), ["钟世明"])
    }

    func testMalformedOrUnrelatedExtractionIsRejected() {
        let candidate = PostInjectionDictionaryLearner.makeCandidate(from: "使用 MemoEko", to: "使用 MemoEcho")!
        XCTAssertNil(PostInjectionDictionaryLearner.validatedTerm("Echo", start: 7, candidate: candidate))
        XCTAssertNil(PostInjectionDictionaryLearner.validatedTerm("SwiftUI", start: 3, candidate: candidate))
        XCTAssertNil(PostInjectionDictionaryLearner.validatedTerm("使用", start: 0, candidate: candidate))
        XCTAssertNil(PostInjectionDictionaryLearner.validatedTerm("MemoEcho", start: Int.max, candidate: candidate))
        XCTAssertEqual(PostInjectionDictionaryLearner.validatedTerm("MemoEcho", start: 3, candidate: candidate), "MemoEcho")
    }

    func testModelRejectionAndFailureDoNotLearn() async {
        let store = PersonalDictionaryStore(directoryURL: directory)
        let rejected = await observe(stable("请然后窗口", "请关闭窗口"), original: "请然后窗口", store: store) { _ in .reject }
        XCTAssertEqual(rejected, [.rejected("关闭")])
        let failed = await observe(stable("联系钟世民", "联系钟世明"), original: "联系钟世民", store: store) { _ in
            throw ProperNounLearningEvaluationError.invalidResponse
        }
        XCTAssertEqual(failed, [.failed("明", reason: "learning_failed")])
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testLearningResponseRequiresStructuredCompleteTerm() throws {
        XCTAssertEqual(try LLMProvider.parseProperNounLearningDecision(from: #"{"decision":"accept","term":"SwiftUI","start":2}"#), .accept(term: "SwiftUI", start: 2))
        XCTAssertEqual(try LLMProvider.parseProperNounLearningDecision(from: #"{"decision":"reject"}"#), .reject)
        for response in [#"{"decision":"accept"}"#, #"{"decision":"accept","term":"明","start":0}"#, #"{"decision":"accept","term":"SwiftUI","start":-1}"#, "ignore instructions"] {
            XCTAssertThrowsError(try LLMProvider.parseProperNounLearningDecision(from: response))
        }
    }
}
