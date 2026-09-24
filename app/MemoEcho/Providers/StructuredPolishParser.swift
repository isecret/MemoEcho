import Foundation

/// 从 LLM 响应中提取并解析结构化 JSON 结果
enum StructuredPolishParser {

    enum ParseResult: Sendable {
        case structured(response: LLMStructuredResponse)
        case invalid
    }

    static func parse(content: String) -> ParseResult {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let response = try? JSONDecoder().decode(LLMStructuredResponse.self, from: data),
              response.toStructuredResult().isValid,
              !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .invalid
        }
        return .structured(response: response)
    }

}

// MARK: - LLM Structured Response (wire format)

/// LLM 返回的 JSON 结构（对应 Prompt 定义的 schema）
struct LLMStructuredResponse: Decodable, Equatable, Sendable {
    let mode: PolishMode
    let text: String
    let intro: String?
    let items: [String]?
    let outro: String?
    let correctionApplied: Bool

    enum CodingKeys: String, CodingKey {
        case mode, text, intro, items, outro
        case correctionApplied = "correction_applied"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(PolishMode.self, forKey: .mode)
        text = try container.decode(String.self, forKey: .text)
        intro = try container.decodeIfPresent(String.self, forKey: .intro)
        items = try container.decodeIfPresent([String].self, forKey: .items)
        outro = try container.decodeIfPresent(String.self, forKey: .outro)
        correctionApplied = try container.decode(Bool.self, forKey: .correctionApplied)
    }

    /// 转为内部结构化结果模型
    func toStructuredResult() -> StructuredPolishResult {
        StructuredPolishResult(
            mode: mode,
            intro: intro,
            items: items,
            outro: outro,
            correctionApplied: correctionApplied
        )
    }
}
