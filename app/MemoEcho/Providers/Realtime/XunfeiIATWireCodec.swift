import CryptoKit
import Foundation

/// IAT sends JSON audio frames and can replace previous transcription fragments.
/// Keep mutable fragments private until the vendor explicitly completes the task.
struct XunfeiIATWireCodec: Sendable {
    private var sentFirstFrame = false
    private var fragments: [Int: String] = [:]
    private var completed = false

    static func makeRequest(appID: String, apiKey: String, apiSecret: String, now: Date) throws -> URLRequest {
        guard !appID.isEmpty, !apiKey.isEmpty, !apiSecret.isEmpty else { throw RealtimeASRError.configuration }
        let host = "iat-api.xfyun.cn"
        let path = "/v2/iat"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let date = formatter.string(from: now)
        let origin = "host: \(host)\ndate: \(date)\nGET \(path) HTTP/1.1"
        let signature = Data(HMAC<SHA256>.authenticationCode(for: Data(origin.utf8), using: SymmetricKey(data: Data(apiSecret.utf8)))).base64EncodedString()
        let auth = "api_key=\"\(apiKey)\", algorithm=\"hmac-sha256\", headers=\"host date request-line\", signature=\"\(signature)\""
        var parts = URLComponents()
        parts.scheme = "wss"
        parts.host = host
        parts.path = path
        parts.queryItems = [.init(name: "authorization", value: Data(auth.utf8).base64EncodedString()),
                            .init(name: "date", value: date), .init(name: "host", value: host)]
        guard let url = parts.url else { throw RealtimeASRError.configuration }
        return URLRequest(url: url)
    }

    mutating func audioMessage(_ pcm: Data, appID: String) throws -> RealtimeWebSocketMessage {
        guard !completed, !pcm.isEmpty, pcm.count % 2 == 0 else { throw RealtimeASRError.invalidState }
        var frame: [String: Any] = ["data": ["status": sentFirstFrame ? 1 : 0,
            "format": "audio/L16;rate=16000", "encoding": "raw", "audio": pcm.base64EncodedString()]]
        if !sentFirstFrame {
            frame["common"] = ["app_id": appID]
            frame["business"] = ["language": "zh_cn", "domain": "iat", "accent": "mandarin",
                                 "dwa": "wpgs", "eos": 10000]
        }
        let message = try Self.json(frame)
        sentFirstFrame = true
        return message
    }

    func finishMessage() throws -> RealtimeWebSocketMessage {
        guard sentFirstFrame, !completed else { throw RealtimeASRError.invalidState }
        return try Self.json(["data": ["status": 2]])
    }

    mutating func consume(_ object: [String: Any]) throws -> [RealtimeWireCodec.Event] {
        guard !completed, let code = object["code"] as? Int else { throw RealtimeASRError.invalidResponse }
        guard code == 0 else {
            if [10005, 10010, 10110, 11200].contains(code) { throw RealtimeASRError.authentication }
            throw RealtimeASRError.serviceRejected
        }
        guard let data = object["data"] as? [String: Any], let status = data["status"] as? Int,
              (0...2).contains(status) else { throw RealtimeASRError.invalidResponse }
        if let result = data["result"] as? [String: Any] {
            guard let sn = result["sn"] as? Int, sn >= 0, sn < 8000,
                  let words = result["ws"] as? [[String: Any]] else { throw RealtimeASRError.invalidResponse }
            let text = try words.map { word -> String in
                guard let candidates = word["cw"] as? [[String: Any]],
                      let candidate = candidates.first, let text = candidate["w"] as? String else {
                    throw RealtimeASRError.invalidResponse
                }
                return text
            }.joined()
            if let mode = result["pgs"] as? String {
                switch mode {
                case "rpl":
                    guard let range = result["rg"] as? [Int], range.count == 2,
                          range[0] >= 0, range[0] <= range[1], range[1] < sn else { throw RealtimeASRError.invalidResponse }
                    fragments = fragments.filter { !(range[0]...range[1]).contains($0.key) }
                case "apd": break
                default: throw RealtimeASRError.invalidResponse
                }
            }
            if let previous = fragments[sn], previous != text { throw RealtimeASRError.invalidResponse }
            fragments[sn] = text
        } else if status != 2 { throw RealtimeASRError.invalidResponse }
        let text = fragments.keys.sorted().compactMap { fragments[$0] }.joined()
        guard text.count <= 8000 else { throw RealtimeASRError.textLimit }
        if status == 2 {
            completed = true
            return [.transcript(.stableSentence(id: "iat-final", text: text, endSample: nil)), .completed]
        }
        return [.transcript(.partial(text: text))]
    }

    private static func json(_ object: [String: Any]) throws -> RealtimeWebSocketMessage {
        .text(String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self))
    }
}
