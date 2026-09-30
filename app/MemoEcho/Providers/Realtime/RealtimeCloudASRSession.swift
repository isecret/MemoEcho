import Foundation

/// One native task with a continuously running receiver. The pipeline owns audio buffering/pacing.
actor RealtimeCloudASRSession: RealtimeASRSession {
    nonisolated let events: AsyncThrowingStream<RealtimeASREvent, Error>
    nonisolated let capabilities: RealtimeASRCapabilities
    private let continuation: AsyncThrowingStream<RealtimeASREvent, Error>.Continuation
    private let configuration: RealtimeCloudASRConfiguration
    private let transport: any RealtimeWebSocketTransport
    private let connectTimeout: TimeInterval
    private let sendTimeout: TimeInterval
    private let finalTimeout: TimeInterval
    private let requestBuilder: @Sendable (RealtimeCloudASRConfiguration) async throws -> URLRequest
    private var codec: RealtimeWireCodec
    private var receiver: Task<Void, Never>?
    private var state = State.idle
    private var failure: RealtimeASRError?
    private var sentences: [String: String] = [:]
    private var sentenceOrder: [String] = []
    private var sentSamples: Int64 = 0
    private enum State { case idle, connecting, ready, finishing, finished, cancelled, failed }

    init(configuration: RealtimeCloudASRConfiguration,
         transport: any RealtimeWebSocketTransport = URLSessionRealtimeWebSocketTransport(),
         connectTimeout: TimeInterval = 8, sendTimeout: TimeInterval = 5, finalTimeout: TimeInterval = 15,
         requestBuilder: @escaping @Sendable (RealtimeCloudASRConfiguration) async throws -> URLRequest = {
             try await RealtimeWireCodec.makeRequest(configuration: $0)
         }) {
        self.configuration = configuration
        self.transport = transport
        self.capabilities = configuration.capabilities
        self.codec = RealtimeWireCodec(configuration: configuration)
        self.connectTimeout = connectTimeout
        self.sendTimeout = sendTimeout
        self.finalTimeout = finalTimeout
        self.requestBuilder = requestBuilder
        let stream = AsyncThrowingStream<RealtimeASREvent, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        events = stream.stream
        continuation = stream.continuation
    }

    func connect() async throws {
        guard state == .idle else { throw RealtimeASRError.invalidState }
        state = .connecting
        let deadline = ContinuousClock.now + .seconds(connectTimeout)
        do {
            let request = try await bounded(seconds: remaining(until: deadline)) { [configuration, requestBuilder] in
                try await requestBuilder(configuration)
            }
            try checkFailure()
            try await bounded(seconds: remaining(until: deadline)) { [transport] in try await transport.connect(request) }
            try checkFailure()
            if let start = try codec.startMessage() {
                try await bounded(seconds: min(sendTimeout, remaining(until: deadline))) { [transport] in try await transport.send(start) }
            }
            try checkFailure()
            // IAT returns recognition only after its first audio frame, with no started event.
            if codec.readyAfterTransportConnect { state = .ready }
            receiver = Task { await self.receiveLoop() }
            try await waitUntil(seconds: remaining(until: deadline)) { self.state != .connecting }
            try checkFailure()
            guard state == .ready else { throw RealtimeASRError.invalidState }
        } catch {
            await fail(sanitized(error))
            throw sanitized(error)
        }
    }

    func send(_ pcm: Data) async throws {
        try checkFailure()
        guard state == .ready, pcm.count % 2 == 0 else { throw RealtimeASRError.invalidState }
        guard !pcm.isEmpty else { return }
        guard sentSamples + Int64(pcm.count / 2) <= Int64(capabilities.maximumSessionSeconds * 16_000) else {
            await fail(.sessionLimit)
            throw RealtimeASRError.sessionLimit
        }
        do {
            let message = try codec.audioMessage(pcm)
            try await bounded(seconds: sendTimeout) { [transport] in try await transport.send(message) }
            try checkFailure()
            sentSamples += Int64(pcm.count / 2)
        } catch {
            await fail(sanitized(error))
            throw sanitized(error)
        }
    }

    func finish() async throws -> String {
        try checkFailure()
        guard state == .ready else { throw RealtimeASRError.invalidState }
        state = .finishing
        do {
            let message = try codec.finishMessage()
            try await bounded(seconds: sendTimeout) { [transport] in try await transport.send(message) }
            try await waitUntil(seconds: finalTimeout) { self.state != .finishing }
            try checkFailure()
            guard state == .finished else { throw RealtimeASRError.connectionClosed }
            await transport.close()
            return sentenceOrder.compactMap { sentences[$0] }.joined()
        } catch {
            await fail(sanitized(error))
            throw sanitized(error)
        }
    }

    func cancel() async {
        guard state != .cancelled else { return }
        state = .cancelled
        failure = .cancelled
        receiver?.cancel()
        continuation.finish(throwing: RealtimeASRError.cancelled)
        await transport.close()
    }

    private func receiveLoop() async {
        do {
            while !Task.isCancelled {
                let message = try await transport.receive()
                guard state != .cancelled, state != .failed, state != .finished else { return }
                if case .closed(let normal) = message {
                    // RTASR's documented terminal signal is a normal close after end=true.
                    guard codec.completesOnNormalClose, normal, state == .finishing else {
                        throw RealtimeASRError.connectionClosed
                    }
                    state = .finished
                    continuation.finish()
                    return
                }
                for event in try codec.consume(message) {
                    switch event {
                    case .ready:
                        if state == .connecting { state = .ready }
                    case .completed:
                        guard state == .finishing else { throw RealtimeASRError.connectionClosed }
                        state = .finished
                        continuation.finish()
                        return
                    case .transcript(let event):
                        switch event {
                        case .stableSentence(let id, let text, _):
                            if let existing = sentences[id] {
                                guard existing == text else { throw RealtimeASRError.invalidResponse }
                                continue
                            }
                            guard sentenceOrder.count < 8_000,
                                  sentences.values.reduce(0, { $0 + $1.count }) + text.count <= 8_000 else {
                                throw RealtimeASRError.textLimit
                            }
                            sentences[id] = text
                            sentenceOrder.append(id)
                        case .partial: break // Diagnostic consumers may timestamp this; no text is retained here.
                        }
                        continuation.yield(event)
                    }
                }
            }
        } catch { await fail(sanitized(error)) }
    }

    private func checkFailure() throws {
        try Task.checkCancellation()
        if let failure { throw failure }
    }
    private func fail(_ error: RealtimeASRError) async {
        guard state != .cancelled, state != .finished, state != .failed else { return }
        state = .failed
        failure = error
        continuation.finish(throwing: error)
        receiver?.cancel()
        await transport.close()
    }
    private func sanitized(_ error: Error) -> RealtimeASRError {
        if error is CancellationError { return .cancelled }
        return error as? RealtimeASRError ?? .connectionClosed
    }
    private func remaining(until deadline: ContinuousClock.Instant) throws -> TimeInterval {
        let duration = ContinuousClock.now.duration(to: deadline)
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        guard seconds > 0 else { throw RealtimeASRError.timeout }
        return seconds
    }
    private func waitUntil(seconds: TimeInterval, predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !predicate() {
            try Task.checkCancellation()
            if ContinuousClock.now >= deadline { throw RealtimeASRError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func bounded<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask { try await operation() }
                group.addTask {
                    try await Task.sleep(for: .seconds(seconds))
                    throw RealtimeASRError.timeout
                }
                defer { group.cancelAll() }
                do { return try await group.next()! }
                catch {
                    // Unblock pending socket operations before the task group waits for cleanup.
                    await transport.close()
                    throw error
                }
            }
        } onCancel: { [transport] in
            Task { await transport.close() }
        }
    }
}
