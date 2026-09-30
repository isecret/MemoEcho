import Foundation

/// Historical sentence/streaming products share V2 framing, with separate product clusters.
/// Server completion is JSON sequence < 0; unlike V3, the binary server flags remain zero.
struct VolcengineTraditionalWireCodec: Sendable {
    let taskID: String
    private var confirmedSnapshot: String?
    private var hasReceivedText = false

    init(taskID: String = UUID().uuidString) { self.taskID = taskID }

    static func makeRequest(appID: String, accessToken: String, cluster: String) throws -> URLRequest {
        guard !appID.isEmpty, !accessToken.isEmpty, !cluster.isEmpty,
              !accessToken.contains("\r"), !accessToken.contains("\n") else { throw RealtimeASRError.configuration }
        var request = URLRequest(url: URL(string: "wss://openspeech.bytedance.com/api/v2/asr")!)
        // The vendor's historical Bearer scheme uses a semicolon, not the usual space-only form.
        request.setValue("Bearer; \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    func startMessage(appID: String, accessToken: String, cluster: String) throws -> RealtimeWebSocketMessage {
        let payload = try JSONSerialization.data(withJSONObject: [
            "app": ["appid": appID, "token": accessToken, "cluster": cluster],
            "user": ["uid": "memoecho"],
            "audio": ["format": "raw", "codec": "raw", "rate": 16000, "bits": 16, "channel": 1],
            "request": ["reqid": taskID, "sequence": 1, "nbest": 1, "show_utterances": true,
                        "workflow": "audio_in,resample,partition,vad,fe,decode,itn,nlu_punctuate"]
        ])
        return .binary(try VolcengineTraditionalFrame.encodeClient(type: 1, payload: payload, json: true))
    }

    func audioMessage(_ pcm: Data) throws -> RealtimeWebSocketMessage {
        .binary(try VolcengineTraditionalFrame.encodeClient(type: 2, payload: pcm, json: false))
    }

    func finishMessage() throws -> RealtimeWebSocketMessage {
        .binary(try VolcengineTraditionalFrame.encodeClient(type: 2, payload: Data(), json: false, final: true))
    }

    mutating func consume(_ message: RealtimeWebSocketMessage) throws -> [RealtimeWireCodec.Event] {
        guard case .binary(let frame) = message else { throw RealtimeASRError.invalidResponse }
        let payload = try VolcengineTraditionalFrame.decodeServer(frame)
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let code = object["code"] as? Int else { throw RealtimeASRError.invalidResponse }
        if code != 1000 { throw Self.rejection(code) }
        guard let reqID = object["reqid"] as? String, reqID == taskID else { throw RealtimeASRError.invalidResponse }
        var last = false
        if let sequence = object["sequence"] {
            guard let value = sequence as? Int, value != 0 else { throw RealtimeASRError.invalidResponse }
            last = value < 0
        }
        var text: String?
        if let rawResults = object["result"] {
            guard let results = rawResults as? [[String: Any]] else { throw RealtimeASRError.invalidResponse }
            if let result = results.first {
                let utterances = result["utterances"] as? [[String: Any]] ?? []
                if let fullText = result["text"] as? String {
                    text = fullText
                } else if !utterances.isEmpty {
                    text = try utterances.map { utterance -> String in
                        guard let value = utterance["text"] as? String else { throw RealtimeASRError.invalidResponse }
                        return value
                    }.joined()
                }
                // Empty result objects are acknowledgements. A new snapshot supersedes previous
                // confirmation, but an acknowledgement must not discard confirmed recognition.
                if text != nil {
                    confirmedSnapshot = !utterances.isEmpty && utterances.allSatisfy({ $0["definite"] as? Bool == true }) ? text : nil
                }
                if let text, !text.isEmpty { hasReceivedText = true }
            }
        }
        var events: [RealtimeWireCodec.Event] = [.ready]
        if last {
            guard text != nil || confirmedSnapshot != nil || !hasReceivedText else { throw RealtimeASRError.invalidResponse }
            if let finalText = text ?? confirmedSnapshot, !finalText.isEmpty {
                guard finalText.count <= 8000 else { throw RealtimeASRError.textLimit }
                events.append(.transcript(.stableSentence(id: "traditional-final", text: finalText, endSample: nil)))
            }
            events.append(.completed)
        } else if let text, !text.isEmpty {
            guard text.count <= 8000 else { throw RealtimeASRError.textLimit }
            // Default V2 responses contain the whole transcript and can repeat or revise text.
            events.append(.transcript(.partial(text: text)))
        }
        return events
    }

    static func rejection(_ code: Int) -> RealtimeASRError {
        switch code {
        case 1002: .authentication
        case 1010: .sessionLimit
        case 1020, 1021: .timeout
        default: .serviceRejected
        }
    }
}

/// V2 full server responses have no sequence integer in their binary header. Their JSON
/// sequence field carries completion; only audio client frames use the terminal bit.
enum VolcengineTraditionalFrame {
    static func encodeClient(type: UInt8, payload: Data, json: Bool, final: Bool = false) throws -> Data {
        guard type == 1 || type == 2, !final || type == 2 else { throw RealtimeASRError.invalidState }
        let compressed = try VolcengineRealtimeFrame.gzip(payload)
        var data = Data([0x11, (type << 4) | (final ? 2 : 0), json ? 0x11 : 0x01, 0])
        append(UInt32(compressed.count), to: &data)
        data.append(compressed)
        return data
    }

    static func decodeServer(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, bytes[0] >> 4 == 1 else { throw RealtimeASRError.invalidResponse }
        let headerSize = Int(bytes[0] & 0x0F) * 4
        guard headerSize >= 4, bytes.count >= headerSize + 4, bytes[1] & 0x0F == 0 else { throw RealtimeASRError.invalidResponse }
        let type = bytes[1] >> 4
        if type == 15 {
            guard bytes.count >= headerSize + 8 else { throw RealtimeASRError.invalidResponse }
            let code = Int(read(bytes, at: headerSize))
            let count = Int(read(bytes, at: headerSize + 4))
            guard count <= 1_048_576, bytes.count == headerSize + 8 + count else { throw RealtimeASRError.invalidResponse }
            throw VolcengineTraditionalWireCodec.rejection(code)
        }
        guard type == 9, bytes[2] >> 4 == 1 else { throw RealtimeASRError.invalidResponse }
        let count = Int(read(bytes, at: headerSize))
        let offset = headerSize + 4
        guard count <= 1_048_576, bytes.count == offset + count else { throw RealtimeASRError.invalidResponse }
        let payload = Data(bytes[offset...])
        switch bytes[2] & 0x0F {
        case 0: return payload
        case 1: return try VolcengineRealtimeFrame.gunzip(payload)
        default: throw RealtimeASRError.invalidResponse
        }
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                                UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }
    private static func read(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        bytes[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
