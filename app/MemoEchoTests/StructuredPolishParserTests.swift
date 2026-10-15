import XCTest
@testable import MemoEcho

final class StructuredPolishParserTests: XCTestCase {
    func testPlainTextParsesSuccessfully() {
        let json = #"{"mode":"plain_text","text":"今天天气不错。","correction_applied":false}"#
        guard case .structured(let response) = StructuredPolishParser.parse(content: json) else {
            return XCTFail("Expected structured result")
        }
        XCTAssertEqual(response.mode, .plainText)
        XCTAssertEqual(response.text, "今天天气不错。")
        XCTAssertFalse(response.correctionApplied)
    }

    func testListPreservesIntroItemsAndOutro() {
        let json = #"{"mode":"list","text":"出差要带的东西：苹果、香蕉。","intro":"出差要带的东西","items":["苹果","香蕉"],"outro":"明天出门。","correction_applied":true}"#
        guard case .structured(let response) = StructuredPolishParser.parse(content: json) else {
            return XCTFail("Expected structured result")
        }
        XCTAssertEqual(response.mode, .list)
        XCTAssertEqual(response.items, ["苹果", "香蕉"])
        XCTAssertEqual(response.intro, "出差要带的东西")
        XCTAssertEqual(response.outro, "明天出门。")
        XCTAssertTrue(response.correctionApplied)
    }

    func testListWithoutDuplicatedTextRendersExactlyLikeLegacyResponse() throws {
        let fields: [String: Any] = ["mode": "list", "intro": "出差要带的东西",
                                   "items": ["苹果", "香蕉"], "outro": "明天出门。", "correction_applied": true]
        var legacyFields = fields
        legacyFields["text"] = "出差要带的东西：苹果、香蕉。明天出门。"
        func parse(_ fields: [String: Any]) throws -> LLMStructuredResponse {
            let json = try JSONSerialization.data(withJSONObject: fields)
            guard case .structured(let response) = StructuredPolishParser.parse(content: String(decoding: json, as: UTF8.self)) else {
                throw NSError(domain: "Expected structured response", code: 1)
            }
            return response
        }
        let compact = try parse(fields)
        let legacy = try parse(legacyFields)
        XCTAssertEqual(compact.text, "")
        XCTAssertEqual(compact.toStructuredResult(), legacy.toStructuredResult())
        XCTAssertEqual(StructuredPolishRenderer.render(response: compact), StructuredPolishRenderer.render(response: legacy))
        XCTAssertEqual(StructuredPolishRenderer.render(response: compact), "出差要带的东西：\n1. 苹果\n2. 香蕉\n明天出门。")
    }

    func testInvalidOrIncompleteResponsesAreRejected() {
        let invalid = [
            "这是一段普通文本",
            #"{"mode":"message","text":"你好","correction_applied":false}"#,
            #"{"mode":"list","text":"没有列表","items":[],"correction_applied":false}"#,
            #"{"mode":"list","items":null,"correction_applied":false}"#,
            #"{"mode":"list","correction_applied":false}"#,
            #"{"mode":"list","items":["有效条目"," \n "],"correction_applied":false}"#,
            #"{"mode":"list","items":[42],"correction_applied":false}"#,
            #"{"mode":"list","text":42,"items":["条目"],"correction_applied":false}"#,
            #"{"mode":"list","items":["条目"]}"#,
            #"{"mode":"plain_text","text":"缺少修正字段"}"#,
            #"{"mode":"plain_text","text":"","correction_applied":false}"#,
            #"{"mode":"plain_text","text":" \n ","correction_applied":false}"#,
            #"{"mode":"plain_text","text":null,"correction_applied":false}"#,
            #"{"mode":"plain_text","correction_applied":false}"#,
            "   "
        ]
        for content in invalid {
            guard case .invalid = StructuredPolishParser.parse(content: content) else {
                return XCTFail("Expected invalid response for \(content)")
            }
        }
    }
}
