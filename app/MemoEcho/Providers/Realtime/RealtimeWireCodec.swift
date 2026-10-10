import CryptoKit
import Foundation

/// Protocol contracts: Tencent 53937; Alibaba NLS WebSocket; Bailian Paraformer client/server
/// events; Volcano bigmodel_async / bigmodel_nostream; iFlytek RTASR v1 and IAT v2.
struct RealtimeWireCodec: Sendable {
    enum Event: Sendable, Equatable { case ready, completed, transcript(RealtimeASREvent) }
    let configuration: RealtimeCloudASRConfiguration
    let taskID: String
    private var iat = XunfeiIATWireCodec()
    private var traditional: VolcengineTraditionalWireCodec
    private var sequence: Int32 = 1
    private var bailianSentenceID = 0
    private var hasVolcengineCommittedSentence = false
    private var volcengineConfirmedSnapshot: String?
    private var hasVolcengineSentenceText = false
    init(configuration: RealtimeCloudASRConfiguration, taskID: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()) {
        self.configuration = configuration
        self.taskID = taskID
        self.traditional = VolcengineTraditionalWireCodec(taskID: taskID)
    }
    var readyAfterTransportConnect: Bool { if case .xunfeiIAT = configuration { true } else { false } }
    var completesOnNormalClose: Bool { if case .xunfei = configuration { true } else { false } }

    static func makeRequest(configuration: RealtimeCloudASRConfiguration, now: Date = Date()) async throws -> URLRequest {
        let timestamp = String(Int(now.timeIntervalSince1970))
        var request: URLRequest
        switch configuration {
        case .tencent(let appID, let secretID, let secretKey):
            guard !appID.isEmpty, appID.allSatisfy(\.isNumber), !secretID.isEmpty, !secretKey.isEmpty else { throw RealtimeASRError.configuration }
            let hostPath = "asr.cloud.tencent.com/asr/v2/\(appID)"
            var params = ["secretid": secretID, "timestamp": timestamp,
                          "expired": String(Int(now.timeIntervalSince1970) + 3600),
                          "nonce": String(UInt32.random(in: 1...UInt32.max)),
                          "engine_model_type": "16k_zh", "voice_id": String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)),
                          "voice_format": "1", "needvad": "1", "filter_empty_result": "0"]
            let raw = params.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
            params["signature"] = hmacSHA1(secretKey, hostPath + "?" + raw)
            request = URLRequest(url: try signedURL("wss://" + hostPath, params))
        case .aliyun(let key, let secret, let appKey):
            guard !key.isEmpty, !secret.isEmpty, !appKey.isEmpty else { throw RealtimeASRError.configuration }
            let token = try await fetchAliyunToken(key: key, secret: secret, now: now)
            request = URLRequest(url: try signedURL("wss://nls-gateway-cn-shanghai.aliyuncs.com/ws/v1", ["token": token]))
        case .bailian(let key, let endpoint, let model):
            guard !key.isEmpty, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, endpoint.scheme == "wss", endpoint.host != nil,
                  endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil,
                  endpoint.path == "/api-ws/v1/inference" else { throw RealtimeASRError.configuration }
            request = URLRequest(url: endpoint)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .volcengine(let key, let resourceID, let mode, _):
            let resources = ["volc.bigasr.sauc.duration", "volc.seedasr.sauc.duration",
                             "volc.bigasr.sauc.concurrent", "volc.seedasr.sauc.concurrent"]
            guard !key.isEmpty, resources.contains(resourceID) else { throw RealtimeASRError.configuration }
            let path = mode == .sentence ? "bigmodel_nostream" : "bigmodel_async"
            request = URLRequest(url: URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/\(path)")!)
            request.setValue(key, forHTTPHeaderField: "X-Api-Key")
            request.setValue(resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
            let requestID = UUID().uuidString
            request.setValue(requestID, forHTTPHeaderField: "X-Api-Connect-Id")
            request.setValue(requestID, forHTTPHeaderField: "X-Api-Request-Id")
            request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
        case .volcengineTraditional(let appID, let accessToken, let cluster, _):
            request = try VolcengineTraditionalWireCodec.makeRequest(appID: appID, accessToken: accessToken, cluster: cluster)
        case .xunfeiIAT(let appID, let key, let secret):
            request = try XunfeiIATWireCodec.makeRequest(appID: appID, apiKey: key, apiSecret: secret, now: now)
        case .xunfei(let appID, let key):
            guard !appID.isEmpty, !key.isEmpty else { throw RealtimeASRError.configuration }
            let md5 = Insecure.MD5.hash(data: Data((appID + timestamp).utf8)).map { String(format: "%02x", $0) }.joined()
            request = URLRequest(url: try signedURL("wss://rtasr.xfyun.cn/v1/ws", ["appid": appID, "ts": timestamp, "signa": hmacSHA1(key, md5)]))
        }
        request.timeoutInterval = 8
        return request
    }

    func startMessage() throws -> RealtimeWebSocketMessage? {
        switch configuration {
        case .volcengineTraditional(let appID, let accessToken, let cluster, _):
            return try traditional.startMessage(appID: appID, accessToken: accessToken, cluster: cluster)
        case .aliyun(_, _, let appKey):
            return try jsonMessage(["header": ["appkey": appKey, "message_id": Self.identifier(), "task_id": taskID,
                                                   "namespace": "SpeechTranscriber", "name": "StartTranscription"],
                                    "payload": ["format": "pcm", "sample_rate": 16000, "enable_intermediate_result": true,
                                                "enable_punctuation_prediction": true, "enable_inverse_text_normalization": true]])
        case .bailian(_, _, let model):
            return try jsonMessage(["header": ["action": "run-task", "task_id": taskID, "streaming": "duplex"],
                                    "payload": ["task_group": "audio", "task": "asr", "function": "recognition", "model": model,
                                                "parameters": ["format": "pcm", "sample_rate": 16000, "semantic_punctuation_enabled": false, "heartbeat": true],
                                                "input": [:]]])
        case .volcengine(_, _, let mode, let hotwords):
            var options: [String: Any] = ["model_name": "bigmodel", "enable_itn": true,
                                         "enable_punc": true, "show_utterances": true, "result_type": "full"]
            if mode == .streaming { options["enable_nonstream"] = true }
            if let context = try hotwords.context() { options["corpus"] = ["context": context] }
            let data = try JSONSerialization.data(withJSONObject: ["user": ["uid": "memoecho"],
                "audio": ["format": "pcm", "codec": "raw", "rate": 16000, "bits": 16, "channel": 1],
                "request": options])
            return .binary(try VolcengineRealtimeFrame.encode(type: 1, sequence: 1, payload: data, json: true))
        default: return nil
        }
    }
    mutating func audioMessage(_ pcm: Data) throws -> RealtimeWebSocketMessage {
        if case .volcengineTraditional = configuration { return try traditional.audioMessage(pcm) }
        if case .xunfeiIAT(let appID, _, _) = configuration { return try iat.audioMessage(pcm, appID: appID) }
        if case .volcengine = configuration {
            sequence += 1
            return .binary(try VolcengineRealtimeFrame.encode(type: 2, sequence: sequence, payload: pcm, json: false))
        }
        return .binary(pcm)
    }
    mutating func finishMessage() throws -> RealtimeWebSocketMessage {
        switch configuration {
        case .tencent: return .text("{\"type\":\"end\"}")
        case .xunfeiIAT: return try iat.finishMessage()
        case .xunfei: return .binary(Data("{\"end\":true}".utf8))
        case .aliyun(_, _, let appKey):
            return try jsonMessage(["header": ["appkey": appKey, "message_id": Self.identifier(), "task_id": taskID,
                                                   "namespace": "SpeechTranscriber", "name": "StopTranscription"]])
        case .bailian:
            return try jsonMessage(["header": ["action": "finish-task", "task_id": taskID, "streaming": "duplex"], "payload": ["input": [:]]])
        case .volcengine:
            sequence += 1
            return .binary(try VolcengineRealtimeFrame.encode(type: 2, sequence: -sequence, payload: Data(), json: false))
        case .volcengineTraditional: return try traditional.finishMessage()
        }
    }

    mutating func consume(_ message: RealtimeWebSocketMessage) throws -> [Event] {
        if case .volcengineTraditional = configuration { return try traditional.consume(message) }
        let data: Data
        var last = false
        if case .volcengine = configuration {
            guard case .binary(let bytes) = message else { throw RealtimeASRError.invalidResponse }
            let frame = try VolcengineRealtimeFrame.decode(bytes)
            data = frame.payload
            last = frame.final
        } else {
            switch message {
            case .text(let text): data = Data(text.utf8)
            case .binary(let bytes): data = bytes
            case .closed: throw RealtimeASRError.connectionClosed
            }
        }
        guard data.count <= 1_048_576,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RealtimeASRError.invalidResponse }
        var events: [Event] = []
        switch configuration {
        case .volcengineTraditional:
            throw RealtimeASRError.invalidState // Handled by its independent V2 decoder above.
        case .tencent:
            guard let code = object["code"] as? Int else { throw RealtimeASRError.invalidResponse }
            guard code == 0 else { throw code == 4002 ? RealtimeASRError.authentication : .serviceRejected }
            if let result = object["result"] as? [String: Any] {
                if let text = result["voice_text_str"] as? String, let id = result["index"] as? Int {
                    events.append(transcript(id: String(id), text: text, stable: result["slice_type"] as? Int == 2, milliseconds: Self.integer(result["end_time"])))
                }
            } else if object["final"] == nil { events.append(.ready) }
            if object["final"] as? Int == 1 { events.append(.completed) }
        case .aliyun:
            guard let header = object["header"] as? [String: Any], let name = header["name"] as? String else { throw RealtimeASRError.invalidResponse }
            // A gateway rejection can occur before the requested task is assigned. Preserve its
            // numeric status without echoing potentially sensitive status_text into UI or logs.
            if let status = header["status"] as? Int, status != 20000000 {
                throw RealtimeASRError.aliyunRejected(status: status)
            }
            if name == "TaskFailed" { throw RealtimeASRError.serviceRejected }
            if let responseID = header["task_id"] as? String, responseID != taskID { throw RealtimeASRError.invalidResponse }
            switch name {
            case "TranscriptionStarted": events.append(.ready)
            case "TranscriptionCompleted": events.append(.completed)
            case "SentenceEnd", "TranscriptionResultChanged":
                guard let payload = object["payload"] as? [String: Any], let text = payload["result"] as? String,
                      let index = payload["index"] as? Int else { throw RealtimeASRError.invalidResponse }
                events.append(transcript(id: String(index), text: text, stable: name == "SentenceEnd", milliseconds: Self.integer(payload["time"])))
            default: break
            }
        case .bailian:
            guard let header = object["header"] as? [String: Any], let event = header["event"] as? String else { throw RealtimeASRError.invalidResponse }
            if let responseID = header["task_id"] as? String, responseID != taskID { throw RealtimeASRError.invalidResponse }
            switch event {
            case "task-started": events.append(.ready)
            case "task-finished": events.append(.completed)
            case "task-failed": throw RealtimeASRError.serviceRejected
            case "result-generated":
                guard let payload = object["payload"] as? [String: Any], let output = payload["output"] as? [String: Any],
                      let sentence = output["sentence"] as? [String: Any] else { throw RealtimeASRError.invalidResponse }
                if let text = sentence["text"] as? String {
                    let stable = sentence["sentence_end"] as? Bool == true
                    let begin = Self.integer(sentence["begin_time"])
                    let end = Self.integer(sentence["end_time"])
                    // begin_time is stable for a sentence and permits duplicate final suppression.
                    let id = begin.map(String.init) ?? "sentence-\(bailianSentenceID)"
                    events.append(transcript(id: id, text: text, stable: stable, milliseconds: end))
                    if stable { bailianSentenceID += 1 }
                }
            default: break
            }
        case .xunfeiIAT:
            events = try iat.consume(object)
        case .xunfei:
            guard let action = object["action"] as? String else { throw RealtimeASRError.invalidResponse }
            let code = Self.integer(object["code"])
            if action == "error" || (code != nil && code != 0) { throw code == 10110 ? RealtimeASRError.authentication : .serviceRejected }
            if action == "started" { events.append(.ready) }
            if action == "result" {
                guard let string = object["data"] as? String,
                      let payload = try? JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any],
                      let cn = payload["cn"] as? [String: Any], let st = cn["st"] as? [String: Any],
                      let id = Self.integer(payload["seg_id"]), let rt = st["rt"] as? [[String: Any]] else { throw RealtimeASRError.invalidResponse }
                let text = rt.flatMap { $0["ws"] as? [[String: Any]] ?? [] }.compactMap { word in
                    (word["cw"] as? [[String: Any]])?.first?["w"] as? String
                }.joined()
                events.append(transcript(id: String(id), text: text, stable: Self.integer(st["type"]) == 0, milliseconds: Self.integer(st["ed"])))
            }
        case .volcengine(_, _, let mode, _):
            if let code = object["code"] as? Int, code != 0, code != 1000, code != 20000000 { throw RealtimeASRError.serviceRejected }
            events.append(.ready)
            let result = object["result"] as? [String: Any] ?? (object["result"] as? [[String: Any]])?.first
            if mode == .sentence {
                events += try consumeVolcengineSentence(result, last: last)
                break
            }
            if let result {
                let utterances = result["utterances"] as? [[String: Any]] ?? []
                for utterance in utterances {
                    guard let text = utterance["text"] as? String else { throw RealtimeASRError.invalidResponse }
                    let stable = last || utterance["definite"] as? Bool == true
                    // Interim utterances can omit timing fields. They are never committed or used
                    // as recovery boundaries; require an end timestamp only for a confirmed sentence.
                    guard stable else {
                        events.append(.transcript(.partial(text: text)))
                        continue
                    }
                    guard let end = Self.integer(utterance["end_time"]) else { throw RealtimeASRError.invalidResponse }
                    // The service also omits start_time on confirmed/final utterances. Use the
                    // confirmed end time as identity so a later full snapshot adding start_time
                    // cannot cause the same sentence to be committed twice.
                    events.append(transcript(id: "end-\(end)", text: text, stable: true, milliseconds: end))
                    hasVolcengineCommittedSentence = true
                }
                if last, utterances.isEmpty, let text = result["text"] as? String, !text.isEmpty {
                    guard !hasVolcengineCommittedSentence else { throw RealtimeASRError.invalidResponse }
                    // An unsegmented final snapshot is safe only when there were no committed sentences.
                    events.append(transcript(id: "final", text: text, stable: true, milliseconds: nil))
                }
            }
            if last { events.append(.completed) }
        }
        return events
    }

    /// Full snapshots can repeat or revise earlier text. Hold sentence-mode results until
    /// the terminal packet instead of turning successive snapshots into separate sentences.
    private mutating func consumeVolcengineSentence(_ result: [String: Any]?, last: Bool) throws -> [Event] {
        var text: String?
        if let result {
            let utterances = result["utterances"] as? [[String: Any]] ?? []
            if let fullText = result["text"] as? String {
                text = fullText
            } else if !utterances.isEmpty {
                let fragments = try utterances.map { utterance -> String in
                    guard let value = utterance["text"] as? String else { throw RealtimeASRError.invalidResponse }
                    return value
                }
                text = fragments.joined()
            }
            if text != nil {
                if !utterances.isEmpty, utterances.allSatisfy({ $0["definite"] as? Bool == true }) {
                    volcengineConfirmedSnapshot = text
                } else {
                    volcengineConfirmedSnapshot = nil
                }
            }
            if let text, !text.isEmpty { hasVolcengineSentenceText = true }
        }
        if last {
            guard text != nil || volcengineConfirmedSnapshot != nil || !hasVolcengineSentenceText else {
                throw RealtimeASRError.invalidResponse
            }
            var events: [Event] = []
            if let finalText = text ?? volcengineConfirmedSnapshot, !finalText.isEmpty {
                events.append(transcript(id: "sentence-final", text: finalText, stable: true, milliseconds: nil))
            }
            events.append(.completed)
            return events
        }
        if let text, !text.isEmpty { return [.transcript(.partial(text: text))] }
        return []
    }

    private func transcript(id: String, text: String, stable: Bool, milliseconds: Int64?) -> Event {
        if stable {
            let end = milliseconds.flatMap { $0 > 0 && $0 <= 90_000 ? $0 * 16 : nil }
            return .transcript(.stableSentence(id: id, text: text, endSample: end))
        }
        return .transcript(.partial(text: text))
    }
    private func jsonMessage(_ object: [String: Any]) throws -> RealtimeWebSocketMessage {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return .text(String(decoding: data, as: UTF8.self))
    }
    private static func integer(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? String { return Int64(value) }
        return nil
    }
    // NLS rejects uppercase hex IDs with MESSAGE_INVALID (40000002).
    private static func identifier() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
    static func hmacSHA1(_ key: String, _ message: String) -> String {
        Data(HMAC<Insecure.SHA1>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(key.utf8)))).base64EncodedString()
    }
    static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"))!
    }
    static func signedURL(_ base: String, _ parameters: [String: String]) throws -> URL {
        let query = parameters.sorted { $0.key < $1.key }.map { "\(percentEncode($0.key))=\(percentEncode($0.value))" }.joined(separator: "&")
        guard let url = URL(string: base + "?" + query) else { throw RealtimeASRError.configuration }
        return url
    }
    private static func fetchAliyunToken(key: String, secret: String, now: Date) async throws -> String {
        let formatter = ISO8601DateFormatter()
        var params = ["AccessKeyId": key, "Action": "CreateToken", "Format": "JSON", "RegionId": "cn-shanghai",
                      "SignatureMethod": "HMAC-SHA1", "SignatureNonce": UUID().uuidString, "SignatureVersion": "1.0",
                      "Timestamp": formatter.string(from: now), "Version": "2019-02-28"]
        let query = params.sorted { $0.key < $1.key }.map { "\(percentEncode($0.key))=\(percentEncode($0.value))" }.joined(separator: "&")
        params["Signature"] = hmacSHA1(secret + "&", "GET&%2F&" + percentEncode(query))
        var request = URLRequest(url: try signedURL("https://nls-meta.cn-shanghai.aliyuncs.com/", params))
        request.timeoutInterval = 8
        let session = URLSession(configuration: .ephemeral, delegate: RealtimeNoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw RealtimeASRError.invalidResponse }
        guard response.statusCode == 200 else { throw RealtimeASRError.authentication }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = (object["Token"] as? [String: Any])?["Id"] as? String, !token.isEmpty else { throw RealtimeASRError.authentication }
        return token
    }
}
