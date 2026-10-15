import XCTest
@testable import MemoEcho

final class LLMReferenceBudgetTests: XCTestCase {
    func testSmallDictionaryIsUnchangedAndDoesNotNormalizePronunciation() {
        let terms = [TermReference(term: "MemoEcho", pronunciationHint: "米莫"), .init(term: "钟世明", pronunciationHint: nil)]
        var calls = 0
        let result = LLMReferenceBudget.selectTerms(terms, text: "测试", phonetic: { _ in calls += 1; return "" })
        XCTAssertEqual(result.terms, terms)
        XCTAssertEqual(calls, 0)
    }

    func testRelevantTermsAtEndOfLargeDictionaryBeatFallbackPrefix() {
        let terms = fillerTerms() + [
            .init(term: "MemoEcho", pronunciationHint: nil),
            .init(term: "OpenAI", pronunciationHint: "欧喷爱"),
            .init(term: "钟世明", pronunciationHint: nil)
        ]
        let selection = LLMReferenceBudget.selectTerms(terms, text: "用 memoecho 和欧喷爱发给钟世明")
        XCTAssertEqual(selection.terms.prefix(3).map(\.term), ["MemoEcho", "OpenAI", "钟世明"])
        XCTAssertLessThanOrEqual(selection.terms.count, 3 + LLMReferenceBudget.fallbackTerms)
        XCTAssertLessThanOrEqual(selection.prompt.count, LLMReferenceBudget.dictionaryLimit)
    }

    func testReadyIndexFindsWholeSyllableHomophoneWithoutRetransformingDictionary() throws {
        let terms = fillerTerms(count: 129) + [.init(term: "钟世明", pronunciationHint: nil)]
        let index = try XCTUnwrap(PreparedTermIndex(terms: terms))
        var calls = 0
        let result = LLMReferenceBudget.selectTerms(terms, text: "发给钟世鸣", index: index, phonetic: {
            calls += 1
            return PreparedTermIndex.phoneticKey($0)
        })
        XCTAssertEqual(result.terms.first?.term, "钟世明")
        XCTAssertEqual(calls, 1)
        let boundaryTerms = fillerTerms(count: 129) + [.init(term: "长安", pronunciationHint: "chang an")]
        let boundaryIndex = try XCTUnwrap(PreparedTermIndex(terms: boundaryTerms))
        let boundary = LLMReferenceBudget.selectTerms(boundaryTerms, text: "长南", index: boundaryIndex)
        XCTAssertFalse(boundary.terms.contains(where: { $0.term == "长安" }))
    }

    func testColdOrMismatchedIndexDoesNotWaitOrUseDeletedTerms() throws {
        let old = fillerTerms(count: 129) + [.init(term: "旧词", pronunciationHint: nil)]
        let index = try XCTUnwrap(PreparedTermIndex(terms: old))
        let current = fillerTerms(count: 129) + [.init(term: "新词", pronunciationHint: nil)]
        var calls = 0
        let selection = LLMReferenceBudget.selectTerms(current, text: "新词", index: index, phonetic: { _ in calls += 1; return "" })
        XCTAssertEqual(selection.terms.first?.term, "新词")
        XCTAssertFalse(selection.terms.contains(where: { $0.term == "旧词" }))
        XCTAssertEqual(calls, 0)
    }

    func testLiteralByteSearchPreservesCanonicalAndWidthEquivalence() {
        let terms = fillerTerms(count: 129) + [.init(term: "Café", pronunciationHint: nil), .init(term: "ＭｅｍｏＥｃｈｏ", pronunciationHint: nil)]
        let selection = LLMReferenceBudget.selectTerms(terms, text: "cafe\u{301} 和 memoecho")
        XCTAssertEqual(selection.terms.prefix(2).map(\.term), ["Café", "ＭｅｍｏＥｃｈｏ"])
    }

    func testOversizedTermIsSkippedWithoutSplittingOrBlockingFollowingMatch() {
        let huge = String(repeating: "超长", count: 3_000)
        let terms = [TermReference(term: huge, pronunciationHint: nil), .init(term: "完整词条", pronunciationHint: "wan zheng")]
        let selection = LLMReferenceBudget.selectTerms(terms, text: huge + "完整词条")
        XCTAssertEqual(selection.terms.map(\.term), ["完整词条"])
        XCTAssertTrue(selection.prompt.contains("wan zheng"))
        XCTAssertLessThanOrEqual(selection.prompt.count, LLMReferenceBudget.dictionaryLimit)
    }

    func testFinalEncodedContextFitsBudgetAndPreservesNearestText() throws {
        let nearby = String(repeating: "旧", count: 1_100) + "NEAR_CURSOR"
        let context = WindowContextService.buildSnapshot(from: .init(
            appName: "Synthetic", selectedText: "SELECTED", surroundingTextBefore: nearby,
            surroundingTextAfter: "AFTER", visibleText: String(repeating: "\"\\🧑🏽‍💻长段落\n", count: 2_000))).snapshot
        let prompt = try XCTUnwrap(LLMReferenceBudget.contextSection(context))
        let json = try contextJSON(prompt)
        XCTAssertLessThanOrEqual(prompt.count, LLMReferenceBudget.contextLimit)
        XCTAssertEqual(json["selectedText"] as? String, "SELECTED")
        XCTAssertTrue((json["surroundingTextBefore"] as? String)?.hasSuffix("NEAR_CURSOR") == true)
        XCTAssertEqual(json["surroundingTextAfter"] as? String, "AFTER")
        XCTAssertFalse(prompt.contains("\u{FFFD}"))
    }

    func testVisibleParagraphsAlreadyInNearbyTextAndDuplicateLinesAreRemoved() throws {
        let context = WindowContextService.buildSnapshot(from: .init(
            selectedText: "已选文字", surroundingTextBefore: "光标之前",
            visibleText: "已选文字\n光标之前\n另一个段落\n另一个段落")).snapshot
        let json = try contextJSON(XCTUnwrap(LLMReferenceBudget.contextSection(context)))
        XCTAssertEqual(json["visibleText"] as? String, "另一个段落")
    }

    func testSensitiveContextIsRedactedBeforeBudgeting() throws {
        let context = WindowContextService.buildSnapshot(from: .init(
            appName: "Terminal", bundleID: "com.apple.Terminal", windowTitle: "PRIVATE_TITLE",
            selectedText: "PRIVATE_SELECTED", visibleText: "PRIVATE_BODY")).snapshot
        let prompt = try XCTUnwrap(LLMReferenceBudget.contextSection(context))
        XCTAssertFalse(prompt.contains("PRIVATE_"))
        XCTAssertTrue(prompt.contains("Terminal"))
    }

    func testLargeAuxiliaryPayloadHasCombinedBudget() throws {
        let terms = fillerTerms()
        let text = String(terms.map(\.term).joined(separator: " ").prefix(8_000))
        let dictionary = LLMReferenceBudget.selectTerms(terms, text: text).prompt
        let context = WindowContextService.buildSnapshot(from: .init(visibleText: String(repeating: "背景", count: 5_000))).snapshot
        let window = try XCTUnwrap(LLMReferenceBudget.contextSection(context))
        XCTAssertLessThanOrEqual(dictionary.count + window.count, 8_192)
        XCTAssertLessThanOrEqual(dictionary.count, 4_096)
        XCTAssertLessThanOrEqual(window.count, 4_096)
    }

    func testWarmerInvalidatesOldSnapshotWithoutWaiting() async throws {
        let warmer = LLMTermIndexWarmer()
        let old = fillerTerms(count: 129)
        warmer.prepare(old)
        for _ in 0..<1_000 {
            if warmer.ready(for: old) != nil { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertNotNil(warmer.ready(for: old))
        let current = [TermReference(term: "新词典", pronunciationHint: nil)]
        warmer.prepare(current)
        XCTAssertNil(warmer.ready(for: old))
        XCTAssertNil(warmer.ready(for: current)) // Small dictionaries need no phonetic index.
    }

    private func fillerTerms(count: Int = 5_000) -> [TermReference] {
        (0..<count).map { .init(term: "合成术语\($0)", pronunciationHint: nil) }
    }

    private func contextJSON(_ prompt: String) throws -> [String: Any] {
        let body = try XCTUnwrap(prompt.components(separatedBy: "BEGIN_WINDOW_CONTEXT_JSON\n").last?
            .components(separatedBy: "\nEND_WINDOW_CONTEXT_JSON").first)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
    }
}
