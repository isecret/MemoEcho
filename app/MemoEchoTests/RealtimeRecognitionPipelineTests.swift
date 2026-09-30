import Foundation
import XCTest
@testable import MemoEcho

@MainActor
final class RealtimeRecognitionPipelineTests: XCTestCase {
    func testEmptyCaptureCallbacksDoNotOccupyInboxEntries() throws {
        let inbox = RealtimeAudioInbox()
        for _ in 0..<1000 { inbox.append(Data()) }
        let (chunk, ended) = try inbox.take()
        XCTAssertNil(chunk)
        XCTAssertFalse(ended)
        XCTAssertEqual(inbox.peakMilliseconds, 0)
        inbox.finish()
        XCTAssertTrue(try inbox.take().1)
    }

    func testSub500MillisecondsNeverCreatesOrConnectsSession() async throws {
        let factory = PipelineSessionFactory([])
        let pipeline = makePipeline(factory)
        pipeline.input.append(audio(bytes: 15_998))
        pipeline.input.finish()
        let texts = try await pipeline.run()
        XCTAssertEqual(texts, [])
        XCTAssertEqual(factory.creationCount, 0)
        let snapshot = await pipeline.snapshot()
        XCTAssertTrue(snapshot.audio.processedPCM.isEmpty)
        XCTAssertTrue(snapshot.audio.rawPCM.isEmpty)
    }

    func testExactly500MillisecondsSendsInitialAudioAndShortFinalFrame() async throws {
        let session = PipelineTestSession(text: "完整结果", frameBytes: 1280)
        let factory = PipelineSessionFactory([session])
        let pipeline = makePipeline(factory)
        let input = audio(bytes: 16_000)
        pipeline.input.append(input.prefix(798))
        pipeline.input.append(input.dropFirst(798))
        pipeline.input.finish()
        let texts = try await pipeline.run()
        let recorded = await session.snapshot()
        XCTAssertEqual(texts, ["完整结果"])
        XCTAssertEqual(recorded.frames.reduce(into: Data()) { $0.append($1) }, input)
        XCTAssertEqual(recorded.frames.last?.count, 640)
        XCTAssertEqual(recorded.connects, 1)
        XCTAssertEqual(recorded.finishes, 1)
    }

    func testNativeWindowRolloverPreservesSampleOrderAndShortLastWindow() async throws {
        let sessions = (0..<4).map { PipelineTestSession(text: "窗口\($0)", windowSeconds: 1) }
        let factory = PipelineSessionFactory(sessions)
        let pipeline = makePipeline(factory)
        let input = audio(bytes: 3 * 32_000 + 202)
        pipeline.input.append(input)
        pipeline.input.finish()
        let texts = try await pipeline.run()
        var sent = Data()
        var lengths: [Int] = []
        for session in sessions {
            let snapshot = await session.snapshot()
            let window = snapshot.frames.reduce(into: Data()) { $0.append($1) }
            sent.append(window)
            lengths.append(window.count)
            XCTAssertEqual(snapshot.connects, 1)
            XCTAssertEqual(snapshot.finishes, 1)
        }
        XCTAssertEqual(texts, ["窗口0", "窗口1", "窗口2", "窗口3"])
        XCTAssertEqual(sent, input)
        XCTAssertEqual(lengths, [32_000, 32_000, 32_000, 202])
        let recovery = await pipeline.snapshot()
        XCTAssertTrue(recovery.audio.processedPCM.isEmpty)
        XCTAssertTrue(recovery.audio.rawPCM.isEmpty)
    }

    func testFinishFailurePreservesCommittedTextProcessedWindowAndUnconsumedRawTail() async throws {
        let failedFinish = PipelineTestGate()
        let finished = PipelineTestSession(text: "已确认", windowSeconds: 1)
        let failed = PipelineTestSession(text: "不会提交", windowSeconds: 1,
                                         finishGate: failedFinish, finishError: .serviceRejected)
        let pipeline = makePipeline(PipelineSessionFactory([finished, failed, PipelineTestSession(text: "unused", windowSeconds: 1)]))
        let firstWindow = audio(bytes: 32_000)
        let failedWindow = audio(bytes: 32_000, seed: 11)
        let rawTail = audio(bytes: 3200, seed: 29)
        pipeline.input.append(firstWindow + failedWindow)
        let task = Task { try await pipeline.run() }
        await failed.finishEntered.wait()
        pipeline.input.append(rawTail)
        pipeline.input.finish()
        await failedFinish.open()
        do {
            _ = try await task.value
            XCTFail("The failed window cannot expose a successful prefix")
        } catch {
            XCTAssertEqual(error as? RealtimeASRError, .serviceRejected)
        }
        let recovery = await pipeline.snapshot()
        XCTAssertEqual(recovery.transcripts, ["已确认"])
        // During asynchronous finalization the next task may already process this tail.
        XCTAssertEqual(recovery.audio.processedPCM + recovery.audio.rawPCM, failedWindow + rawTail)
        XCTAssertTrue(recovery.audio.processedPCM.starts(with: failedWindow))
    }

    func testConnectFailureRetainsInitialAudioAndPendingRawChunks() async throws {
        let session = PipelineTestSession(text: "", connectError: .authentication)
        let pipeline = makePipeline(PipelineSessionFactory([session]))
        let initial = audio(bytes: 16_000)
        let tail = audio(bytes: 4000)
        pipeline.input.append(initial)
        pipeline.input.append(tail)
        pipeline.input.finish()
        do {
            _ = try await pipeline.run()
            XCTFail("Expected authentication failure")
        } catch { XCTAssertEqual(error as? RealtimeASRError, .authentication) }
        let snapshot = await pipeline.snapshot()
        XCTAssertEqual(snapshot.audio.processedPCM, initial)
        XCTAssertEqual(snapshot.audio.rawPCM, tail)
        XCTAssertEqual(snapshot.transcripts, [])
    }

    func testCancelUnblocksSendAndDiscardsAudioAndText() async throws {
        let sendGate = PipelineTestGate()
        let session = PipelineTestSession(text: "迟到结果", sendGate: sendGate)
        let pipeline = makePipeline(PipelineSessionFactory([session]))
        pipeline.input.append(audio(bytes: 16_000))
        let task = Task { try await pipeline.run() }
        await session.sendEntered.wait()
        await pipeline.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled audio must not complete")
        } catch { }
        pipeline.input.append(audio(bytes: 100))
        let snapshot = await pipeline.snapshot()
        XCTAssertEqual(snapshot.transcripts, [])
        XCTAssertTrue(snapshot.audio.processedPCM.isEmpty)
        XCTAssertTrue(snapshot.audio.rawPCM.isEmpty)
        let recorded = await session.snapshot()
        XCTAssertGreaterThanOrEqual(recorded.cancels, 1)
        XCTAssertEqual(recorded.finishes, 0)
    }

    func testTaskCancellationUnblocksInputWait() async throws {
        let factory = PipelineSessionFactory([])
        let pipeline = makePipeline(factory)
        let task = Task { try await pipeline.run() }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancelled input wait")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(factory.creationCount, 0)
    }

    func testSlowSenderOverflowFailsAndKeepsAcceptedAudio() async throws {
        let sendGate = PipelineTestGate()
        let session = PipelineTestSession(text: "", sendGate: sendGate)
        let pipeline = makePipeline(PipelineSessionFactory([session]))
        let initial = audio(bytes: 16_000)
        let queued = audio(bytes: 480_000, seed: 41)
        pipeline.input.append(initial)
        let task = Task { try await pipeline.run() }
        await session.sendEntered.wait()
        pipeline.input.append(queued)
        pipeline.input.append(Data([1, 0]))
        await sendGate.open()
        do {
            _ = try await task.value
            XCTFail("Overflow cannot silently discard audio and succeed")
        } catch {
            guard case RealtimePipelineError.backpressure = error else {
                return XCTFail("Unexpected overflow error: \(type(of: error))")
            }
        }
        let recovery = await pipeline.snapshot()
        XCTAssertEqual(recovery.audio.processedPCM, initial)
        XCTAssertEqual(recovery.audio.rawPCM, queued)
        XCTAssertEqual(pipeline.input.peakMilliseconds, 15_000)
    }

    func testPartialAndStableEventsDoNotBecomeCommittedBeforeTaskFinal() async throws {
        let finishGate = PipelineTestGate()
        let session = PipelineTestSession(text: "最终修正", finishGate: finishGate)
        let pipeline = makePipeline(PipelineSessionFactory([session]))
        pipeline.input.append(audio(bytes: 16_000))
        pipeline.input.finish()
        let task = Task { try await pipeline.run() }
        await session.finishEntered.wait()
        session.emit(.partial(text: "中间文字"))
        session.emit(.stableSentence(id: "1", text: "句子结束", endSample: 8_000))
        let pending = await pipeline.snapshot()
        XCTAssertEqual(pending.transcripts, [])
        XCTAssertEqual(pending.audio.processedPCM.count, 16_000)
        await finishGate.open()
        let texts = try await task.value
        XCTAssertEqual(texts, ["最终修正"])
    }

    func testTranscriptLimitCountsFinalTextAcrossWindows() async throws {
        let sessions = [PipelineTestSession(text: String(repeating: "甲", count: 4000), windowSeconds: 1),
                        PipelineTestSession(text: String(repeating: "乙", count: 4001), windowSeconds: 1)]
        let pipeline = makePipeline(PipelineSessionFactory(sessions))
        pipeline.input.append(audio(bytes: 64_000))
        pipeline.input.finish()
        do {
            _ = try await pipeline.run()
            XCTFail("8001 final characters must fail before output")
        } catch {
            XCTAssertEqual(error as? MemoEchoError, .transcriptTooLong(charCount: 8001))
        }
    }

    func testExactly8000CharactersAreAccepted() async throws {
        let expected = String(repeating: "字", count: 8000)
        let pipeline = makePipeline(PipelineSessionFactory([PipelineTestSession(text: expected)]))
        pipeline.input.append(audio(bytes: 16_000))
        pipeline.input.finish()
        let texts = try await pipeline.run()
        XCTAssertEqual(texts, [expected])
    }

    func testSub500MillisecondsDoesNotInitializeDSP() async throws {
        let factory = PipelineSessionFactory([])
        let processors = PipelineProcessorFactory()
        let pipeline = RealtimeRecognitionPipeline(sessionID: "short-dsp-test", makePreprocessor: {
            processors.makeProcessor()
        }, makeSession: { try factory.makeSession() })
        pipeline.input.append(audio(bytes: 15_998))
        pipeline.input.finish()
        let texts = try await pipeline.run()
        XCTAssertEqual(texts, [])
        XCTAssertEqual(processors.creationCount, 0)
        XCTAssertEqual(factory.creationCount, 0)
    }

    func testConnectionFailureFlushesDelayedDSPTailIntoProcessedRecoveryExactlyOnce() async throws {
        let factory = PipelineSessionFactory([PipelineTestSession(text: "", connectError: .authentication)])
        let processors = PipelineProcessorFactory()
        let pipeline = RealtimeRecognitionPipeline(sessionID: "failed-dsp-test", makePreprocessor: {
            processors.makeProcessor()
        }, makeSession: { try factory.makeSession() })
        let input = Data(Array(repeating: [UInt8(1), 0], count: 8000).joined())
        let rawTail = Data([3, 0, 4, 0])
        pipeline.input.append(input)
        pipeline.input.append(rawTail)
        pipeline.input.finish()
        do {
            _ = try await pipeline.run()
            XCTFail("Expected connection failure")
        } catch { XCTAssertEqual(error as? RealtimeASRError, .authentication) }
        let recovery = await pipeline.snapshot()
        XCTAssertEqual(recovery.audio.processedPCM, Data(Array(repeating: [UInt8(2), 0], count: 8000).joined()))
        XCTAssertEqual(recovery.audio.rawPCM, rawTail)
        XCTAssertEqual(processors.creationCount, 1)
    }

    func testCancellationDoesNotResurrectDelayedDSPTail() async throws {
        let sendGate = PipelineTestGate()
        let session = PipelineTestSession(text: "迟到结果", sendGate: sendGate)
        let factory = PipelineSessionFactory([session])
        let processors = PipelineProcessorFactory()
        let pipeline = RealtimeRecognitionPipeline(sessionID: "cancelled-dsp-test", makePreprocessor: {
            processors.makeProcessor()
        }, makeSession: { try factory.makeSession() })
        pipeline.input.append(audio(bytes: 16_000))
        let task = Task { try await pipeline.run() }
        await session.sendEntered.wait()
        await pipeline.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch { }
        let recovery = await pipeline.snapshot()
        XCTAssertTrue(recovery.audio.processedPCM.isEmpty)
        XCTAssertTrue(recovery.audio.rawPCM.isEmpty)
        XCTAssertEqual(recovery.transcripts, [])
        XCTAssertEqual(processors.creationCount, 1)
    }

    func testRecoveryCanReplayShortValidTailWithoutRepeatingMisTouchThreshold() async throws {
        let session = PipelineTestSession(text: "有效尾音")
        let factory = PipelineSessionFactory([session])
        let pipeline = RealtimeRecognitionPipeline(sessionID: "short-replay-test", preprocess: false,
                                                   minimumStartBytes: 0) {
            try factory.makeSession()
        }
        let input = audio(bytes: 202)
        pipeline.input.append(input)
        pipeline.input.finish()
        let texts = try await pipeline.run()
        let snapshot = await session.snapshot()
        XCTAssertEqual(texts, ["有效尾音"])
        XCTAssertEqual(snapshot.frames, [input])
        XCTAssertEqual(snapshot.connects, 1)
        XCTAssertEqual(snapshot.finishes, 1)
    }

    func testNoiseOnlyConfirmedWindowDoesNotFailEarlierSpeech() async throws {
        let sessions = [PipelineTestSession(text: "已确认语音", windowSeconds: 1),
                        PipelineTestSession(text: "", windowSeconds: 1)]
        let pipeline = makePipeline(PipelineSessionFactory(sessions))
        pipeline.input.append(Data(repeating: 1, count: 64_000))
        pipeline.input.finish()
        let texts = try await pipeline.run()
        XCTAssertEqual(texts, ["已确认语音"])
        let recovery = await pipeline.snapshot()
        XCTAssertTrue(recovery.audio.processedPCM.isEmpty)
    }

    func testEarlierFinalFailureWakesIdleConsumerAndRetainsBothTasksInOrder() async throws {
        let gate = PipelineTestGate()
        let previous = PipelineTestSession(text: "", windowSeconds: 1, finishGate: gate, finishError: .serviceRejected)
        let current = PipelineTestSession(text: "不能提交后窗", windowSeconds: 1)
        let pipeline = makePipeline(PipelineSessionFactory([previous, current]))
        let first = audio(bytes: 32_000, seed: 4)
        let second = audio(bytes: 16_000, seed: 8)
        pipeline.input.append(first + second)
        let task = Task { try await pipeline.run() }
        await previous.finishEntered.wait()
        await current.sendEntered.wait()
        try await Task.sleep(for: .milliseconds(20))
        await gate.open()
        do { _ = try await task.value; XCTFail("Earlier final failure must fail whole recording") }
        catch { XCTAssertEqual(error as? RealtimeASRError, .serviceRejected) }
        let recovery = await pipeline.snapshot()
        XCTAssertEqual(recovery.audio.processedPCM, first + second)
        XCTAssertEqual(recovery.transcripts, [])
        let state = await current.snapshot()
        XCTAssertGreaterThanOrEqual(state.cancels, 1)
    }

    func testCancelWhilePreviousTaskFinishesClearsBothTaskAudio() async throws {
        let gate = PipelineTestGate()
        let previous = PipelineTestSession(text: "迟到前窗", windowSeconds: 1, finishGate: gate)
        let current = PipelineTestSession(text: "迟到后窗", windowSeconds: 1)
        let pipeline = makePipeline(PipelineSessionFactory([previous, current]))
        pipeline.input.append(audio(bytes: 48_000))
        let task = Task { try await pipeline.run() }
        await previous.finishEntered.wait()
        await current.sendEntered.wait()
        await pipeline.cancel()
        do { _ = try await task.value; XCTFail("Cancelled handoff must fail") } catch { }
        let recovery = await pipeline.snapshot()
        XCTAssertTrue(recovery.audio.processedPCM.isEmpty)
        XCTAssertEqual(recovery.transcripts, [])
    }

    func testVoicedWindowWithEmptyFinalFailsAndRetainsItsAudio() async throws {
        let pipeline = makePipeline(PipelineSessionFactory([PipelineTestSession(text: "", windowSeconds: 1)]))
        let input = Data(Array(repeating: [UInt8(0), 16], count: 16000).joined())
        pipeline.input.append(input)
        pipeline.input.finish()
        do { _ = try await pipeline.run(); XCTFail("Voiced audio with empty final must fail") }
        catch { XCTAssertEqual(error as? MemoEchoError, .asrEmptyTranscript) }
        let recovery = await pipeline.snapshot()
        XCTAssertEqual(recovery.audio.processedPCM, input)
        XCTAssertEqual(recovery.transcripts, [])
    }

    func testPacedHandoffDoesNotAccumulateFinalizationLatency() async throws {
        let tracker = PacedConnectionTracker()
        let sessions = (0..<7).map { PacedPipelineSession(index: $0, tracker: tracker) }
        let factory = PacedPipelineFactory(sessions)
        let pipeline = RealtimeRecognitionPipeline(sessionID: "paced-handoff", preprocess: false,
                                                   minimumStartBytes: 0) { try factory.makeSession() }
        let producer = Task {
            // Produce at the same 1:1 rate required by Tencent/RTASR.
            for _ in 0..<60 {
                pipeline.input.append(Data(repeating: 1, count: 1280))
                try await Task.sleep(for: .milliseconds(40))
            }
            pipeline.input.finish()
        }
        let text = try await pipeline.run()
        try await producer.value
        XCTAssertEqual(text, (0..<6).map { "窗口\($0)" })
        let snapshot = await tracker.snapshot()
        XCTAssertLessThanOrEqual(snapshot.peak, 2)
        XCTAssertEqual(snapshot.active, 0)
        var starts: [ContinuousClock.Instant] = []
        for session in sessions.prefix(6) {
            let frames = await session.frames
            XCTAssertEqual(frames.count, 10)
            starts.append(try XCTUnwrap(frames.first))
        }
        // Six 400ms windows: serial finish(120ms)+connect(30ms) would add 750ms.
        let elapsed = starts[0].duration(to: starts[5])
        XCTAssertLessThan(elapsed, .milliseconds(2350))
    }

    func testPacedHandoffNeverBurstsNewTaskAtItsPreconnectionTime() async throws {
        let tracker = PacedConnectionTracker()
        let sessions = (0..<4).map { PacedPipelineSession(index: $0, tracker: tracker) }
        let factory = PacedPipelineFactory(sessions)
        let pipeline = RealtimeRecognitionPipeline(sessionID: "paced-timeline", preprocess: false,
                                                   minimumStartBytes: 0) { try factory.makeSession() }
        let producer = Task {
            for _ in 0..<30 {
                pipeline.input.append(Data(repeating: 2, count: 1280))
                try await Task.sleep(for: .milliseconds(40))
            }
            pipeline.input.finish()
        }
        _ = try await pipeline.run()
        try await producer.value
        for session in sessions {
            let frames = await session.frames
            for pair in zip(frames, frames.dropFirst()) {
                XCTAssertGreaterThanOrEqual(pair.0.duration(to: pair.1), .milliseconds(25))
            }
        }
        let first = await sessions[0].frames
        let second = await sessions[1].frames
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(first.first).duration(to: XCTUnwrap(second.first)), .milliseconds(390))
        let peak = await tracker.snapshot().peak
        XCTAssertLessThanOrEqual(peak, 2)
    }

    func testIATStyleLongSilenceRotatesWithoutDroppingPCM() async throws {
        let sessions = (0..<4).map { _ in PipelineTestSession(text: "", frameBytes: 1280,
            windowSeconds: 55, silenceSeconds: 0.12, allowsPreconnection: false) }
        let factory = PipelineSessionFactory(sessions)
        let pipeline = RealtimeRecognitionPipeline(sessionID: "iat-silence-test", preprocess: false,
                                                   minimumStartBytes: 0) { try factory.makeSession() }
        let source = Data(repeating: 0, count: 1280 * 7)
        pipeline.input.append(source)
        pipeline.input.finish()
        let result = try await pipeline.run()
        XCTAssertTrue(result.isEmpty)
        var uploaded = Data()
        var counts: [Int] = []
        for session in sessions {
            let snapshot = await session.snapshot()
            counts.append(snapshot.frames.count)
            snapshot.frames.forEach { uploaded.append($0) }
        }
        XCTAssertEqual(uploaded, source)
        XCTAssertEqual(counts, [3, 3, 1, 0])
    }

    func testIATStyleFiftyFiveSecondWindowsKeepLongRecordingContinuous() async throws {
        let sessions = (0..<3).map { PipelineTestSession(text: "窗口\($0)", frameBytes: 1280,
            windowSeconds: 55, allowsPreconnection: false) }
        let pipeline = makePipeline(PipelineSessionFactory(sessions))
        let source = audio(bytes: 61 * 32_000)
        let producer = Task {
            for offset in stride(from: 0, to: source.count, by: 3200) {
                pipeline.input.append(source.subdata(in: offset..<min(offset + 3200, source.count)))
                try await Task.sleep(for: .milliseconds(1))
            }
            pipeline.input.finish()
        }
        let result = try await pipeline.run()
        try await producer.value
        XCTAssertEqual(result, ["窗口0", "窗口1"])
        var uploaded = Data()
        for session in sessions {
            let snapshot = await session.snapshot()
            snapshot.frames.forEach { uploaded.append($0) }
        }
        XCTAssertEqual(uploaded, source)
        let first = await sessions[0].snapshot()
        XCTAssertEqual(first.frames.reduce(0) { $0 + $1.count }, 55 * 32_000)
    }

    private func makePipeline(_ factory: PipelineSessionFactory) -> RealtimeRecognitionPipeline {
        RealtimeRecognitionPipeline(sessionID: "synthetic-pipeline-test", preprocess: false) {
            try factory.makeSession()
        }
    }

    private func audio(bytes: Int, seed: Int = 7) -> Data {
        Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 * 31 + seed) })
    }
}

private actor PipelineTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor PipelineTestSession: RealtimeASRSession {
    nonisolated let capabilities: RealtimeASRCapabilities
    nonisolated let events: AsyncThrowingStream<RealtimeASREvent, Error>
    private nonisolated let eventContinuation: AsyncThrowingStream<RealtimeASREvent, Error>.Continuation
    nonisolated let sendEntered = PipelineTestGate()
    nonisolated let finishEntered = PipelineTestGate()
    private let text: String
    private let sendGate: PipelineTestGate?
    private let finishGate: PipelineTestGate?
    private let connectError: RealtimeASRError?
    private let finishError: RealtimeASRError?
    private var frames: [Data] = []
    private var connects = 0
    private var finishes = 0
    private var cancels = 0
    private var cancelled = false

    init(text: String, frameBytes: Int = 3200, windowSeconds: TimeInterval = 90,
         sendGate: PipelineTestGate? = nil, finishGate: PipelineTestGate? = nil,
         connectError: RealtimeASRError? = nil, finishError: RealtimeASRError? = nil,
         silenceSeconds: TimeInterval? = nil, allowsPreconnection: Bool = true) {
        self.text = text
        self.sendGate = sendGate
        self.finishGate = finishGate
        self.connectError = connectError
        self.finishError = finishError
        capabilities = .init(preferredFrameBytes: frameBytes, requiresRealtimePacing: false,
                             maximumSessionSeconds: windowSeconds, allowsPreconnection: allowsPreconnection,
                             maximumSilenceSeconds: silenceSeconds)
        (events, eventContinuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingNewest(2))
    }

    func connect() async throws {
        connects += 1
        if let connectError { throw connectError }
    }
    func send(_ pcm: Data) async throws {
        await sendEntered.open()
        await sendGate?.wait()
        guard !cancelled else { throw CancellationError() }
        frames.append(pcm)
    }
    func finish() async throws -> String {
        finishes += 1
        await finishEntered.open()
        await finishGate?.wait()
        guard !cancelled else { throw CancellationError() }
        if let finishError { throw finishError }
        return text
    }
    func cancel() async {
        cancels += 1
        cancelled = true
        await sendGate?.open()
        await finishGate?.open()
        eventContinuation.finish()
    }
    nonisolated func emit(_ event: RealtimeASREvent) { eventContinuation.yield(event) }
    func snapshot() -> (frames: [Data], connects: Int, finishes: Int, cancels: Int) {
        (frames, connects, finishes, cancels)
    }
}

private final class PipelineSessionFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let sessions: [PipelineTestSession]
    private var index = 0
    init(_ sessions: [PipelineTestSession]) { self.sessions = sessions }
    var creationCount: Int { lock.withLock { index } }
    func makeSession() throws -> any RealtimeASRSession {
        try lock.withLock {
            guard index < sessions.count else { throw RealtimeASRError.invalidState }
            defer { index += 1 }
            return sessions[index]
        }
    }
}

private final class PipelineProcessorFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var creations = 0
    var creationCount: Int { lock.withLock { creations } }
    func makeProcessor() -> StreamingAudioPreprocessor {
        lock.withLock { creations += 1 }
        var frames = [[Float]](repeating: [Float](repeating: 0, count: 480), count: 2)
        return StreamingAudioPreprocessor(delaySamples48k: 960, frameProcessor: { frame in
            frames.append(frame.map { $0 * 2 })
            return frames.removeFirst()
        })
    }
}

private actor PacedConnectionTracker {
    private var active = 0
    private var peak = 0
    func opened() { active += 1; peak = max(peak, active) }
    func closed() { active -= 1 }
    func snapshot() -> (active: Int, peak: Int) { (active, peak) }
}

private actor PacedPipelineSession: RealtimeASRSession {
    nonisolated let capabilities = RealtimeASRCapabilities(preferredFrameBytes: 1280, requiresRealtimePacing: true,
                                                          maximumSessionSeconds: 0.4)
    nonisolated let events = AsyncThrowingStream<RealtimeASREvent, Error> { $0.finish() }
    let index: Int
    let tracker: PacedConnectionTracker
    private var opened = false
    private(set) var frames: [ContinuousClock.Instant] = []
    init(index: Int, tracker: PacedConnectionTracker) { self.index = index; self.tracker = tracker }
    func connect() async throws {
        opened = true
        await tracker.opened()
        try await Task.sleep(for: .milliseconds(30))
    }
    func send(_ pcm: Data) async throws { try Task.checkCancellation(); frames.append(.now) }
    func finish() async throws -> String {
        try await Task.sleep(for: .milliseconds(120))
        return "窗口\(index)"
    }
    func cancel() async {
        if opened { opened = false; await tracker.closed() }
    }
}

private final class PacedPipelineFactory: @unchecked Sendable {
    let sessions: [PacedPipelineSession]
    private let lock = NSLock()
    private var index = 0
    init(_ sessions: [PacedPipelineSession]) { self.sessions = sessions }
    func makeSession() throws -> any RealtimeASRSession {
        try lock.withLock {
            guard index < sessions.count else { throw RealtimeASRError.invalidState }
            defer { index += 1 }
            return sessions[index]
        }
    }
}
