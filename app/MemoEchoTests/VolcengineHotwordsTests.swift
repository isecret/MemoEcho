import XCTest
@testable import MemoEcho

final class VolcengineHotwordsTests: XCTestCase {
    func testSelectionNormalizesDeduplicatesAndPreservesFirstSpelling() throws {
        let snapshot = VolcengineHotwords(terms: [" \n", " MemoEcho ", "memoecho", "Café", "Cafe\u{301}", "火山引擎"],
                                          platform: .volcengineBigModelSentence)
        XCTAssertEqual(snapshot.terms, ["MemoEcho", "Café", "火山引擎"])
        XCTAssertEqual(try decodedTerms(snapshot), snapshot.terms)
        XCTAssertNil(try VolcengineHotwords.empty.context())
    }

    func testJSONEscapesRoundTripWithoutSplittingTerms() throws {
        let terms = ["a\"b", "c\\d", "e/f", "😀", "line\nfeed", "\u{0001}inside"]
        let snapshot = VolcengineHotwords(terms: terms, platform: .volcengineSentence)
        XCTAssertEqual(try decodedTerms(snapshot), terms)
    }

    func testByteBudgetIncludesJSONEnvelopeAndEscapes() throws {
        let maximumBytes = 256 * 1024
        let exact = String(repeating: "a", count: maximumBytes - 26)
        for platform in [ASRPlatform.volcengineRealtime, .volcengineBigModelSentence, .volcengineSentence] {
            let snapshot = VolcengineHotwords(terms: [exact, "next"], platform: platform)
            XCTAssertEqual(snapshot.terms, [exact])
            XCTAssertEqual(try XCTUnwrap(snapshot.context()).utf8.count, maximumBytes)
            XCTAssertTrue(VolcengineHotwords(terms: [exact + "a", "short"], platform: platform).terms.isEmpty)
            let escaped = VolcengineHotwords(terms: [String(repeating: "\"", count: maximumBytes / 2)], platform: platform)
            XCTAssertTrue(escaped.terms.isEmpty)
        }
    }

    func testAllV3EndpointsShareWordLimitAndIndependentPayloadBound() throws {
        let input = (0..<5001).map { "术语\($0)" }
        for platform in [ASRPlatform.volcengineRealtime, .volcengineBigModelSentence, .volcengineSentence] {
            let selection = VolcengineHotwords(terms: input, platform: platform)
            XCTAssertEqual(selection.terms, Array(input.prefix(5000)))
            let longTerms = (0..<5000).map { String(repeating: "中", count: 100) + String($0) }
            let bounded = VolcengineHotwords(terms: longTerms, platform: platform)
            XCTAssertLessThan(bounded.terms.count, 5000)
            XCTAssertLessThanOrEqual(try XCTUnwrap(bounded.context()).utf8.count, 256 * 1024)
            XCTAssertEqual(bounded.terms, Array(longTerms.prefix(bounded.terms.count)))
        }
    }

    func testOtherPlatformsNeverSelectHotwords() {
        for platform in ASRPlatform.allCases where ![.volcengineRealtime, .volcengineBigModelSentence, .volcengineSentence].contains(platform) {
            XCTAssertEqual(VolcengineHotwords(terms: ["MemoEcho"], platform: platform), .empty)
        }
    }

    func testBothWebSocketModesAndModelVersionsEncodeSnapshotOnlyInStartPacket() throws {
        for platform in [ASRPlatform.volcengineRealtime, .volcengineBigModelSentence] {
            for version in VolcengineASRModelVersion.allCases {
                var config = ASRConfig()
                config.selectedPlatform = platform
                config.volcengine.modelVersion = version
                config.volcengine.apiKey = "synthetic-key"
                let selection = VolcengineHotwords(terms: ["MemoEcho", "a\"b\\c"], platform: platform)
                var codec = RealtimeWireCodec(configuration: try ASRProviderFactory.realtimeConfiguration(for: config, hotwords: selection))
                guard case .binary(let frame) = try codec.startMessage() else { return XCTFail("Expected start") }
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: VolcengineRealtimeFrame.gunzip(Data(frame.dropFirst(8)))) as? [String: Any])
                let request = try XCTUnwrap(body["request"] as? [String: Any])
                let corpus = try XCTUnwrap(request["corpus"] as? [String: String])
                XCTAssertEqual(corpus, ["context": try XCTUnwrap(selection.context())])
                XCTAssertEqual(request["enable_nonstream"] as? Bool, platform == .volcengineRealtime ? true : nil)
                let pcm = Data(repeating: 0, count: 3200)
                guard case .binary(let audio) = try codec.audioMessage(pcm) else { return XCTFail("Expected audio") }
                XCTAssertEqual(try VolcengineRealtimeFrame.gunzip(Data(audio.dropFirst(8))), pcm)
                let emptyCodec = RealtimeWireCodec(configuration: try ASRProviderFactory.realtimeConfiguration(for: config))
                guard case .binary(let empty) = try emptyCodec.startMessage() else { return XCTFail("Expected start") }
                let emptyBody = try XCTUnwrap(JSONSerialization.jsonObject(with: VolcengineRealtimeFrame.gunzip(Data(empty.dropFirst(8)))) as? [String: Any])
                XCTAssertNil((emptyBody["request"] as? [String: Any])?["corpus"])
            }
        }
    }

    @MainActor
    func testCheckpointKeepsOriginalTermsAndDiscardsThemWithRecovery() throws {
        let original = VolcengineHotwords(terms: ["MemoEcho"], platform: .volcengineRealtime)
        let checkpoint = SessionRecoveryCheckpoint(transcripts: [], mode: .polish, language: .english,
            asrPlatform: .volcengineRealtime, target: nil, context: nil, hotwords: original)
        XCTAssertEqual(checkpoint.hotwords, original)
        checkpoint.discard()
        XCTAssertEqual(checkpoint.hotwords, .empty)
    }

    private func decodedTerms(_ hotwords: VolcengineHotwords) throws -> [String] {
        let json = try XCTUnwrap(hotwords.context())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: [[String: String]]])
        return try XCTUnwrap(object["hotwords"]).compactMap { $0["word"] }
    }
}
