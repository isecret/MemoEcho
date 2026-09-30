import XCTest
@testable import MemoEcho

final class VolcengineBigModelASRProtocolTests: XCTestCase {
    func testModesRouteToTheirOwnEndpointsWithBothModelResources() async throws {
        for resource in ["volc.bigasr.sauc.duration", "volc.seedasr.sauc.duration"] {
            for mode in [VolcengineRealtimeMode.sentence, .streaming] {
                let request = try await RealtimeWireCodec.makeRequest(configuration:
                    .volcengine(apiKey: "synthetic-test-key", resourceID: resource, mode: mode))
                XCTAssertEqual(request.url?.scheme, "wss")
                XCTAssertEqual(request.url?.host, "openspeech.bytedance.com")
                XCTAssertEqual(request.url?.path, mode == .sentence ? "/api/v3/sauc/bigmodel_nostream" : "/api/v3/sauc/bigmodel_async")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), "synthetic-test-key")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Resource-Id"), resource)
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Sequence"), "-1")
                let requestID = try XCTUnwrap(request.value(forHTTPHeaderField: "X-Api-Request-Id"))
                XCTAssertNotNil(UUID(uuidString: requestID))
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Connect-Id"), requestID)
            }
        }
    }

    func testUnrecognizedResourceCannotIssueRequest() async {
        do {
            _ = try await RealtimeWireCodec.makeRequest(configuration:
                .volcengine(apiKey: "synthetic-test-key", resourceID: "volc.bigasr.auc_turbo", mode: .sentence))
            XCTFail("File resource must not be used for a streaming audio task")
        } catch { XCTAssertEqual(error as? RealtimeASRError, .configuration) }
    }

    func testSentenceStartUsesFullSnapshotsWithoutStreamingDualPass() throws {
        let codec = sentenceCodec()
        guard case .binary(let frame) = try codec.startMessage() else { return XCTFail("Binary start expected") }
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: VolcengineRealtimeFrame.gunzip(Data(frame.dropFirst(8)))) as? [String: Any])
        let audio = try XCTUnwrap(body["audio"] as? [String: Any])
        XCTAssertEqual(audio["format"] as? String, "pcm")
        XCTAssertEqual(audio["rate"] as? Int, 16_000)
        let request = try XCTUnwrap(body["request"] as? [String: Any])
        XCTAssertEqual(request["show_utterances"] as? Bool, true)
        XCTAssertEqual(request["result_type"] as? String, "full")
        XCTAssertNil(request["enable_nonstream"])
    }

    func testSentenceSnapshotsStayPartialAndTextOnlyTerminalCommitsOnce() throws {
        var codec = sentenceCodec()
        let interim = #"{"result":{"text":"合成测试。","utterances":[{"text":"合成测试。","definite":true,"end_time":1000}]}}"#
        XCTAssertEqual(try codec.consume(response(interim)), [.ready, .transcript(.partial(text: "合成测试。"))])
        XCTAssertEqual(try codec.consume(response(interim)), [.ready, .transcript(.partial(text: "合成测试。"))])
        let final = #"{"result":{"text":"合成测试。第二句。"}}"#
        XCTAssertEqual(try codec.consume(response(final, final: true)), [.ready,
            .transcript(.stableSentence(id: "sentence-final", text: "合成测试。第二句。", endSample: nil)), .completed])
    }

    func testSentenceTerminalCanReviseEarlierSnapshot() throws {
        var codec = sentenceCodec()
        _ = try codec.consume(response(#"{"result":{"text":"合成文字","utterances":[{"text":"合成文字","definite":true}]}}"#))
        XCTAssertEqual(try codec.consume(response(#"{"result":{"text":"修正后的合成文字。"}}"#, final: true)), [.ready,
            .transcript(.stableSentence(id: "sentence-final", text: "修正后的合成文字。", endSample: nil)), .completed])
    }

    func testSentenceTerminalUtterancesDoNotRequireTimestamps() throws {
        var codec = sentenceCodec()
        let final = #"{"result":{"utterances":[{"text":"第一句。","definite":true},{"text":"第二句。","definite":true}]}}"#
        XCTAssertEqual(try codec.consume(response(final, final: true)), [.ready,
            .transcript(.stableSentence(id: "sentence-final", text: "第一句。第二句。", endSample: nil)), .completed])
    }

    func testSentenceTerminalAcknowledgementCanConfirmEarlierDefiniteSnapshot() throws {
        var codec = sentenceCodec()
        _ = try codec.consume(response(#"{"result":{"text":"合成测试。","utterances":[{"text":"合成测试。","definite":true}]}}"#))
        XCTAssertEqual(try codec.consume(response("{}", final: true)), [.ready,
            .transcript(.stableSentence(id: "sentence-final", text: "合成测试。", endSample: nil)), .completed])
    }

    func testEmptyResultAcknowledgementPreservesEarlierDefiniteSnapshot() throws {
        var codec = sentenceCodec()
        _ = try codec.consume(response(#"{"result":{"text":"合成测试。","utterances":[{"text":"合成测试。","definite":true}]}}"#))
        XCTAssertEqual(try codec.consume(response(#"{"result":{}}"#)), [.ready])
        XCTAssertEqual(try codec.consume(response(#"{"result":{}}"#, final: true)), [.ready,
            .transcript(.stableSentence(id: "sentence-final", text: "合成测试。", endSample: nil)), .completed])
    }

    func testSentenceTerminalAcknowledgementNeverPromotesUnconfirmedText() throws {
        var codec = sentenceCodec()
        _ = try codec.consume(response(#"{"result":{"text":"合成未确认文字","utterances":[{"text":"合成未确认文字","definite":false}]}}"#))
        XCTAssertThrowsError(try codec.consume(response("{}", final: true))) {
            XCTAssertEqual($0 as? RealtimeASRError, .invalidResponse)
        }
    }

    func testSentenceSessionWaitsForEndAndReturnsFullTextWithoutRepeatingSnapshots() async throws {
        let socket = SentenceModeSocket()
        let session = RealtimeCloudASRSession(configuration:
            .volcengine(apiKey: "synthetic-test-key", resourceID: "volc.seedasr.sauc.duration", mode: .sentence), transport: socket)
        try await session.connect()
        try await session.send(Data(repeating: 0, count: 3200))
        let result = try await session.finish()
        XCTAssertEqual(result, "合成测试。第二句。")
        let sent = await socket.sentMessages
        XCTAssertEqual(sent.count, 3)
        guard case .binary(let final) = sent.last else { return XCTFail("Binary audio final expected") }
        XCTAssertEqual(final[1] & 2, 2)
    }

    private func sentenceCodec() -> RealtimeWireCodec {
        RealtimeWireCodec(configuration: .volcengine(apiKey: "synthetic-test-key", mode: .sentence))
    }
    private func response(_ json: String, final: Bool = false) throws -> RealtimeWebSocketMessage {
        .binary(try VolcengineRealtimeFrame.encode(type: 9, sequence: final ? -7 : 1, payload: Data(json.utf8), json: true))
    }
}

private actor SentenceModeSocket: RealtimeWebSocketTransport {
    var sentMessages: [RealtimeWebSocketMessage] = []
    private var pending: [RealtimeWebSocketMessage] = []
    private var waiter: CheckedContinuation<RealtimeWebSocketMessage, Error>?
    private var closed = false

    func connect(_ request: URLRequest) async throws { try enqueue("{}", final: false) }
    func send(_ message: RealtimeWebSocketMessage) async throws {
        sentMessages.append(message)
        guard case .binary(let frame) = message, frame[1] >> 4 == 2 else { return }
        if frame[1] & 2 != 0 {
            try enqueue(#"{"result":{"text":"合成测试。第二句。"}}"#, final: true)
        } else {
            let snapshot = #"{"result":{"text":"合成测试。","utterances":[{"text":"合成测试。","definite":true}]}}"#
            try enqueue(snapshot, final: false)
            try enqueue(snapshot, final: false)
        }
    }
    func receive() async throws -> RealtimeWebSocketMessage {
        if !pending.isEmpty { return pending.removeFirst() }
        if closed { throw RealtimeASRError.connectionClosed }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func close() async {
        closed = true
        waiter?.resume(throwing: RealtimeASRError.connectionClosed)
        waiter = nil
    }
    private func enqueue(_ json: String, final: Bool) throws {
        let message = RealtimeWebSocketMessage.binary(try VolcengineRealtimeFrame.encode(type: 9,
            sequence: final ? -7 : 1, payload: Data(json.utf8), json: true))
        if let waiter { self.waiter = nil; waiter.resume(returning: message) }
        else { pending.append(message) }
    }
}
