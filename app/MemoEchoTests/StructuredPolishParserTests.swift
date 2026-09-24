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

    func testInvalidOrIncompleteResponsesAreRejected() {
        let invalid = [
            "这是一段普通文本",
            #"{"mode":"message","text":"你好","correction_applied":false}"#,
            #"{"mode":"list","text":"没有列表","items":[],"correction_applied":false}"#,
            #"{"mode":"plain_text","text":"缺少修正字段"}"#,
            #"{"mode":"plain_text","text":"","correction_applied":false}"#,
            "   "
        ]
        for content in invalid {
            guard case .invalid = StructuredPolishParser.parse(content: content) else {
                return XCTFail("Expected invalid response for \(content)")
            }
        }
    }
}
