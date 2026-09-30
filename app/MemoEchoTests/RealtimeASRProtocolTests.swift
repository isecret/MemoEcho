import XCTest
@testable import MemoEcho

final class RealtimeASRProtocolTests: XCTestCase {
    func testTencentSignsRequestAndUsesNativeRealtimeParameters() async throws {
        let request = try await RealtimeWireCodec.makeRequest(configuration: .tencent(appID: "123", secretID: "test-id", secretKey: "test-key"), now: Date(timeIntervalSince1970: 1000))
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.path, "/asr/v2/123")
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let params = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(params["voice_format"], "1")
        XCTAssertEqual(params["needvad"], "1")
        let raw = params.filter { $0.key != "signature" }.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        XCTAssertEqual(params["signature"], RealtimeWireCodec.hmacSHA1("test-key", "asr.cloud.tencent.com/asr/v2/123?" + raw))
    }

    func testTencentOnlyCommitsFinalSentences() throws {
        var codec = RealtimeWireCodec(configuration: .tencent(appID: "1", secretID: "id", secretKey: "key"))
        XCTAssertEqual(try codec.consume(.text("{\"code\":0}")), [.ready])
        let partial = try codec.consume(.text("{\"code\":0,\"result\":{\"index\":0,\"slice_type\":1,\"voice_text_str\":\"合成\",\"end_time\":800}}"))
        XCTAssertEqual(partial, [.transcript(.partial(text: "合成"))])
        let final = try codec.consume(.text("{\"code\":0,\"result\":{\"index\":0,\"slice_type\":2,\"voice_text_str\":\"合成测试。\",\"end_time\":1000}}"))
        XCTAssertEqual(final, [.transcript(.stableSentence(id: "0", text: "合成测试。", endSample: 16000))])
        XCTAssertEqual(try codec.finishMessage(), .text("{\"type\":\"end\"}"))
        XCTAssertEqual(try codec.consume(.text("{\"code\":0,\"final\":1}")), [.completed])
    }

    func testAliyunUsesTranscriberAndRejectsWrongTask() throws {
        var codec = RealtimeWireCodec(configuration: .aliyun(accessKeyID: "test", accessKeySecret: "test", appKey: "test"), taskID: "task")
        let start = try json(codec.startMessage())
        XCTAssertEqual((start["header"] as? [String: Any])?["namespace"] as? String, "SpeechTranscriber")
        XCTAssertEqual((start["header"] as? [String: Any])?["name"] as? String, "StartTranscription")
        XCTAssertEqual(try codec.consume(.text("{\"header\":{\"name\":\"TranscriptionStarted\",\"task_id\":\"task\",\"status\":20000000}}")), [.ready])
        XCTAssertEqual(try codec.consume(.text("{\"header\":{\"name\":\"SentenceEnd\",\"task_id\":\"task\"},\"payload\":{\"index\":1,\"time\":1250,\"result\":\"测试\"}}")), [.transcript(.stableSentence(id: "1", text: "测试", endSample: 20000))])
        XCTAssertThrowsError(try codec.consume(.text("{\"header\":{\"name\":\"TranscriptionCompleted\",\"task_id\":\"other\"}}")))
    }

    func testAliyunFailureBeforeTaskAssignmentPreservesStatus() throws {
        var codec = RealtimeWireCodec(configuration: .aliyun(accessKeyID: "test", accessKeySecret: "test", appKey: "test"), taskID: "task")
        let response = #"{"header":{"name":"TaskFailed","task_id":"unassigned-task","status":40000002,"status_text":"untrusted-sensitive-text"}}"#
        XCTAssertThrowsError(try codec.consume(.text(response))) { error in
            XCTAssertTrue(error.localizedDescription.contains("40000002"))
            XCTAssertFalse(error.localizedDescription.contains("untrusted-sensitive-text"))
            XCTAssertNotEqual(error as? RealtimeASRError, .invalidResponse)
        }
    }

    func testAliyunUsesLowercaseHexMessageAndTaskIDs() throws {
        var codec = RealtimeWireCodec(configuration: .aliyun(accessKeyID: "test", accessKeySecret: "test", appKey: "test"))
        let start = try json(codec.startMessage())
        let finish = try json(codec.finishMessage())
        let startHeader = try XCTUnwrap(start["header"] as? [String: Any])
        let finishHeader = try XCTUnwrap(finish["header"] as? [String: Any])
        for header in [startHeader, finishHeader] {
            for field in ["message_id", "task_id"] {
                let id = try XCTUnwrap(header[field] as? String)
                XCTAssertEqual(id.count, 32)
                XCTAssertNotNil(id.range(of: "^[0-9a-f]{32}$", options: .regularExpression))
            }
        }
        XCTAssertEqual(startHeader["task_id"] as? String, finishHeader["task_id"] as? String)
        XCTAssertNotEqual(startHeader["message_id"] as? String, finishHeader["message_id"] as? String)
    }

    func testBailianWaitsForTaskFinishedAndKeepsSilentConnectionAlive() throws {
        var codec = RealtimeWireCodec(configuration: bailian, taskID: "task")
        let start = try json(codec.startMessage())
        let payload = try XCTUnwrap(start["payload"] as? [String: Any])
        let params = try XCTUnwrap(payload["parameters"] as? [String: Any])
        XCTAssertEqual(params["heartbeat"] as? Bool, true)
        XCTAssertEqual(params["format"] as? String, "pcm")
        XCTAssertEqual(try codec.consume(.text("{\"header\":{\"event\":\"task-started\",\"task_id\":\"task\"}}")), [.ready])
        let sentence = "{\"header\":{\"event\":\"result-generated\",\"task_id\":\"task\"},\"payload\":{\"output\":{\"sentence\":{\"text\":\"合成测试\",\"sentence_end\":true,\"begin_time\":0,\"end_time\":900}}}}"
        XCTAssertEqual(try codec.consume(.text(sentence)), [.transcript(.stableSentence(id: "0", text: "合成测试", endSample: 14400))])
        XCTAssertEqual(try codec.consume(.text(sentence)), [.transcript(.stableSentence(id: "0", text: "合成测试", endSample: 14400))])
        XCTAssertEqual(try codec.consume(.text("{\"header\":{\"event\":\"task-finished\",\"task_id\":\"task\"}}")), [.completed])
    }

    func testBailianRejectsHTTPBatchEndpoint() async {
        do {
            _ = try await RealtimeWireCodec.makeRequest(configuration: .bailian(apiKey: "test", endpoint: URL(string: "https://example.com/generation")!, model: "qwen-audio-3.1-asr-flash"))
            XCTFail("Batch configuration must fail")
        } catch { XCTAssertEqual(error as? RealtimeASRError, .configuration) }
    }

    func testBailianAcceptsCustomModelWithoutMarkingItVerified() async throws {
        for model in ["qwen-audio-3.1-asr-flash-streaming", "fun-asr-realtime", "user-specified-model"] {
            let config = AliyunBailianASRConfig(apiKey: "test", model: " \(model)\n")
            XCTAssertTrue(config.isComplete)
            XCTAssertFalse(config.isReady)
            let connection = RealtimeCloudASRConfiguration.bailian(apiKey: config.normalizedAPIKey,
                endpoint: try XCTUnwrap(config.requestURL), model: config.normalizedModel)
            _ = try await RealtimeWireCodec.makeRequest(configuration: connection)
            let codec = RealtimeWireCodec(configuration: connection)
            let start = try json(codec.startMessage())
            XCTAssertEqual((start["payload"] as? [String: Any])?["model"] as? String, model)
        }
    }

    func testBailianRejectsBlankModelInConfigurationAndRequest() async throws {
        for model in ["", " \n\t"] {
            let config = AliyunBailianASRConfig(apiKey: "test", model: model)
            XCTAssertFalse(config.isComplete)
            do {
                _ = try await RealtimeWireCodec.makeRequest(configuration: .bailian(apiKey: "test",
                    endpoint: try XCTUnwrap(config.requestURL), model: model))
                XCTFail("Blank model must be rejected")
            } catch { XCTAssertEqual(error as? RealtimeASRError, .configuration) }
        }
    }

    func testXunfeiUsesRTASRSignatureAndBinaryEnd() async throws {
        // Published signing example from the vendor uses synthetic credentials.
        let request = try await RealtimeWireCodec.makeRequest(configuration: .xunfei(appID: "595f23df", apiKey: "d9f4aa7ea6d94faca62cd88a28fd5234"), now: Date(timeIntervalSince1970: 1512041814))
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "signa" }?.value, "IrrzsJeOFk1NGfJHW6SkHUoN9CU=")
        var codec = RealtimeWireCodec(configuration: .xunfei(appID: "test", apiKey: "test"))
        XCTAssertTrue(codec.completesOnNormalClose)
        XCTAssertEqual(try codec.finishMessage(), .binary(Data("{\"end\":true}".utf8)))
        let inner: [String: Any] = ["seg_id": 4, "cn": ["st": ["type": "0", "ed": "1200", "rt": [["ws": [["cw": [["w": "合成测试"]]]]]]]]]
        let innerJSON = String(decoding: try JSONSerialization.data(withJSONObject: inner), as: UTF8.self)
        let outer = try JSONSerialization.data(withJSONObject: ["action": "result", "code": "0", "data": innerJSON])
        XCTAssertEqual(try codec.consume(.binary(outer)), [.transcript(.stableSentence(id: "4", text: "合成测试", endSample: 19200))])
    }

    func testVolcanoFramingCompressionAndFinalBit() throws {
        var codec = RealtimeWireCodec(configuration: .volcengine(apiKey: "test"))
        guard case .binary(let start) = try codec.startMessage() else { return XCTFail("binary expected") }
        XCTAssertEqual(Array(start.prefix(4)), [0x11, 0x10, 0x11, 0])
        let object = try JSONSerialization.jsonObject(with: VolcengineRealtimeFrame.gunzip(Data(start.dropFirst(8)))) as? [String: Any]
        XCTAssertEqual((object?["request"] as? [String: Any])?["enable_nonstream"] as? Bool, true)
        guard case .binary(let end) = try codec.finishMessage() else { return XCTFail("binary expected") }
        XCTAssertEqual(Array(end.prefix(4)), [0x11, 0x22, 0x01, 0])
        let payload = Data("{\"result\":{\"utterances\":[{\"text\":\"合成测试\",\"start_time\":0,\"end_time\":1000,\"definite\":true}]}}".utf8)
        let response = try VolcengineRealtimeFrame.encode(type: 9, sequence: -2, payload: payload, json: true)
        XCTAssertEqual(try codec.consume(.binary(response)), [.ready, .transcript(.stableSentence(id: "end-1000", text: "合成测试", endSample: 16000)), .completed])
        XCTAssertThrowsError(try VolcengineRealtimeFrame.decode(Data(response.dropLast())))
        XCTAssertThrowsError(try VolcengineRealtimeFrame.gunzip(Data([0, 1, 2])))
    }

    func testVolcanoPartialDoesNotRequireStartTime() throws {
        var codec = RealtimeWireCodec(configuration: .volcengine(apiKey: "test"))
        // Real response shape from credential validation; transcription replaced with synthetic text.
        let payload = Data(#"{"result":{"text":"合成测试","utterances":[{"definite":false,"end_time":500,"text":"合成测试"}]}}"#.utf8)
        let response = try VolcengineRealtimeFrame.encode(type: 9, sequence: 1, payload: payload, json: true)
        XCTAssertEqual(try codec.consume(.binary(response)), [.ready, .transcript(.partial(text: "合成测试"))])
        let finalPayload = Data(#"{"result":{"utterances":[{"definite":true,"start_time":0,"end_time":1000,"text":"合成测试。"}]}}"#.utf8)
        let finalResponse = try VolcengineRealtimeFrame.encode(type: 9, sequence: -2, payload: finalPayload, json: true)
        XCTAssertEqual(try codec.consume(.binary(finalResponse)), [.ready, .transcript(.stableSentence(id: "end-1000", text: "合成测试。", endSample: 16000)), .completed])
    }

    func testVolcanoPartialWithoutTimestampsDoesNotWeakenFinalValidation() throws {
        var codec = RealtimeWireCodec(configuration: .volcengine(apiKey: "test"))
        let payload = Data(#"{"result":{"utterances":[{"definite":false,"text":"合成测试"}]}}"#.utf8)
        let partial = try VolcengineRealtimeFrame.encode(type: 9, sequence: 1, payload: payload, json: true)
        XCTAssertEqual(try codec.consume(.binary(partial)), [.ready, .transcript(.partial(text: "合成测试"))])
        let final = try VolcengineRealtimeFrame.encode(type: 9, sequence: -2, payload: payload, json: true)
        XCTAssertThrowsError(try codec.consume(.binary(final))) {
            XCTAssertEqual($0 as? RealtimeASRError, .invalidResponse)
        }
    }

    func testVolcanoFinalDoesNotRequireStartTime() throws {
        var codec = RealtimeWireCodec(configuration: .volcengine(apiKey: "test"))
        // Real final response shape from validation; text is synthetic.
        let payload = Data(#"{"result":{"text":"合成测试","utterances":[{"definite":true,"end_time":2342,"text":"合成测试"}]}}"#.utf8)
        let response = try VolcengineRealtimeFrame.encode(type: 9, sequence: -7, payload: payload, json: true)
        XCTAssertEqual(try codec.consume(.binary(response)), [.ready, .transcript(.stableSentence(id: "end-2342", text: "合成测试", endSample: 37472)), .completed])
    }

    func testVolcanoSessionDeduplicatesWhenStartTimeAppearsInFinalSnapshot() async throws {
        let socket = ScriptedRealtimeSocket(mode: .volcanoSuccess)
        let session = RealtimeCloudASRSession(configuration: .volcengine(apiKey: "test"), transport: socket)
        try await session.connect()
        try await session.send(Data(repeating: 0, count: 3200))
        let result = try await session.finish()
        XCTAssertEqual(result, "合成测试。第二句。")
    }

    func testGzipRejectsExpansionBeyondResponseBudget() throws {
        let compressed = try VolcengineRealtimeFrame.gzip(Data(repeating: 0, count: 1_048_577))
        XCTAssertThrowsError(try VolcengineRealtimeFrame.gunzip(compressed))
    }

    func testSessionReceivesBeforeFinishAndDeduplicatesStableSentences() async throws {
        let socket = ScriptedRealtimeSocket()
        let session = RealtimeCloudASRSession(configuration: .tencent(appID: "1", secretID: "test", secretKey: "test"), transport: socket)
        try await session.connect()
        try await session.send(Data(repeating: 0, count: 1280))
        let result = try await session.finish()
        XCTAssertEqual(result, "合成测试。")
        let sent = await socket.sentMessages
        XCTAssertEqual(sent.last, .text("{\"type\":\"end\"}"))
        let closed = await socket.isClosed
        XCTAssertTrue(closed)
    }

    func testPrematureNormalCloseFails() async throws {
        let socket = ScriptedRealtimeSocket(mode: .prematureClose)
        let session = RealtimeCloudASRSession(configuration: .tencent(appID: "1", secretID: "test", secretKey: "test"), transport: socket)
        try await session.connect()
        await socket.simulatePrematureClose()
        do { _ = try await session.finish(); XCTFail("Premature close must not complete") }
        catch { XCTAssertEqual(error as? RealtimeASRError, .connectionClosed) }
    }

    func testMissingFinalTimesOutAndClosesSocket() async throws {
        let socket = ScriptedRealtimeSocket(mode: .noFinal)
        let session = RealtimeCloudASRSession(configuration: .tencent(appID: "1", secretID: "test", secretKey: "test"), transport: socket, finalTimeout: 0.02)
        try await session.connect()
        do { _ = try await session.finish(); XCTFail("Missing final must fail") }
        catch { XCTAssertEqual(error as? RealtimeASRError, .timeout) }
        let closed = await socket.isClosed
        XCTAssertTrue(closed)
    }

    func testCancelUnblocksReceiverAndDoesNotReturnPartialText() async throws {
        let socket = ScriptedRealtimeSocket(mode: .noFinal)
        let session = RealtimeCloudASRSession(configuration: .tencent(appID: "1", secretID: "test", secretKey: "test"), transport: socket)
        try await session.connect()
        await session.cancel()
        do { _ = try await session.finish(); XCTFail("Cancelled task must fail") }
        catch { XCTAssertEqual(error as? RealtimeASRError, .cancelled) }
        let closed = await socket.isClosed
        XCTAssertTrue(closed)
    }

    func testProviderErrorDoesNotExposeServerMessage() throws {
        var codec = RealtimeWireCodec(configuration: .tencent(appID: "1", secretID: "test", secretKey: "test"))
        do {
            _ = try codec.consume(.text("{\"code\":4002,\"message\":\"private-transcript-and-credential\"}"))
            XCTFail("Error expected")
        } catch {
            XCTAssertEqual(error as? RealtimeASRError, .authentication)
            XCTAssertFalse(error.localizedDescription.contains("private-transcript"))
        }
    }

    func testCancellationDuringRequestPreparationCannotOpenSocket() async throws {
        let socket = ScriptedRealtimeSocket()
        let session = RealtimeCloudASRSession(configuration: .tencent(appID: "1", secretID: "test", secretKey: "test"), transport: socket, requestBuilder: { _ in
            try await Task.sleep(for: .milliseconds(40))
            return URLRequest(url: URL(string: "wss://example.com")!)
        })
        let connection = Task { try await session.connect() }
        try await Task.sleep(for: .milliseconds(10))
        await session.cancel()
        do { try await connection.value; XCTFail("Cancelled connect must fail") }
        catch { XCTAssertEqual(error as? RealtimeASRError, .cancelled) }
        let count = await socket.connectCount
        let sent = await socket.sentMessages
        XCTAssertEqual(count, 0)
        XCTAssertTrue(sent.isEmpty)
    }

    func testConnectionUsesOneDeadlineForPreparationAndHandshake() async throws {
        let socket = ScriptedRealtimeSocket(connectDelay: .milliseconds(40))
        let session = RealtimeCloudASRSession(configuration: .tencent(appID: "1", secretID: "test", secretKey: "test"), transport: socket, connectTimeout: 0.06, requestBuilder: { _ in
            try await Task.sleep(for: .milliseconds(40))
            return URLRequest(url: URL(string: "wss://example.com")!)
        })
        do { try await session.connect(); XCTFail("Combined startup exceeds deadline") }
        catch { XCTAssertEqual(error as? RealtimeASRError, .timeout) }
        let closed = await socket.isClosed
        XCTAssertTrue(closed)
    }

    func testBlockedAudioSendTimesOutAndUnblocksTransport() async throws {
        let socket = ScriptedRealtimeSocket(mode: .blockedSend)
        let session = RealtimeCloudASRSession(configuration: .tencent(appID: "1", secretID: "test", secretKey: "test"), transport: socket, sendTimeout: 0.02)
        try await session.connect()
        do { try await session.send(Data(repeating: 0, count: 1280)); XCTFail("Blocked send must fail") }
        catch { XCTAssertEqual(error as? RealtimeASRError, .timeout) }
        let closed = await socket.isClosed
        XCTAssertTrue(closed)
    }

    func testNormalCloseAfterEndIsNotTencentFinal() async throws {
        let socket = ScriptedRealtimeSocket(mode: .closeAtFinish)
        let session = RealtimeCloudASRSession(configuration: .tencent(appID: "1", secretID: "test", secretKey: "test"), transport: socket)
        try await session.connect()
        do { _ = try await session.finish(); XCTFail("Tencent requires explicit final") }
        catch { XCTAssertEqual(error as? RealtimeASRError, .connectionClosed) }
    }

    func testXunfeiNormalCloseAfterBinaryEndCompletes() async throws {
        let socket = ScriptedRealtimeSocket(mode: .closeAtFinish)
        let session = RealtimeCloudASRSession(configuration: .xunfei(appID: "test", apiKey: "test"), transport: socket)
        try await session.connect()
        let text = try await session.finish()
        XCTAssertEqual(text, "")
        let sent = await socket.sentMessages
        XCTAssertEqual(sent, [.binary(Data("{\"end\":true}".utf8))])
    }

    private var bailian: RealtimeCloudASRConfiguration { .bailian(apiKey: "test", endpoint: URL(string: "wss://example.com/api-ws/v1/inference")!, model: "paraformer-realtime-v2") }
    private func json(_ message: RealtimeWebSocketMessage?) throws -> [String: Any] {
        guard case .text(let string) = message else { throw RealtimeASRError.invalidResponse }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any])
    }
}

private actor ScriptedRealtimeSocket: RealtimeWebSocketTransport {
    enum Mode { case success, prematureClose, noFinal, blockedSend, closeAtFinish, volcanoSuccess }
    let mode: Mode
    let connectDelay: Duration
    var connectCount = 0
    var sentMessages: [RealtimeWebSocketMessage] = []
    var isClosed = false
    private var pending: [RealtimeWebSocketMessage] = []
    private var waiter: CheckedContinuation<RealtimeWebSocketMessage, Error>?
    private var sendWaiter: CheckedContinuation<Void, Error>?
    init(mode: Mode = .success, connectDelay: Duration = .zero) { self.mode = mode; self.connectDelay = connectDelay }
    func connect(_ request: URLRequest) async throws {
        connectCount += 1
        try await Task.sleep(for: connectDelay)
        if mode == .volcanoSuccess { try enqueueVolcano("{}", final: false) }
        else if request.url?.host == "rtasr.xfyun.cn" { enqueue(.text("{\"action\":\"started\",\"code\":\"0\"}")) }
        else { enqueue(.text("{\"code\":0}")) }
    }
    func simulatePrematureClose() { enqueue(.closed(normal: true)) }
    func send(_ message: RealtimeWebSocketMessage) async throws {
        sentMessages.append(message)
        if mode == .volcanoSuccess, case .binary(let data) = message {
            guard data.count >= 4, data[1] >> 4 == 2 else { return }
            if data[1] & 2 != 0 {
                try enqueueVolcano(#"{"result":{"utterances":[{"text":"合成测试。","start_time":0,"end_time":2342,"definite":true},{"text":"第二句。","end_time":3000,"definite":true}]}}"#, final: true)
            } else {
                try enqueueVolcano(#"{"result":{"utterances":[{"text":"合成","end_time":500,"definite":false}]}}"#, final: false)
                try enqueueVolcano(#"{"result":{"utterances":[{"text":"合成测试。","end_time":2342,"definite":true}]}}"#, final: false)
            }
            return
        }
        if mode == .blockedSend { return try await withCheckedThrowingContinuation { sendWaiter = $0 } }
        if mode == .closeAtFinish {
            enqueue(.closed(normal: true))
            return
        }
        if case .binary = message {
            let sentence = RealtimeWebSocketMessage.text("{\"code\":0,\"result\":{\"index\":0,\"slice_type\":2,\"voice_text_str\":\"合成测试。\",\"end_time\":40}}")
            enqueue(sentence); enqueue(sentence)
        }
        if message == .text("{\"type\":\"end\"}"), mode == .success { enqueue(.text("{\"code\":0,\"final\":1}")) }
    }
    func receive() async throws -> RealtimeWebSocketMessage {
        if !pending.isEmpty { return pending.removeFirst() }
        if isClosed { throw RealtimeASRError.connectionClosed }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func close() async {
        isClosed = true
        sendWaiter?.resume(throwing: RealtimeASRError.connectionClosed)
        sendWaiter = nil
        waiter?.resume(throwing: RealtimeASRError.connectionClosed)
        waiter = nil
    }
    private func enqueue(_ message: RealtimeWebSocketMessage) {
        if let waiter { self.waiter = nil; waiter.resume(returning: message) }
        else { pending.append(message) }
    }
    private func enqueueVolcano(_ json: String, final: Bool) throws {
        enqueue(.binary(try VolcengineRealtimeFrame.encode(type: 9, sequence: final ? -7 : 1, payload: Data(json.utf8), json: true)))
    }
}
