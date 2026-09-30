import XCTest
@testable import MemoEcho

final class VolcengineTraditionalASRProtocolTests: XCTestCase {
    func testBothModesUseHistoricalEndpointAndBearerSemicolonAuthentication() async throws {
        for mode in [VolcengineRealtimeMode.sentence, .streaming] {
            let request = try await RealtimeWireCodec.makeRequest(configuration: .volcengineTraditional(
                appID: "synthetic-app", accessToken: "synthetic-token", cluster: "synthetic-cluster", mode: mode))
            XCTAssertEqual(request.url?.absoluteString, "wss://openspeech.bytedance.com/api/v2/asr")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer; synthetic-token")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Api-Key"))
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Api-Resource-Id"))
        }
    }

    func testClientStartIncludesSelectedProductClusterAndRawPCMMetadata() throws {
        for mode in [VolcengineRealtimeMode.sentence, .streaming] {
            let codec = RealtimeWireCodec(configuration: .volcengineTraditional(appID: "synthetic-app",
                accessToken: "synthetic-token", cluster: mode == .sentence ? "sentence-cluster" : "streaming-cluster", mode: mode), taskID: "test-task")
            guard case .binary(let frame) = try codec.startMessage() else { return XCTFail("Binary start expected") }
            XCTAssertEqual(Array(frame.prefix(4)), [0x11, 0x10, 0x11, 0])
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: VolcengineRealtimeFrame.gunzip(Data(frame.dropFirst(8)))) as? [String: Any])
            let app = try XCTUnwrap(object["app"] as? [String: Any])
            XCTAssertEqual(app["appid"] as? String, "synthetic-app")
            XCTAssertEqual(app["token"] as? String, "synthetic-token")
            XCTAssertEqual(app["cluster"] as? String, mode == .sentence ? "sentence-cluster" : "streaming-cluster")
            let audio = try XCTUnwrap(object["audio"] as? [String: Any])
            XCTAssertEqual(audio["format"] as? String, "raw")
            XCTAssertEqual(audio["codec"] as? String, "raw")
            XCTAssertEqual(audio["rate"] as? Int, 16000)
            XCTAssertEqual(audio["bits"] as? Int, 16)
            XCTAssertEqual(audio["channel"] as? Int, 1)
            let request = try XCTUnwrap(object["request"] as? [String: Any])
            XCTAssertEqual(request["reqid"] as? String, "test-task")
            XCTAssertEqual(request["sequence"] as? Int, 1)
            XCTAssertEqual(request["show_utterances"] as? Bool, true)
            XCTAssertEqual(request["workflow"] as? String, "audio_in,resample,partition,vad,fe,decode,itn,nlu_punctuate")
            XCTAssertNil(request["result_type"])
            XCTAssertNil(request["vad_signal"])
        }
    }

    func testAudioFramesUseGzipRawBytesAndOnlyClientTerminalFlag() throws {
        var codec = makeCodec()
        let pcm = Data([1, 0, 2, 0, 3, 0])
        guard case .binary(let frame) = try codec.audioMessage(pcm) else { return XCTFail("Binary audio expected") }
        XCTAssertEqual(Array(frame.prefix(4)), [0x11, 0x20, 0x01, 0])
        XCTAssertEqual(try VolcengineRealtimeFrame.gunzip(Data(frame.dropFirst(8))), pcm)
        guard case .binary(let final) = try codec.finishMessage() else { return XCTFail("Binary terminal expected") }
        XCTAssertEqual(Array(final.prefix(4)), [0x11, 0x22, 0x01, 0])
        XCTAssertEqual(try VolcengineRealtimeFrame.gunzip(Data(final.dropFirst(8))), Data())
    }

    func testJSONNegativeSequenceCompletesEvenThoughServerHeaderFlagsRemainZero() throws {
        var codec = makeCodec()
        XCTAssertEqual(try codec.consume(response(["sequence": 1])), [.ready])
        let events = try codec.consume(response(["sequence": -3, "result": [["text": "合成测试。"]]]))
        XCTAssertEqual(events, [.ready, .transcript(.stableSentence(id: "traditional-final", text: "合成测试。", endSample: nil)), .completed])
    }

    func testWholeTranscriptSnapshotsRemainPartialUntilRevisedFinalSnapshot() throws {
        var codec = makeCodec()
        let interim: [String: Any] = ["sequence": 2, "result": [["text": "第一句。", "utterances": [["text": "第一句。", "definite": true]]]]]
        XCTAssertEqual(try codec.consume(response(interim)), [.ready, .transcript(.partial(text: "第一句。"))])
        XCTAssertEqual(try codec.consume(response(interim)), [.ready, .transcript(.partial(text: "第一句。"))])
        XCTAssertEqual(try codec.consume(response(["sequence": -4, "result": [["text": "修正第一句。第二句。"]]])), [.ready,
            .transcript(.stableSentence(id: "traditional-final", text: "修正第一句。第二句。", endSample: nil)), .completed])
    }

    func testEmptyAcknowledgementsPreserveDefiniteSnapshotForJSONTerminal() throws {
        var codec = makeCodec()
        _ = try codec.consume(response(["sequence": 2, "result": [["text": "合成测试。", "utterances": [["text": "合成测试。", "definite": true]]]]]))
        XCTAssertEqual(try codec.consume(response(["sequence": 3, "result": [[:]]])), [.ready])
        XCTAssertEqual(try codec.consume(response(["sequence": -4, "result": [[:]]])), [.ready,
            .transcript(.stableSentence(id: "traditional-final", text: "合成测试。", endSample: nil)), .completed])
    }

    func testTerminalAcknowledgementDoesNotPromotePartialOrStaleDefiniteSnapshot() throws {
        for addConfirmedSnapshot in [false, true] {
            var codec = makeCodec()
            if addConfirmedSnapshot {
                _ = try codec.consume(response(["sequence": 2, "result": [["text": "之前确认文本", "utterances": [["text": "之前确认文本", "definite": true]]]]]))
            }
            _ = try codec.consume(response(["sequence": 3, "result": [["text": "最新未确认文本", "utterances": [["text": "最新未确认文本", "definite": false]]]]]))
            XCTAssertThrowsError(try codec.consume(response(["sequence": -4]))) {
                XCTAssertEqual($0 as? RealtimeASRError, .invalidResponse)
            }
        }
    }

    func testWrongTaskAndMalformedResultCannotCompleteSession() throws {
        var codec = makeCodec()
        XCTAssertThrowsError(try codec.consume(response(["reqid": "other-task", "sequence": -1, "result": [["text": "合成文本"]]]))) {
            XCTAssertEqual($0 as? RealtimeASRError, .invalidResponse)
        }
        XCTAssertThrowsError(try codec.consume(response(["sequence": -1, "result": ["text": "错误结构"]]))) {
            XCTAssertEqual($0 as? RealtimeASRError, .invalidResponse)
        }
        XCTAssertThrowsError(try codec.consume(response(["sequence": "-1"]))) {
            XCTAssertEqual($0 as? RealtimeASRError, .invalidResponse)
        }
    }

    func testHistoricalFrameDecoderRejectsV3SequenceFlagsAndTruncatedPayloads() throws {
        let valid = try frame(payload: JSONSerialization.data(withJSONObject: ["reqid": "test-task", "code": 1000]))
        XCTAssertNoThrow(try VolcengineTraditionalFrame.decodeServer(valid))
        XCTAssertThrowsError(try VolcengineTraditionalFrame.decodeServer(Data(valid.dropLast())))
        var v3Flags = valid
        v3Flags[1] = 0x93
        XCTAssertThrowsError(try VolcengineTraditionalFrame.decodeServer(v3Flags))
        var invalidCompression = valid
        invalidCompression[2] = 0x12
        XCTAssertThrowsError(try VolcengineTraditionalFrame.decodeServer(invalidCompression))
    }

    func testJSONAndBinaryRejectionsMapCodesWithoutExposingServerMessages() throws {
        for (code, expected) in [(1002, RealtimeASRError.authentication), (1010, .sessionLimit), (1020, .timeout), (1005, .serviceRejected)] {
            var codec = makeCodec()
            XCTAssertThrowsError(try codec.consume(response(["code": code, "message": "untrusted-secret-and-transcript"]))) {
                XCTAssertEqual($0 as? RealtimeASRError, expected)
                XCTAssertFalse($0.localizedDescription.contains("untrusted-secret"))
            }
            var error = Data([0x11, 0xF0, 0, 0])
            append(UInt32(code), to: &error)
            let message = Data("untrusted-secret-and-transcript".utf8)
            append(UInt32(message.count), to: &error)
            error.append(message)
            XCTAssertThrowsError(try VolcengineTraditionalFrame.decodeServer(error)) {
                XCTAssertEqual($0 as? RealtimeASRError, expected)
                XCTAssertFalse($0.localizedDescription.contains("untrusted-secret"))
            }
        }
    }

    func testTranscriptOverLimitFailsBeforeCommittingFinal() throws {
        var codec = makeCodec()
        XCTAssertThrowsError(try codec.consume(response(["sequence": -1, "result": [["text": String(repeating: "合", count: 8001)]]]))) {
            XCTAssertEqual($0 as? RealtimeASRError, .textLimit)
        }
    }

    func testBothModesUploadWhileRecordingAndCompleteOnlyOnJSONTerminal() async throws {
        for mode in [VolcengineRealtimeMode.sentence, .streaming] {
            let socket = TraditionalModeSocket()
            let session = RealtimeCloudASRSession(configuration: .volcengineTraditional(appID: "synthetic-app",
                accessToken: "synthetic-token", cluster: "synthetic-cluster", mode: mode), transport: socket)
            try await session.connect()
            try await session.send(Data(repeating: 0, count: 3200))
            let result = try await session.finish()
            XCTAssertEqual(result, "合成第一句。第二句。")
            let sent = await socket.sentMessages
            XCTAssertEqual(sent.count, 3)
            guard case .binary(let last) = sent.last else { return XCTFail("Binary terminal expected") }
            XCTAssertEqual(last[1], 0x22)
        }
    }

    private func makeCodec() -> RealtimeWireCodec {
        RealtimeWireCodec(configuration: .volcengineTraditional(appID: "synthetic-app", accessToken: "synthetic-token",
            cluster: "synthetic-cluster", mode: .streaming), taskID: "test-task")
    }
    private func response(_ fields: [String: Any]) throws -> RealtimeWebSocketMessage {
        var object: [String: Any] = ["reqid": "test-task", "code": 1000]
        object.merge(fields) { _, new in new }
        return .binary(try frame(payload: JSONSerialization.data(withJSONObject: object)))
    }
    private func frame(payload: Data) throws -> Data {
        let compressed = try VolcengineRealtimeFrame.gzip(payload)
        var data = Data([0x11, 0x90, 0x11, 0])
        append(UInt32(compressed.count), to: &data)
        data.append(compressed)
        return data
    }
    private func append(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                                UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }
}

private actor TraditionalModeSocket: RealtimeWebSocketTransport {
    var sentMessages: [RealtimeWebSocketMessage] = []
    private var taskID = ""
    private var pending: [RealtimeWebSocketMessage] = []
    private var waiter: CheckedContinuation<RealtimeWebSocketMessage, Error>?
    private var closed = false

    func connect(_ request: URLRequest) async throws {}
    func send(_ message: RealtimeWebSocketMessage) async throws {
        sentMessages.append(message)
        guard case .binary(let frame) = message else { throw RealtimeASRError.invalidResponse }
        if frame[1] >> 4 == 1 {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: VolcengineRealtimeFrame.gunzip(Data(frame.dropFirst(8)))) as? [String: Any])
            taskID = try XCTUnwrap((object["request"] as? [String: Any])?["reqid"] as? String)
            try enqueue(sequence: 1, result: nil)
        } else if frame[1] & 2 != 0 {
            try enqueue(sequence: -3, result: ["text": "合成第一句。第二句。"])
        } else {
            let snapshot: [String: Any] = ["text": "合成第一句。", "utterances": [["text": "合成第一句。", "definite": true]]]
            try enqueue(sequence: 2, result: snapshot)
            try enqueue(sequence: 2, result: snapshot)
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
    private func enqueue(sequence: Int, result: [String: Any]?) throws {
        var object: [String: Any] = ["reqid": taskID, "code": 1000, "sequence": sequence]
        if let result { object["result"] = [result] }
        let compressed = try VolcengineRealtimeFrame.gzip(JSONSerialization.data(withJSONObject: object))
        var frame = Data([0x11, 0x90, 0x11, 0])
        let count = UInt32(compressed.count)
        frame.append(contentsOf: [UInt8(truncatingIfNeeded: count >> 24), UInt8(truncatingIfNeeded: count >> 16),
                                 UInt8(truncatingIfNeeded: count >> 8), UInt8(truncatingIfNeeded: count)])
        frame.append(compressed)
        let message = RealtimeWebSocketMessage.binary(frame)
        if let waiter { self.waiter = nil; waiter.resume(returning: message) }
        else { pending.append(message) }
    }
}
