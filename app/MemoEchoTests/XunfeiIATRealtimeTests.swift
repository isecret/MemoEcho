import CryptoKit
import XCTest
@testable import MemoEcho

final class XunfeiIATRealtimeTests: XCTestCase {
    private var config: RealtimeCloudASRConfiguration { .xunfeiIAT(appID: "synthetic-app", apiKey: "synthetic-key", apiSecret: "synthetic-secret") }

    func testSignedRequestUsesIATDateAndHMACSHA256() async throws {
        let request = try await RealtimeWireCodec.makeRequest(configuration: config, now: Date(timeIntervalSince1970: 0))
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.host, "iat-api.xfyun.cn")
        XCTAssertEqual(url.path, "/v2/iat")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["date"], "Thu, 01 Jan 1970 00:00:00 GMT")
        let origin = "host: iat-api.xfyun.cn\ndate: Thu, 01 Jan 1970 00:00:00 GMT\nGET /v2/iat HTTP/1.1"
        let expected = Data(HMAC<SHA256>.authenticationCode(for: Data(origin.utf8), using: SymmetricKey(data: Data("synthetic-secret".utf8)))).base64EncodedString()
        let auth = String(decoding: try XCTUnwrap(Data(base64Encoded: XCTUnwrap(query["authorization"]))), as: UTF8.self)
        XCTAssertTrue(auth.contains("signature=\"\(expected)\""))
        XCTAssertNil(query["signa"])
        XCTAssertEqual(config.capabilities.maximumSessionSeconds, 55)
        XCTAssertEqual(config.capabilities.preferredFrameBytes, 1280)
        XCTAssertFalse(config.capabilities.allowsPreconnection)
    }

    func testFirstIntermediateAndFinalFramesMatchIATContract() throws {
        var codec = RealtimeWireCodec(configuration: config)
        XCTAssertTrue(codec.readyAfterTransportConnect)
        XCTAssertFalse(codec.completesOnNormalClose)
        XCTAssertNil(try codec.startMessage())
        XCTAssertThrowsError(try codec.finishMessage())
        let audio = Data([1, 2, 3, 4])
        let first = try json(codec.audioMessage(audio))
        XCTAssertEqual((first["common"] as? [String: String])?["app_id"], "synthetic-app")
        let business = try XCTUnwrap(first["business"] as? [String: Any])
        XCTAssertEqual(business["dwa"] as? String, "wpgs")
        XCTAssertEqual(business["eos"] as? Int, 10000)
        let data = try XCTUnwrap(first["data"] as? [String: Any])
        XCTAssertEqual(data["status"] as? Int, 0)
        XCTAssertEqual(data["format"] as? String, "audio/L16;rate=16000")
        XCTAssertEqual(data["encoding"] as? String, "raw")
        XCTAssertEqual(data["audio"] as? String, audio.base64EncodedString())
        let middle = try json(codec.audioMessage(audio))
        XCTAssertNil(middle["common"])
        XCTAssertNil(middle["business"])
        XCTAssertEqual((middle["data"] as? [String: Any])?["status"] as? Int, 1)
        let final = try json(codec.finishMessage())
        XCTAssertEqual(final["data"] as? [String: Int], ["status": 2])
    }

    func testCorrectionsReplaceFragmentsAndOnlyFinalCommitsText() throws {
        var codec = RealtimeWireCodec(configuration: config)
        XCTAssertEqual(try codec.consume(response(sn: 0, text: "错误", status: 0)), [.transcript(.partial(text: "错误"))])
        XCTAssertEqual(try codec.consume(response(sn: 1, text: "片段")), [.transcript(.partial(text: "错误片段"))])
        let correction = try response(sn: 2, text: "正确", mode: "rpl", range: [0, 1])
        XCTAssertEqual(try codec.consume(correction), [.transcript(.partial(text: "正确"))])
        XCTAssertEqual(try codec.consume(correction), [.transcript(.partial(text: "正确"))])
        XCTAssertEqual(try codec.consume(response(sn: 3, text: "结果", status: 2)), [.transcript(.stableSentence(id: "iat-final", text: "正确结果", endSample: nil)), .completed])
    }

    func testMalformedCorrectionAndServerErrorsCannotPublishText() throws {
        for range in [[2, 0], [-1, 0], [0, 2]] {
            var codec = RealtimeWireCodec(configuration: config)
            XCTAssertThrowsError(try codec.consume(response(sn: 2, text: "无效", mode: "rpl", range: range)))
        }
        var codec = RealtimeWireCodec(configuration: config)
        XCTAssertThrowsError(try codec.consume(.text(#"{"code":10005,"message":"private-transcript-and-secret"}"#))) { error in
            XCTAssertEqual(error as? RealtimeASRError, .authentication)
            XCTAssertFalse(error.localizedDescription.contains("private-transcript"))
        }
        XCTAssertThrowsError(try codec.consume(.text(#"{"code":0,"data":{"status":1}}"#)))
    }

    func testConnectDoesNotWaitForRecognitionAndUploadsBeforeFinish() async throws {
        let socket = IATTestSocket()
        let session = RealtimeCloudASRSession(configuration: config, transport: socket, connectTimeout: 0.1)
        try await session.connect()
        let beforeAudio = await socket.messages
        XCTAssertTrue(beforeAudio.isEmpty)
        try await session.send(Data([1, 2]))
        let sent = await socket.messages
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual((try json(sent[0])["data"] as? [String: Any])?["status"] as? Int, 0)
        let result = try await session.finish()
        XCTAssertEqual(result, "合成结果")
    }

    func testNormalCloseWithoutExplicitFinalFails() async throws {
        let socket = IATTestSocket(closeWithoutFinal: true)
        let session = RealtimeCloudASRSession(configuration: config, transport: socket)
        try await session.connect()
        try await session.send(Data([1, 2]))
        do { _ = try await session.finish(); XCTFail("IAT requires data.status=2") }
        catch { XCTAssertEqual(error as? RealtimeASRError, .connectionClosed) }
    }

    private func response(sn: Int, text: String, status: Int = 1, mode: String = "apd", range: [Int]? = nil) throws -> RealtimeWebSocketMessage {
        var result: [String: Any] = ["sn": sn, "pgs": mode, "ws": [["cw": [["w": text]]]]]
        if let range { result["rg"] = range }
        return .text(String(decoding: try JSONSerialization.data(withJSONObject: ["code": 0, "data": ["status": status, "result": result]]), as: UTF8.self))
    }
    private func json(_ message: RealtimeWebSocketMessage) throws -> [String: Any] {
        guard case .text(let text) = message else { throw RealtimeASRError.invalidResponse }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}

private actor IATTestSocket: RealtimeWebSocketTransport {
    let closeWithoutFinal: Bool
    private(set) var messages: [RealtimeWebSocketMessage] = []
    private var pending: [RealtimeWebSocketMessage] = []
    private var waiter: CheckedContinuation<RealtimeWebSocketMessage, Error>?
    init(closeWithoutFinal: Bool = false) { self.closeWithoutFinal = closeWithoutFinal }
    func connect(_ request: URLRequest) async throws { }
    func send(_ message: RealtimeWebSocketMessage) async throws {
        messages.append(message)
        guard case .text(let text) = message,
              let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let data = object["data"] as? [String: Any] else { throw RealtimeASRError.invalidResponse }
        let status = data["status"] as? Int
        let response: RealtimeWebSocketMessage = status == 2
            ? (closeWithoutFinal ? .closed(normal: true) : .text(#"{"code":0,"data":{"status":2,"result":{"sn":1,"ws":[{"cw":[{"w":"结果"}]}]}}}"#))
            : .text(#"{"code":0,"data":{"status":1,"result":{"sn":0,"ws":[{"cw":[{"w":"合成"}]}]}}}"#)
        if let waiter { self.waiter = nil; waiter.resume(returning: response) }
        else { pending.append(response) }
    }
    func receive() async throws -> RealtimeWebSocketMessage {
        if !pending.isEmpty { return pending.removeFirst() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func close() async { waiter?.resume(throwing: RealtimeASRError.connectionClosed); waiter = nil }
}
