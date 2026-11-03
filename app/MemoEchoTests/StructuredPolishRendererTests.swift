import XCTest
@testable import MemoEcho

final class StructuredPolishRendererTests: XCTestCase {

    // MARK: - plain_text 渲染

    func testPlainTextRendering() {
        let response = makeLLMResponse(mode: .plainText, text: "今天天气不错。")
        let rendered = StructuredPolishRenderer.render(response: response)
        XCTAssertEqual(rendered, "今天天气不错。")
    }

    func testPlainTextTrimsWhitespace() {
        let response = makeLLMResponse(mode: .plainText, text: "  有空格  ")
        let rendered = StructuredPolishRenderer.render(response: response)
        XCTAssertEqual(rendered, "有空格")
    }

    // MARK: - list 渲染

    func testListRendering() {
        let response = makeLLMResponse(
            mode: .list,
            text: "1. 买菜\n2. 做饭\n3. 洗碗",
            items: ["买菜", "做饭", "洗碗"]
        )
        let rendered = StructuredPolishRenderer.render(response: response)
        XCTAssertEqual(rendered, "1. 买菜\n2. 做饭\n3. 洗碗")
    }

    func testListRenderingPreservesIntro() {
        let response = makeLLMResponse(
            mode: .list,
            text: "我明天要出差，提醒我带一些东西：\n1. 身份证\n2. 充电宝",
            intro: "我明天要出差，提醒我带一些东西：",
            items: ["身份证", "充电宝"]
        )
        let rendered = StructuredPolishRenderer.render(response: response)
        XCTAssertEqual(rendered, "我明天要出差，提醒我带一些东西：\n1. 身份证\n2. 充电宝")
    }

    func testListRenderingPreservesOutro() {
        let response = makeLLMResponse(
            mode: .list,
            text: "我明天要出差，提醒我带一些东西：\n1. 身份证\n2. 充电宝\n另外明天航班是早上九点的，记得提醒我出门。",
            intro: "我明天要出差，提醒我带一些东西：",
            items: ["身份证", "充电宝"],
            outro: "另外明天航班是早上九点的，记得提醒我出门。"
        )
        let rendered = StructuredPolishRenderer.render(response: response)
        XCTAssertEqual(rendered, "我明天要出差，提醒我带一些东西：\n1. 身份证\n2. 充电宝\n另外明天航班是早上九点的，记得提醒我出门。")
    }

    func testListRenderingSupportsOutroWithoutIntro() {
        let response = makeLLMResponse(
            mode: .list,
            text: "1. 身份证\n2. 充电宝\n另外明天航班是早上九点的，记得提醒我出门。",
            items: ["身份证", "充电宝"],
            outro: "另外明天航班是早上九点的，记得提醒我出门。"
        )
        let rendered = StructuredPolishRenderer.render(response: response)
        XCTAssertEqual(rendered, "1. 身份证\n2. 充电宝\n另外明天航班是早上九点的，记得提醒我出门。")
    }

    func testListRenderingAddsColonToIntroWhenMissing() {
        let response = makeLLMResponse(
            mode: .list,
            text: "我明天要出差，提醒我带一些东西：\n1. 身份证",
            intro: "我明天要出差，提醒我带一些东西",
            items: ["身份证"]
        )
        let rendered = StructuredPolishRenderer.render(response: response)
        XCTAssertEqual(rendered, "我明天要出差，提醒我带一些东西：\n1. 身份证")
    }

    func testListWithEmptyItemsFallsBackToText() {
        let response = makeLLMResponse(
            mode: .list,
            text: "没有真正的列表",
            items: []
        )
        let rendered = StructuredPolishRenderer.render(response: response)
        XCTAssertEqual(rendered, "没有真正的列表")
    }

    func testListWithNilItemsFallsBackToText() {
        let response = makeLLMResponse(
            mode: .list,
            text: "也不是列表",
            items: nil
        )
        let rendered = StructuredPolishRenderer.render(response: response)
        XCTAssertEqual(rendered, "也不是列表")
    }

    func testNormalizationPreservesModelApprovedWordsAndPunctuation() {
        for text in ["嗯", "嗯。", "啊？", "唉！", "嗯我想确认一下明天的会议。",
                     "然后就是我们先对一下。", "先保存，然后退出。", "这个就是我要的。",
                     "他说：‘嗯。’", "1. 嗯\n2. 好", "啊啊啊", "……", "保留  间隔"] {
            XCTAssertEqual(PolishTextNormalizer.normalize(text), text)
        }
    }

    func testNormalizationOnlyTrimsEdgesAndNormalizesLineEndings() {
        XCTAssertEqual(PolishTextNormalizer.normalize(" \r\n嗯。\r\n  好。\r收到。\n "), "嗯。\n  好。\n收到。")
        XCTAssertEqual(PolishTextNormalizer.normalize(" \r\n\t"), "")
    }

    // MARK: - Helpers

    private func makeLLMResponse(
        mode: PolishMode,
        text: String,
        intro: String? = nil,
        items: [String]? = nil,
        outro: String? = nil,
        correctionApplied: Bool = false
    ) -> LLMStructuredResponse {
        // We need to encode and decode since LLMStructuredResponse only has Decodable
        let dict: [String: Any?] = [
            "mode": mode.rawValue,
            "text": text,
            "intro": intro,
            "items": items,
            "outro": outro,
            "correction_applied": correctionApplied
        ]
        let filtered = dict.compactMapValues { $0 }
        let data = try! JSONSerialization.data(withJSONObject: filtered)
        return try! JSONDecoder().decode(LLMStructuredResponse.self, from: data)
    }
}
