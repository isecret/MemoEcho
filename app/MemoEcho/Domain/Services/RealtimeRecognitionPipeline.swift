import Foundation

/// The capture callback only copies into this byte-bounded mailbox. One consumer owns DSP and sends.
final class RealtimeAudioInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var bytes = 0
    private var ended = false
    private var overflow = false
    private var captureError: MemoEchoError?
    private var peak = 0
    private var stoppedAt: ContinuousClock.Instant?
    let byteLimit: Int
    let signals: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init(byteLimit: Int = 480_000) {
        self.byteLimit = byteLimit
        (signals, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        guard !ended else { lock.unlock(); return }
        // Never continue after overload; retain accepted audio for an explicit partial recovery.
        if bytes + data.count > byteLimit {
            overflow = true
            ended = true
        } else {
            chunks.append(data)
            bytes += data.count
            peak = max(peak, bytes)
        }
        lock.unlock()
        continuation.yield(())
    }

    func fail(_ error: MemoEchoError) {
        lock.withLock { captureError = error; ended = true }
        continuation.yield(())
    }

    func finish() {
        lock.withLock { ended = true; if stoppedAt == nil { stoppedAt = .now } }
        continuation.yield(())
    }

    func take() throws -> (Data?, Bool) {
        try lock.withLock {
            if let captureError { throw captureError }
            if overflow { throw RealtimePipelineError.backpressure }
            guard !chunks.isEmpty else { return (nil, ended) }
            let value = chunks.removeFirst()
            bytes -= value.count
            return (value, false)
        }
    }

    func recoveryTail() -> Data { lock.withLock { chunks.reduce(into: Data()) { $0.append($1) } } }
    func wake() { continuation.yield(()) }
    var isFinished: Bool { lock.withLock { ended } }
    var stopTime: ContinuousClock.Instant? { lock.withLock { stoppedAt } }
    var peakMilliseconds: Int { lock.withLock { peak / 32 } }
    func clear() { lock.withLock { chunks.removeAll(); bytes = 0; ended = true }; continuation.finish() }
}

enum RealtimePipelineError: Error {
    case backpressure, invalidPCM
}

struct RealtimeRecoveryAudio: Sendable {
    var processedPCM: Data
    var rawPCM: Data
}

/// Finite native tasks are checkpoints, not WAV/one-sentence recognition requests.
/// Audio stays continuous across task boundaries; only complete task results are committed.
actor RealtimeRecognitionPipeline {
    typealias SessionFactory = @Sendable () throws -> any RealtimeASRSession
    nonisolated let input = RealtimeAudioInbox()
    private let makeSession: SessionFactory
    private var session: (any RealtimeASRSession)?
    private var eventTask: Task<Void, Never>?
    private var preparedSession: (any RealtimeASRSession)?
    private var preparedConnect: Task<ContinuousClock.Instant, Error>?
    private var preparedEvents: Task<Void, Never>?
    private var preparedStarted: ContinuousClock.Instant?
    private var finishingSession: (any RealtimeASRSession)?
    private var finishingTask: Task<Void, Never>?
    private var finishingEvents: Task<Void, Never>?
    private var finishingPCM = Data()
    private var terminalFailure: Error?
    private var closing = false
    private var nextSendOrigin: ContinuousClock.Instant?
    private var firstAudioAt: ContinuousClock.Instant?
    private let createdAt = ContinuousClock.now
    private var committed: [String] = []
    private var windowPCM = Data()
    private var silentBytes = 0
    private var sentBytes = 0
    private var sendOrigin: ContinuousClock.Instant?
    private var windowLimit = 0
    private var frames = 0
    private var windows = 0
    private var terminated = false
    private let sessionID: String
    private let preprocess: Bool
    private let minimumStartBytes: Int
    private let makePreprocessor: (@Sendable () -> StreamingAudioPreprocessor)?

    init(sessionID: String, preprocess: Bool = true, minimumStartBytes: Int = 16_000,
         makePreprocessor: (@Sendable () -> StreamingAudioPreprocessor)? = nil, makeSession: @escaping SessionFactory) {
        self.sessionID = sessionID
        self.preprocess = preprocess
        self.minimumStartBytes = minimumStartBytes
        self.makePreprocessor = makePreprocessor
        self.makeSession = makeSession
    }

    func run() async throws -> [String] {
        try await withTaskCancellationHandler {
            try await consume()
        } onCancel: {
            self.input.finish()
            Task { await self.cancel() }
        }
    }

    private func consume() async throws -> [String] {
        var preprocessor: StreamingAudioPreprocessor?
        var initial = Data()
        var active = false
        do {
            for await _ in input.signals {
                while true {
                    try Task.checkCancellation()
                    try checkActive()
                    let (chunk, ended) = try input.take()
                    if let chunk {
                        if !active {
                            initial.append(chunk)
                            if initial.count < minimumStartBytes { continue }
                            if preprocess {
                                let id = sessionID
                                preprocessor = makePreprocessor?() ?? StreamingAudioPreprocessor(onFallback: { code in
                                    DiagnosticsLogger.shared.log(sessionID: id, event: "realtime_denoise_fallback", detail: code)
                                })
                            }
                            active = true
                            let data = try preprocessor?.process(initial) ?? initial
                            initial.removeAll()
                            try await accept(data)
                        } else {
                            try await accept(preprocessor?.process(chunk) ?? chunk)
                        }
                    } else if ended {
                        if active {
                            try await accept(preprocessor?.finish() ?? Data())
                            try await drain(final: true)
                            if session != nil { try await finalizeWindow() }
                            await finishingTask?.value
                            try checkActive()
                            await discardPreparedSession()
                        }
                        if let stopped = input.stopTime {
                            log("asr_wait_after_stop_ms=\(milliseconds(stopped.duration(to: .now)))")
                        }
                        input.clear()
                        return committed
                    } else { break }
                }
            }
            throw CancellationError()
        } catch {
            // Preserve delayed DSP output once; retry must not denoise this audio a second time.
            if !terminated && !Task.isCancelled {
                if active, let tail = try? preprocessor?.finish() { windowPCM.append(tail) }
                if !active { windowPCM.append(initial) }
            }
            await closeConnections()
            throw error
        }
    }

    private func accept(_ data: Data) async throws {
        guard data.count % 2 == 0 else { throw RealtimePipelineError.invalidPCM }
        windowPCM.append(data)
        guard windowPCM.count + finishingPCM.count <= 3_840_000 else { throw RealtimePipelineError.backpressure }
        try await drain(final: false)
    }

    private func checkActive() throws {
        try Task.checkCancellation()
        guard !terminated else { throw CancellationError() }
        if let terminalFailure { throw terminalFailure }
    }

    private func observe(_ candidate: any RealtimeASRSession, since start: ContinuousClock.Instant) -> Task<Void, Never> {
        Task { [weak self] in
            var seenPartial = false
            do {
                for try await event in candidate.events {
                    guard !Task.isCancelled else { return }
                    if case .partial = event, !seenPartial {
                        seenPartial = true
                        await self?.recordFirstPartial(since: start)
                    }
                }
            } catch { /* send/finish reports the same terminal failure. */ }
        }
    }

    private func startWindow() async throws {
        try checkActive()
        let candidate: any RealtimeASRSession
        let start: ContinuousClock.Instant
        let ready: ContinuousClock.Instant
        if let preparedSession, let preparedConnect {
            candidate = preparedSession
            start = preparedStarted ?? .now
            // Keep ownership until the await completes, so cancel can close this socket.
            ready = try await preparedConnect.value
            try checkActive()
            session = candidate
            eventTask = preparedEvents
            self.preparedSession = nil
            self.preparedConnect = nil
            preparedEvents = nil
            preparedStarted = nil
        } else {
            // At most the preceding finalizing task and this current task may exist.
            candidate = try makeSession()
            session = candidate
            start = .now
            eventTask = observe(candidate, since: start)
            try await candidate.connect()
            ready = .now
            try checkActive()
        }
        windowLimit = Int(candidate.capabilities.maximumSessionSeconds * 32_000) / 2 * 2
        guard windowLimit > 0 else { throw RealtimeASRError.configuration }
        windows += 1
        // A preconnected task inherits the sample timeline, not its earlier connection time.
        // A late connection moves the origin forward, never bursts audio faster than 1:1.
        sendOrigin = max(nextSendOrigin ?? .now, .now)
        nextSendOrigin = nil
        log("protocol_ready_ms=\(milliseconds(start.duration(to: ready))) window_count=\(windows)")
    }

    private func prepareNextWindowIfNeeded() throws {
        guard preparedSession == nil, finishingSession == nil, !input.isFinished,
              let current = session, current.capabilities.allowsPreconnection else { return }
        // Tencent disconnects after 6s without audio. Connecting 4s ahead leaves room
        // for handshake latency without creating an idle preconnection for 8 seconds.
        let leadSeconds = min(4.0, current.capabilities.maximumSessionSeconds / 4)
        guard windowLimit - sentBytes <= Int(leadSeconds * 32_000) else { return }
        let candidate = try makeSession()
        let start = ContinuousClock.now
        preparedSession = candidate
        preparedStarted = start
        preparedEvents = observe(candidate, since: start)
        preparedConnect = Task {
            try await candidate.connect()
            return ContinuousClock.now
        }
    }

    private func drain(final: Bool) async throws {
        while sentBytes < windowPCM.count {
            try checkActive()
            if session == nil { try await startWindow() }
            guard let session else { throw RealtimeASRError.invalidState }
            let size = min(session.capabilities.preferredFrameBytes, windowLimit - sentBytes)
            guard size > 0 else { throw RealtimeASRError.sessionLimit }
            let available = min(windowPCM.count - sentBytes, size)
            if available < size && !final { return }
            if session.capabilities.requiresRealtimePacing, let sendOrigin {
                let deadline = sendOrigin.advanced(by: .seconds(Double(sentBytes) / 32_000))
                if ContinuousClock.now < deadline { try await ContinuousClock().sleep(until: deadline) }
            }
            try checkActive()
            let frame = windowPCM.subdata(in: sentBytes..<(sentBytes + available))
            try await session.send(frame)
            try checkActive()
            if firstAudioAt == nil {
                firstAudioAt = .now
                log("first_audio_sent_ms=\(milliseconds(createdAt.duration(to: .now)))")
            }
            sentBytes += available
            frames += 1
            if let seconds = session.capabilities.maximumSilenceSeconds {
                // Conservative RMS floor: a quiet boundary rotates native tasks without dropping PCM.
                silentBytes = Self.isQuiet(frame) ? silentBytes + available : 0
                if silentBytes >= Int(seconds * 32_000) {
                    try await finalizeWindow()
                    continue
                }
            }
            if sentBytes == windowLimit { try await finalizeWindow() }
            else { try prepareNextWindowIfNeeded() }
        }
    }

    /// Transfer only this task's samples to the finalizer. The next task can send
    /// while the preceding task finishes, but its result cannot overtake that task.
    private func finalizeWindow() async throws {
        guard let current = session else { return }
        await finishingTask?.value
        try checkActive()
        let samples = sentBytes
        let start = ContinuousClock.now
        if let stopped = input.stopTime {
            log("drain_after_stop_ms=\(milliseconds(stopped.duration(to: .now)))")
        }
        finishingPCM = Data(windowPCM.prefix(samples))
        windowPCM = Data(windowPCM.dropFirst(samples))
        sentBytes = 0
        silentBytes = 0
        finishingSession = current
        finishingEvents = eventTask
        eventTask = nil
        session = nil
        nextSendOrigin = sendOrigin?.advanced(by: .seconds(Double(samples) / 32_000))
        finishingTask = Task { [weak self] in
            let result: Result<String, Error>
            do { result = .success(try await current.finish().trimmingCharacters(in: .whitespacesAndNewlines)) }
            catch { result = .failure(error) }
            await current.cancel()
            await self?.didFinalize(result, since: start)
        }
    }

    private func didFinalize(_ result: Result<String, Error>, since start: ContinuousClock.Instant) {
        guard !closing, !terminated else { return }
        finishingEvents?.cancel()
        finishingEvents = nil
        finishingSession = nil
        switch result {
        case .success(let text):
            if text.isEmpty && Self.containsVoicedAudio(finishingPCM) {
                terminalFailure = MemoEchoError.asrEmptyTranscript
                input.wake()
                return
            }
            let count = committed.reduce(text.count) { $0 + $1.count }
            if count > 8000 { terminalFailure = MemoEchoError.transcriptTooLong(charCount: count) }
            else {
                // Only an acoustically quiet, successfully confirmed empty task is skipped.
                // The checkpoint still rejects an empty transcript for the whole recording.
                if !text.isEmpty { committed.append(text) }
                finishingPCM.removeAll()
            }
        case .failure(let error): terminalFailure = error
        }
        log("final_after_end_ms=\(milliseconds(start.duration(to: .now))) queued_audio_ms_peak=\(input.peakMilliseconds) window_count=\(windows) frame_count=\(frames)")
        input.wake()
    }

    private static func isQuiet(_ pcm: Data) -> Bool {
        guard !pcm.isEmpty else { return true }
        let bytes = [UInt8](pcm)
        var sum = 0.0
        for index in stride(from: 0, to: bytes.count, by: 2) {
            let sample = Double(Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8))
            sum += sample * sample
        }
        return sqrt(sum / Double(bytes.count / 2)) < 200
    }

    /// Same 20ms / adaptive noise-floor / 12dB / 4-frame rule as AudioSegmenter.
    /// This is a conservative energy gate, not a linguistic VAD; quiet speech and
    /// noisy microphones must be covered by manual acceptance with the chosen service.
    private static func containsVoicedAudio(_ pcm: Data) -> Bool {
        var noiseFloor: Double = 200
        var consecutive = 0
        let bytes = [UInt8](pcm)
        for offset in stride(from: 0, to: bytes.count, by: 640) {
            let end = min(offset + 640, bytes.count)
            guard end - offset >= 2 else { continue }
            var sum = 0.0
            for index in stride(from: offset, to: end - 1, by: 2) {
                let sample = Double(Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8))
                sum += sample * sample
            }
            let rms = sqrt(sum / Double((end - offset) / 2))
            let threshold = noiseFloor * pow(10, 12.0 / 20)
            if rms < threshold {
                noiseFloor = max(10, noiseFloor * 0.97 + rms * 0.03)
                consecutive = 0
            } else {
                consecutive += 1
                if consecutive >= 4 { return true }
            }
        }
        return false
    }

    func snapshot() -> (transcripts: [String], audio: RealtimeRecoveryAudio) {
        (committed, .init(processedPCM: finishingPCM + windowPCM, rawPCM: input.recoveryTail()))
    }

    private func discardPreparedSession() async {
        preparedConnect?.cancel()
        preparedEvents?.cancel()
        let prepared = preparedSession
        preparedSession = nil
        preparedConnect = nil
        preparedEvents = nil
        preparedStarted = nil
        await prepared?.cancel()
    }

    private func closeConnections() async {
        closing = true
        eventTask?.cancel()
        finishingEvents?.cancel()
        finishingTask?.cancel()
        let current = session
        let finishing = finishingSession
        session = nil
        finishingSession = nil
        eventTask = nil
        finishingEvents = nil
        await discardPreparedSession()
        await current?.cancel()
        await finishing?.cancel()
    }

    func cancel() async {
        terminated = true
        input.clear()
        await closeConnections()
        windowPCM.removeAll()
        finishingPCM.removeAll()
        committed.removeAll()
    }

    private func recordFirstPartial(since start: ContinuousClock.Instant) {
        log("first_partial_ms=\(milliseconds(start.duration(to: .now)))")
    }

    private func milliseconds(_ duration: Duration) -> Int {
        let c = duration.components
        return Int(c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000)
    }
    private func log(_ detail: String) {
        DiagnosticsLogger.shared.log(sessionID: sessionID, event: "realtime_asr", detail: detail)
    }
}

extension RealtimeRecognitionPipeline {
    static func replay(_ audio: RealtimeRecoveryAudio, config: ASRConfig, hotwords: VolcengineHotwords = .empty) async throws -> [String] {
        let pipeline = RealtimeRecognitionPipeline(sessionID: UUID().uuidString, preprocess: false, minimumStartBytes: 0) {
            try ASRProviderFactory.makeRealtimeSession(for: config, hotwords: hotwords)
        }
        return try await withTaskCancellationHandler {
            let producer = Task {
                do {
                    var data = audio.processedPCM
                    if !audio.rawPCM.isEmpty {
                        let processor = StreamingAudioPreprocessor()
                        data.append(try processor.process(audio.rawPCM))
                        data.append(try processor.finish())
                    }
                    let start = ContinuousClock.now
                    for offset in stride(from: 0, to: data.count, by: 3200) {
                        try Task.checkCancellation()
                        let deadline = start.advanced(by: .seconds(Double(offset) / 32_000))
                        if ContinuousClock.now < deadline { try await ContinuousClock().sleep(until: deadline) }
                        pipeline.input.append(data.subdata(in: offset..<min(offset + 3200, data.count)))
                    }
                    pipeline.input.finish()
                } catch {
                    pipeline.input.finish()
                    throw error
                }
            }
            do {
                let result = try await pipeline.run()
                try await producer.value
                return result
            } catch {
                producer.cancel()
                await pipeline.cancel()
                throw error
            }
        } onCancel: { Task { await pipeline.cancel() } }
    }
}
