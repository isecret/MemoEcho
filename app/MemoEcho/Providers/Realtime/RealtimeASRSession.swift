import Foundation

struct RealtimeASRCapabilities: Sendable, Equatable {
    let preferredFrameBytes: Int
    let requiresRealtimePacing: Bool
    /// Client task window; the pipeline may start another native realtime task.
    let maximumSessionSeconds: TimeInterval
    let allowsPreconnection: Bool
    let maximumSilenceSeconds: TimeInterval?

    init(preferredFrameBytes: Int, requiresRealtimePacing: Bool, maximumSessionSeconds: TimeInterval,
         allowsPreconnection: Bool = true, maximumSilenceSeconds: TimeInterval? = nil) {
        self.preferredFrameBytes = preferredFrameBytes
        self.requiresRealtimePacing = requiresRealtimePacing
        self.maximumSessionSeconds = maximumSessionSeconds
        self.allowsPreconnection = allowsPreconnection
        self.maximumSilenceSeconds = maximumSilenceSeconds
    }
}

enum RealtimeASREvent: Sendable, Equatable {
    /// A vendor-confirmed immutable sentence. Timestamp is relative to this task's PCM.
    case stableSentence(id: String, text: String, endSample: Int64?)
    case partial(text: String)
}

protocol RealtimeASRSession: Sendable {
    var events: AsyncThrowingStream<RealtimeASREvent, Error> { get }
    var capabilities: RealtimeASRCapabilities { get }
    func connect() async throws
    /// PCM signed little-endian 16-bit, 16 kHz, mono. Calls must be serialized.
    func send(_ pcm: Data) async throws
    /// Flush upstream audio before calling. Returns only after explicit vendor completion.
    func finish() async throws -> String
    func cancel() async
}

enum RealtimeASRError: Error, LocalizedError, Equatable {
    case configuration, invalidResponse, authentication, serviceRejected, connectionClosed
    case aliyunRejected(status: Int)
    case timeout, cancelled, invalidState, textLimit, sessionLimit
    var errorDescription: String? {
        switch self {
        case .configuration: "实时语音服务配置不完整或不受支持"
        case .invalidResponse: "实时语音服务返回了无法解析的数据"
        case .authentication: "实时语音服务鉴权失败，请检查对应实时产品的凭据"
        case .serviceRejected: "实时语音服务拒绝了请求，请检查服务开通状态与额度"
        case .aliyunRejected(let status): "阿里云实时语音服务拒绝请求（错误码：\(status)）"
        case .connectionClosed: "实时语音连接意外中断，请重试"
        case .timeout: "实时语音服务响应超时"
        case .cancelled: "语音识别已取消"
        case .invalidState: "实时语音会话状态无效"
        case .textLimit: "识别文本超过 8000 字符"
        case .sessionLimit: "实时语音任务超过时长限制"
        }
    }
}

/// Both modes continuously upload PCM. Sentence mode returns full recognition snapshots
/// after enough audio or the terminal packet; streaming mode returns intermediate text.
enum VolcengineRealtimeMode: Sendable, Equatable {
    case sentence, streaming
}

enum RealtimeCloudASRConfiguration: Sendable {
    case tencent(appID: String, secretID: String, secretKey: String)
    case aliyun(accessKeyID: String, accessKeySecret: String, appKey: String)
    case bailian(apiKey: String, endpoint: URL, model: String)
    case volcengine(apiKey: String, resourceID: String = "volc.bigasr.sauc.duration", mode: VolcengineRealtimeMode = .streaming)
    case volcengineTraditional(appID: String, accessToken: String, cluster: String, mode: VolcengineRealtimeMode)
    case xunfeiIAT(appID: String, apiKey: String, apiSecret: String)
    case xunfei(appID: String, apiKey: String)

    var capabilities: RealtimeASRCapabilities {
        switch self {
        case .xunfeiIAT:
            .init(preferredFrameBytes: 1280, requiresRealtimePacing: true, maximumSessionSeconds: 55,
                  allowsPreconnection: false, maximumSilenceSeconds: 6)
        case .volcengineTraditional(_, _, _, let mode):
            // Conservative client windows, not a documented server duration limit. Begin the
            // connection when PCM is ready to avoid waiting for audio after the full request.
            .init(preferredFrameBytes: 3200, requiresRealtimePacing: true,
                  maximumSessionSeconds: mode == .sentence ? 55 : 90, allowsPreconnection: false)
        case .tencent, .xunfei:
            .init(preferredFrameBytes: 1280, requiresRealtimePacing: true, maximumSessionSeconds: 90)
        default:
            .init(preferredFrameBytes: 3200, requiresRealtimePacing: false, maximumSessionSeconds: 90)
        }
    }
}

enum RealtimeWebSocketMessage: Sendable, Equatable {
    case text(String), binary(Data), closed(normal: Bool)
}

protocol RealtimeWebSocketTransport: Sendable {
    func connect(_ request: URLRequest) async throws
    func send(_ message: RealtimeWebSocketMessage) async throws
    func receive() async throws -> RealtimeWebSocketMessage
    func close() async
}

actor URLSessionRealtimeWebSocketTransport: RealtimeWebSocketTransport {
    private var task: URLSessionWebSocketTask?
    private let delegate = RealtimeNoRedirectDelegate()
    private var session: URLSession?
    func connect(_ request: URLRequest) async throws {
        guard task == nil else { throw RealtimeASRError.invalidState }
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        self.session = session
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 1_048_576
        self.task = task
        task.resume()
    }
    func send(_ message: RealtimeWebSocketMessage) async throws {
        guard let task else { throw RealtimeASRError.connectionClosed }
        switch message {
        case .text(let value): try await task.send(.string(value))
        case .binary(let data): try await task.send(.data(data))
        case .closed: throw RealtimeASRError.invalidState
        }
    }
    func receive() async throws -> RealtimeWebSocketMessage {
        guard let task else { throw RealtimeASRError.connectionClosed }
        do {
            switch try await task.receive() {
            case .data(let data): return .binary(data)
            case .string(let text): return .text(text)
            @unknown default: throw RealtimeASRError.invalidResponse
            }
        } catch {
            if task.closeCode == .normalClosure { return .closed(normal: true) }
            throw RealtimeASRError.connectionClosed
        }
    }
    func close() async {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }
}

final class RealtimeNoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
