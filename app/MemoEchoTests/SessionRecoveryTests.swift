import AVFoundation
import XCTest
@testable import MemoEcho

@MainActor
final class SessionRecoveryTests: XCTestCase {
    private func checkpoint(segments: [SealedSegment] = [], mode: TextProcessingMode = .polish,
                            target: TextInjectionFocus? = nil) -> SessionRecoveryCheckpoint {
        .init(segments: segments, transcripts: ["已有转写"], mode: mode, language: .japanese,
              asrPlatform: .openAICompatibleASR, target: target, context: nil)
    }
    private func polished(_ text: String = "整理结果") -> PolishResult {
        .init(text: text, source: .llm,
              structured: .init(mode: .plainText, intro: nil, items: nil, outro: nil, correctionApplied: false))
    }
    private func segment(_ index: Int) -> SealedSegment {
        .init(index: index, pcmData: Data([0, 1]), sampleCount: 1, sealReason: .finalize, voicedDetected: true)
    }
    private func processor() -> SessionRecoveryProcessor {
        .init(recognize: { _ in XCTFail("ASR should be skipped"); return "" },
              polish: { [self] _, _ in polished() }, translate: { _, _, _ in "翻译结果" })
    }
    private func process(_ processor: SessionRecoveryProcessor, _ checkpoint: SessionRecoveryCheckpoint) async throws -> String {
        try await processor.process(checkpoint, shouldContinue: { true }, onStage: { _ in })
    }

    func testPolishRetryKeepsTranscriptAndSkipsRecognition() async throws {
        let cp = checkpoint()
        var worker = processor()
        var calls = 0
        worker.polish = { [self] text, _ in
            calls += 1
            XCTAssertEqual(text, ["已有转写"])
            if calls == 1 { throw MemoEchoError.llmNetworkFailure(message: "synthetic") }
            return polished()
        }
        do { _ = try await process(worker, cp); XCTFail("Expected failure") } catch {}
        XCTAssertEqual(cp.stage, .polish)
        let result = try await process(worker, cp)
        XCTAssertEqual(result, "整理结果")
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(cp.transcripts.isEmpty)
    }

    func testTranslationRetryDoesNotRepeatPolishAndKeepsOriginalLanguage() async throws {
        let cp = checkpoint(mode: .translate)
        var worker = processor()
        var polishCalls = 0
        var translateCalls = 0
        worker.polish = { [self] _, _ in polishCalls += 1; return polished() }
        worker.translate = { text, language, _ in
            XCTAssertEqual(text, "整理结果")
            XCTAssertEqual(language, .japanese)
            translateCalls += 1
            if translateCalls == 1 { throw MemoEchoError.llmEmptyResponse }
            return "翻译结果"
        }
        do { _ = try await process(worker, cp); XCTFail("Expected failure") } catch {}
        XCTAssertEqual(cp.stage, .translation)
        XCTAssertTrue(cp.transcripts.isEmpty)
        _ = try await process(worker, cp)
        XCTAssertEqual(polishCalls, 1)
        XCTAssertEqual(translateCalls, 2)
    }

    func testRecognitionRetryOnlyRepeatsFailedSegmentThenContinuesInOrder() async throws {
        let cp = checkpoint(segments: [segment(3), segment(1), segment(2)])
        var worker = processor()
        var calls: [Int] = []
        var fail = true
        worker.recognize = { segment in
            calls.append(segment.index)
            if segment.index == 2 && fail { fail = false; throw MemoEchoError.cloudASREmptyResponse }
            return "段\(segment.index)"
        }
        worker.polish = { [self] text, _ in
            XCTAssertEqual(text, ["已有转写", "段1", "段2", "段3"])
            return polished()
        }
        do { _ = try await process(worker, cp); XCTFail("Expected failure") } catch {}
        XCTAssertEqual(cp.pendingSegments.map(\.index), [2, 3])
        XCTAssertEqual(cp.transcripts, ["已有转写", "段1"])
        _ = try await process(worker, cp)
        XCTAssertEqual(calls, [1, 2, 2, 3])
        XCTAssertTrue(cp.pendingSegments.isEmpty)
    }

    func testEmptyRecognitionKeepsAudioAndDoesNotPolishPartialText() async {
        let cp = checkpoint(segments: [segment(1)])
        var worker = processor()
        worker.recognize = { _ in "  " }
        worker.polish = { [self] _, _ in XCTFail("Must not polish partial text"); return polished() }
        do { _ = try await process(worker, cp); XCTFail("Expected failure") }
        catch { XCTAssertEqual(error as? MemoEchoError, .asrEmptyTranscript) }
        XCTAssertEqual(cp.pendingSegments.count, 1)
    }

    func testTooLongTranscriptNeverEntersLLM() async {
        let cp = checkpoint()
        cp.transcripts = [String(repeating: "字", count: 8001)]
        var worker = processor()
        worker.polish = { [self] _, _ in XCTFail("Must enforce limit"); return polished() }
        do { _ = try await process(worker, cp); XCTFail("Expected failure") }
        catch { XCTAssertEqual(error as? MemoEchoError, .transcriptTooLong(charCount: 8001)) }
    }

    func testStaleResponseCannotAdvanceCheckpoint() async {
        let cp = checkpoint()
        var active = true
        var worker = processor()
        worker.polish = { [self] _, _ in active = false; return polished() }
        do { _ = try await worker.process(cp, shouldContinue: { active }, onStage: { _ in }); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(cp.polished)
        XCTAssertEqual(cp.transcripts, ["已有转写"])
    }

    func testDeadlineDoesNotExtendAndDiscardReleasesPayload() {
        let cp = checkpoint(segments: [segment(1)])
        let now = Date()
        cp.retainUntilExpiration(now: now, lifetime: 600)
        cp.retainUntilExpiration(now: now.addingTimeInterval(300), lifetime: 600)
        XCTAssertTrue(cp.isValid(at: now.addingTimeInterval(599)))
        XCTAssertFalse(cp.isValid(at: now.addingTimeInterval(600)))
        cp.discard()
        XCTAssertTrue(cp.pendingSegments.isEmpty)
        XCTAssertTrue(cp.transcripts.isEmpty)
        XCTAssertNil(cp.context)
        XCTAssertFalse(cp.canRetry)
    }

    func testFinalOutputSkipsAllProvidersAndCannotRetryAfterAttempt() async throws {
        let cp = checkpoint(target: FakeInjectionDriver.focus())
        cp.polished = polished()
        cp.finalText = "最终结果"
        var worker = processor()
        worker.polish = { [self] _, _ in XCTFail("No provider calls for output retry"); return polished() }
        let result = try await process(worker, cp)
        XCTAssertEqual(result, "最终结果")
        XCTAssertTrue(cp.canRetry)
        cp.outputAttempted = true
        XCTAssertFalse(cp.canRetry)
    }

    func testCoordinatorRecoveryIsSingleFlightAndClearsOnSuccess() async throws {
        let driver = FakeInjectionDriver()
        driver.onWait = { tick in if tick == 2 { driver.apply("整理结果") } }
        var calls = 0
        var worker = processor()
        worker.polish = { [self] _, _ in calls += 1; await Task.yield(); return polished() }
        let (session, directory) = makeCoordinator(driver: driver, worker: worker)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cp = checkpoint(target: driver.current)
        session.retainRecovery(cp)
        session.retryRecovery()
        session.retryRecovery()
        XCTAssertTrue(session.isRecovering)
        XCTAssertFalse(session.canRetryRecovery)
        await waitUntil { !session.isRecovering }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(driver.pastes, 1)
        XCTAssertEqual(session.state, .done)
        XCTAssertNil(session.recovery)
        XCTAssertTrue(cp.discarded)
    }

    func testUnconfirmedOutputOffersCopyWithoutRetryOrProviderRerun() async {
        let driver = FakeInjectionDriver()
        let (session, directory) = makeCoordinator(driver: driver, worker: processor())
        defer { session.discardRecovery(); try? FileManager.default.removeItem(at: directory) }
        let cp = checkpoint(target: driver.current)
        session.retainRecovery(cp)
        session.retryRecovery()
        await waitUntil { !session.isRecovering }
        XCTAssertEqual(session.lastInjectionFailureText, "整理结果")
        XCTAssertTrue(cp.outputAttempted)
        XCTAssertFalse(session.canRetryRecovery)
        session.retryRecovery()
        XCTAssertEqual(driver.pastes, 1)
        XCTAssertEqual(driver.axWrites, 0)
        session.discardRecovery()
        XCTAssertNil(session.lastInjectionFailureText)
        XCTAssertNil(session.lastResult)
    }

    func testOutputBeforeDispatchCanBeRetriedWithoutLLM() async {
        let driver = FakeInjectionDriver()
        driver.canActivate = false
        var calls = 0
        var worker = processor()
        worker.polish = { [self] _, _ in calls += 1; return polished() }
        let (session, directory) = makeCoordinator(driver: driver, worker: worker)
        defer { session.discardRecovery(); try? FileManager.default.removeItem(at: directory) }
        session.retainRecovery(checkpoint(target: driver.current))
        session.retryRecovery()
        await waitUntil { !session.isRecovering }
        XCTAssertTrue(session.canRetryRecovery)
        driver.canActivate = true
        driver.onWait = { tick in if tick == 2 { driver.apply("整理结果") } }
        session.retryRecovery()
        await waitUntil { !session.isRecovering }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(driver.pastes, 1)
        XCTAssertEqual(session.state, .done)
    }

    func testExpiryCancelsRecoveryAndDropsLateResponse() async {
        let driver = FakeInjectionDriver()
        var worker = processor()
        worker.polish = { [self] _, _ in
            // Deliberately ignore cancellation to model a late provider response.
            await Task { try? await Task.sleep(for: .milliseconds(100)) }.value
            return polished()
        }
        let (session, directory) = makeCoordinator(driver: driver, worker: worker, lifetime: 0.02)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cp = checkpoint(target: driver.current)
        session.retainRecovery(cp)
        session.retryRecovery()
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(session.recovery)
        XCTAssertTrue(cp.discarded)
        XCTAssertNil(cp.polished)
        XCTAssertFalse(session.isRecovering)
        XCTAssertEqual(driver.pastes, 0)
        XCTAssertEqual(session.state, .cancelled)
    }

    func testCancelRecoveryDropsLateResponseWithoutWriting() async {
        let driver = FakeInjectionDriver()
        var worker = processor()
        worker.polish = { [self] _, _ in
            await Task { try? await Task.sleep(for: .milliseconds(60)) }.value
            return polished()
        }
        let (session, directory) = makeCoordinator(driver: driver, worker: worker)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cp = checkpoint(target: driver.current)
        session.retainRecovery(cp)
        session.retryRecovery()
        await Task.yield()
        session.cancel()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(session.recovery)
        XCTAssertTrue(cp.discarded)
        XCTAssertEqual(driver.pastes, 0)
    }

    func testNewFailureReplacesAndReleasesOldPayload() {
        let (session, directory) = makeCoordinator(worker: processor())
        defer { session.discardRecovery(); try? FileManager.default.removeItem(at: directory) }
        let old = checkpoint(segments: [segment(0)])
        session.retainRecovery(old)
        let new = checkpoint()
        session.retainRecovery(new)
        XCTAssertTrue(old.discarded)
        XCTAssertTrue(old.pendingSegments.isEmpty)
        XCTAssertEqual(session.recovery?.id, new.id)
    }

    func testCaptureInterruptionPreservesInflightSegmentAndTailWithoutAutomaticOutput() async throws {
        let gate = DelayedASR()
        let (session, recorder, directory) = try makeCaptureSession(seconds: 56, asr: gate)
        defer { session.cancel(); session.discardRecovery(); try? FileManager.default.removeItem(at: directory) }
        session.startRecording()
        for _ in 0..<1000 {
            if await gate.hasStarted { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let started = await gate.hasStarted
        XCTAssertTrue(started)
        recorder.onCaptureEvent?(.interrupted(.deviceDisconnected))
        XCTAssertEqual(session.currentError, .audioCaptureInterrupted(.deviceDisconnected))
        XCTAssertEqual(session.recoveryActionTitle, "继续处理已录内容")
        XCTAssertEqual(session.recovery?.pendingSegments.map(\.index), [0, 1])
        XCTAssertTrue(session.recovery?.transcripts.isEmpty == true)
        XCTAssertEqual(recorder.stops, 1)
        let recoveryID = session.recovery?.id
        await gate.complete()
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(session.recovery?.id, recoveryID)
        XCTAssertEqual(session.recovery?.pendingSegments.map(\.index), [0, 1], "late ASR cannot consume recovery audio")
        XCTAssertNil(session.lastResult)
        XCTAssertNil(session.lastInjectionFailureText)
        session.retryRecovery()
        await waitUntil { !session.isRecovering }
        XCTAssertEqual(session.currentError, .llmConfigurationIncomplete)
        XCTAssertEqual(session.recovery?.transcripts.count, 2)
        XCTAssertTrue(session.recovery?.pendingSegments.isEmpty == true)
        XCTAssertEqual(recorder.starts, 1)
    }

    func testInterruptionDuringEndCueClosesOnceAndKeepsTail() async throws {
        let (session, recorder, directory) = try makeCaptureSession(seconds: 1, asr: CountingASR())
        defer { session.discardRecovery(); try? FileManager.default.removeItem(at: directory) }
        session.startRecording()
        await waitUntil { recorder.starts == 1 }
        session.finishRecording()
        recorder.onCaptureEvent?(.interrupted(.streamFailed))
        XCTAssertEqual(recorder.stops, 1)
        XCTAssertEqual(session.recovery?.pendingSegments.count, 1)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(recorder.stops, 1)
        XCTAssertEqual(session.currentError, .audioCaptureInterrupted(.streamFailed))
    }

    func testNoSignalOnlyWarnsAndOldCaptureEventsCannotAffectNewSession() async throws {
        let (session, recorder, directory) = try makeCaptureSession(seconds: 1, asr: CountingASR())
        defer { session.cancel(); session.discardRecovery(); try? FileManager.default.removeItem(at: directory) }
        session.startRecording()
        await waitUntil { recorder.starts == 1 }
        let oldCallback = recorder.onCaptureEvent
        oldCallback?(.signalMissing)
        XCTAssertEqual(session.state, .recording)
        XCTAssertNotNil(session.recordingWarning)
        XCTAssertEqual(recorder.stops, 0)
        oldCallback?(.signalRestored)
        XCTAssertNil(session.recordingWarning)
        session.cancel()
        session.startRecording()
        await waitUntil { recorder.starts == 2 }
        oldCallback?(.interrupted(.deviceDisconnected))
        XCTAssertEqual(session.state, .recording)
        XCTAssertNil(session.recovery)
        XCTAssertEqual(recorder.stops, 1)
    }

    func testEmptyCaptureInterruptionShowsDeviceErrorWithoutEmptyRecovery() async throws {
        let (session, recorder, directory) = try makeCaptureSession(seconds: 0, asr: CountingASR())
        defer { try? FileManager.default.removeItem(at: directory) }
        session.startRecording()
        await waitUntil { recorder.starts == 1 }
        recorder.onCaptureEvent?(.interrupted(.stalled))
        XCTAssertEqual(session.state, .error)
        XCTAssertNil(session.recovery)
        XCTAssertEqual(session.currentError, .audioCaptureInterrupted(.stalled))
    }

    private func makeCaptureSession(seconds: Int, asr: any ASRProvider) throws -> (SessionCoordinator, TailRecorder, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ConfigStore(configDirectory: directory)
        var config = ASRConfig()
        config.selectedPlatform = .openAICompatibleASR
        config.openAICompatible = .init(baseURL: "http://localhost:8000/v1", apiKey: "synthetic-key", model: "test-asr")
        try store.saveASRConfig(config)
        try store.updateCloudValidationState(for: .openAICompatibleASR, status: .verified)
        let recorder = TailRecorder(seconds: seconds)
        let worker = SessionRecoveryProcessor(recognize: { _ in "recovered" },
            polish: { _, _ in throw MemoEchoError.llmConfigurationIncomplete },
            translate: { text, _, _ in text })
        let session = SessionCoordinator(permissionsManager: PermissionsManager(), configStore: store,
            audioDeviceManager: AudioDeviceManager(configStore: store), audioRecorder: recorder,
            ensureMicrophoneAuthorized: {}, ensureAccessibilityAuthorized: {},
            recoveryProcessorFactory: { _ in worker }, asrProviderOverride: { _ in asr })
        return (session, recorder, directory)
    }

    func testASRFailureWhileRecordingPreservesFailedSegmentAndRecordedTail() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(configDirectory: directory)
        var config = ASRConfig()
        config.selectedPlatform = .openAICompatibleASR
        config.openAICompatible = .init(baseURL: "http://localhost:8000/v1", apiKey: "synthetic-key", model: "test-asr")
        try store.saveASRConfig(config)
        try store.updateCloudValidationState(for: .openAICompatibleASR, status: .verified)
        let recorder = TailRecorder()
        let session = SessionCoordinator(permissionsManager: PermissionsManager(), configStore: store,
                                         audioDeviceManager: AudioDeviceManager(configStore: store), audioRecorder: recorder,
                                         ensureMicrophoneAuthorized: {}, ensureAccessibilityAuthorized: {},
                                         asrProviderOverride: { _ in FailingASR() })
        defer { session.cancel() }
        session.startRecording()
        // This integration case denoises a real 55-second segment. Shared CI
        // runners need more time than the lightweight recovery unit tests.
        await waitUntil(timeout: .seconds(15)) { session.recovery != nil }
        XCTAssertEqual(recorder.stops, 1)
        XCTAssertEqual(session.state, .error)
        XCTAssertEqual(session.recovery?.pendingSegments.map(\.index), [0, 1])
        XCTAssertEqual(session.recovery?.pendingSegments.last?.sealReason, .finalize)
        XCTAssertNil(session.lastRecordedAudio)
        session.discardRecovery()
    }

    func testInitialPolishFailureThenRecoveryDoesNotRerecordOrRecognizeAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(configDirectory: directory)
        var config = ASRConfig()
        config.selectedPlatform = .openAICompatibleASR
        config.openAICompatible = .init(baseURL: "http://localhost:8000/v1", apiKey: "synthetic-key", model: "test-asr")
        try store.saveASRConfig(config)
        try store.updateCloudValidationState(for: .openAICompatibleASR, status: .verified)
        let recorder = TailRecorder(seconds: 1)
        let asr = CountingASR()
        let driver = FakeInjectionDriver()
        driver.onWait = { tick in if tick == 2 { driver.apply("整理结果") } }
        var polishCalls = 0
        var worker = processor()
        worker.polish = { [self] transcripts, _ in
            XCTAssertEqual(transcripts, ["synthetic transcript"])
            polishCalls += 1
            if polishCalls == 1 { throw MemoEchoError.llmNetworkFailure(message: "synthetic") }
            return polished()
        }
        let session = SessionCoordinator(permissionsManager: PermissionsManager(), configStore: store,
                                         audioDeviceManager: AudioDeviceManager(configStore: store), audioRecorder: recorder,
                                         ensureMicrophoneAuthorized: {}, ensureAccessibilityAuthorized: {},
                                         textInjector: TextInjector(driver: driver), recoveryProcessorFactory: { _ in worker },
                                         asrProviderOverride: { _ in asr })
        session.startRecording()
        await waitUntil { recorder.starts == 1 }
        session.finishRecording()
        await waitUntil { session.recovery != nil }
        XCTAssertEqual(session.recovery?.stage, .polish)
        XCTAssertEqual(driver.pastes, 0)
        session.retryRecovery()
        await waitUntil { !session.isRecovering }
        let asrCalls = await asr.calls
        XCTAssertEqual(asrCalls, 1)
        XCTAssertEqual(polishCalls, 2)
        XCTAssertEqual(recorder.starts, 1)
        XCTAssertEqual(driver.pastes, 1)
        XCTAssertEqual(session.state, .done)
    }

    func testASRRetryReadsUpdatedCredentialsForOriginalPlatform() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(configDirectory: directory)
        let asr = CountingASR()
        var requestedKeys: [String] = []
        let session = SessionCoordinator(permissionsManager: PermissionsManager(), configStore: store,
                                         audioDeviceManager: AudioDeviceManager(configStore: store),
                                         asrProviderOverride: { config in
            XCTAssertEqual(config.selectedPlatform, .openAICompatibleASR)
            requestedKeys.append(config.openAICompatible.apiKey)
            return asr
        })
        defer { session.discardRecovery() }
        session.retainRecovery(checkpoint(segments: [segment(1)]))
        var updated = ASRConfig()
        updated.selectedPlatform = .aliyunRealtime
        updated.openAICompatible = .init(baseURL: "http://localhost:8000/v1", apiKey: "synthetic-updated", model: "test-asr")
        try store.saveASRConfig(updated)
        session.retryRecovery()
        await waitUntil { !session.isRecovering }
        XCTAssertEqual(requestedKeys, ["synthetic-updated"])
        XCTAssertEqual(session.recovery?.stage, .polish)
        XCTAssertEqual(session.currentError, .llmConfigurationIncomplete)
        XCTAssertTrue(session.recoveryNeedsSettings)
        XCTAssertTrue(session.recovery?.pendingSegments.isEmpty == true)
    }

    func testTranslationFailureGetsItsOwnHUDLabel() async {
        var worker = processor()
        worker.translate = { _, _, _ in throw MemoEchoError.llmEmptyResponse }
        let (session, directory) = makeCoordinator(worker: worker)
        defer { session.discardRecovery(); try? FileManager.default.removeItem(at: directory) }
        var reasons: [HUDFailureReason] = []
        session.onFeedbackEvent = { if case .processingFailed(let reason) = $0 { reasons.append(reason) } }
        session.retainRecovery(checkpoint(mode: .translate))
        session.retryRecovery()
        await waitUntil { !session.isRecovering }
        XCTAssertEqual(reasons, [.translationFailed])
        XCTAssertNil(session.lastInjectionFailureText)
        XCTAssertEqual(session.recovery?.stage, .translation)
    }

    func testUnverifiedPasteCompletesWithoutRecoveryOrMenuText() async throws {
        let driver = FakeInjectionDriver()
        driver.current = FakeInjectionDriver.window()
        let target = try XCTUnwrap(TextInjector(driver: driver).captureTarget(pid: 42, bundleID: "test"))
        let (session, directory) = makeCoordinator(driver: driver, worker: processor(), lifetime: 0.15)
        defer { session.discardRecovery(); try? FileManager.default.removeItem(at: directory) }
        var dispatched = 0
        var finished = 0
        var failed = 0
        session.onFeedbackEvent = { event in
            switch event {
            case .outputDispatched: dispatched += 1
            case .processingFinished: finished += 1
            case .processingFailed: failed += 1
            default: break
            }
        }
        driver.onWait = { tick in
            guard tick == 2 else { return }
            XCTAssertEqual(driver.pastes, 1)
            XCTAssertEqual(dispatched, 1, "Dismiss Thinking after dispatch, before waiting for clipboard cleanup")
            XCTAssertTrue(driver.isInjecting, "Keep the injection lease active while the app consumes the paste")
            XCTAssertEqual(driver.board.restores, 0)
        }
        let cp = checkpoint(target: target)
        session.retainRecovery(cp)
        session.retryRecovery()
        await waitUntil { !session.isRecovering }
        XCTAssertEqual(session.state, .done)
        XCTAssertNil(session.currentError)
        XCTAssertEqual(dispatched, 1)
        XCTAssertEqual(finished, 0)
        XCTAssertEqual(failed, 0)
        XCTAssertNil(session.lastInjectionFailureText)
        XCTAssertNil(session.recovery)
        XCTAssertTrue(cp.discarded)
        XCTAssertNil(cp.finalText)
        XCTAssertTrue(cp.outputAttempted)
        XCTAssertFalse(cp.canRetry)
        XCTAssertFalse(session.canRetryRecovery)
        XCTAssertNil(cp.target)
        XCTAssertNil(cp.context)
        XCTAssertNil(cp.polished)
        XCTAssertTrue(cp.transcripts.isEmpty)
        session.retryRecovery()
        XCTAssertEqual(driver.pastes, 1)
        await waitUntil { session.recovery == nil }
        XCTAssertNil(session.lastInjectionFailureText)
    }

    func testUnreadableFieldHidesHUDBeforeClipboardCleanup() async {
        let driver = FakeInjectionDriver()
        driver.current = FakeInjectionDriver.focus(readable: false)
        let originalClipboard = driver.board.items
        let (session, directory) = makeCoordinator(driver: driver, worker: processor())
        let hud = HUDFeedbackController()
        defer { session.discardRecovery(); try? FileManager.default.removeItem(at: directory) }
        session.onFeedbackEvent = { hud.handleEvent($0) }
        driver.onAsyncWait = { tick in
            guard tick == 2 else { return }
            // Simulate a receiver still consuming the paste after the normal HUD fade.
            await self.waitUntil(timeout: .seconds(1)) { hud.hudState == .hidden }
            XCTAssertEqual(hud.hudState, .hidden)
            XCTAssertFalse(hud.isHUDPresented)
            XCTAssertTrue(driver.isInjecting)
            XCTAssertEqual(driver.board.restores, 0)
        }
        session.retainRecovery(checkpoint(target: driver.current))
        session.retryRecovery()
        await waitUntil { !session.isRecovering }
        XCTAssertEqual(session.state, .done)
        XCTAssertEqual(driver.waits, 21)
        XCTAssertEqual(driver.board.items, originalClipboard)
        XCTAssertEqual(driver.board.restores, 1)
    }

    func testUnverifiedDispatchStillReportsLaterTargetLoss() async throws {
        let driver = FakeInjectionDriver()
        driver.current = FakeInjectionDriver.window()
        let target = try XCTUnwrap(TextInjector(driver: driver).captureTarget(pid: 42, bundleID: "test"))
        let (session, directory) = makeCoordinator(driver: driver, worker: processor())
        defer { session.discardRecovery(); try? FileManager.default.removeItem(at: directory) }
        var events: [String] = []
        session.onFeedbackEvent = {
            switch $0 {
            case .outputDispatched: events.append("dispatched")
            case .processingFailed: events.append("failed")
            case .processingFinished: events.append("finished")
            default: break
            }
        }
        driver.onWait = { tick in if tick == 2 { driver.continuity.invalidate() } }
        session.retainRecovery(checkpoint(target: target))
        session.retryRecovery()
        await waitUntil { !session.isRecovering }
        XCTAssertEqual(events, ["dispatched", "failed"])
        XCTAssertEqual(session.state, .error)
        XCTAssertEqual(driver.pastes, 1)
        XCTAssertEqual(driver.axWrites, 0)
        XCTAssertEqual(driver.waits, 21)
        XCTAssertEqual(driver.board.restores, 1)
        XCTAssertTrue(session.recovery?.outputAttempted == true)
    }

    private func makeCoordinator(driver: FakeInjectionDriver = FakeInjectionDriver(), worker: SessionRecoveryProcessor,
                                 lifetime: TimeInterval = 600) -> (SessionCoordinator, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ConfigStore(configDirectory: directory)
        let session = SessionCoordinator(permissionsManager: PermissionsManager(), configStore: store,
                                         audioDeviceManager: AudioDeviceManager(configStore: store),
                                         textInjector: TextInjector(driver: driver), recoveryLifetime: lifetime,
                                         recoveryProcessorFactory: { _ in worker })
        return (session, directory)
    }

    private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out")
    }
}

private struct FailingASR: ASRProvider {
    func recognize(audioData: Data, timeout: TimeInterval?) async throws -> TranscriptResult {
        throw MemoEchoError.cloudASRNetworkFailure(message: "synthetic failure")
    }
}

@MainActor
private final class TailRecorder: AudioRecording {
    var onCaptureEvent: (@MainActor @Sendable (AudioCaptureEvent) -> Void)?
    var stops = 0
    var starts = 0
    let seconds: Int
    init(seconds: Int = 56) { self.seconds = seconds }
    var currentDurationMs: Int { seconds * 1000 }
    func startRecording(device: AVCaptureDevice?, onPCMChunk: (@Sendable (Data) -> Void)?) async throws {
        starts += 1
        let samples = (0..<(seconds * 16_000)).map { index in Int16(sin(Double(index) * 0.17) * 12_000) }
        onPCMChunk?(samples.withUnsafeBytes { Data($0) })
    }
    func stopRecording() -> AudioRecordingResult {
        stops += 1
        return .init(data: Data([1, 2]), durationMs: seconds * 1000)
    }
    func currentLevel() -> Float { 0 }
}

private actor CountingASR: ASRProvider {
    private(set) var calls = 0
    func recognize(audioData: Data, timeout: TimeInterval?) async throws -> TranscriptResult {
        calls += 1
        return .init(text: "synthetic transcript", requestId: nil, durationMs: 100)
    }
}

private actor DelayedASR: ASRProvider {
    private var continuation: CheckedContinuation<TranscriptResult, Never>?
    private(set) var hasStarted = false
    func recognize(audioData: Data, timeout: TimeInterval?) async throws -> TranscriptResult {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            hasStarted = true
        }
    }
    func complete() {
        continuation?.resume(returning: .init(text: "late result", requestId: nil, durationMs: 1))
        continuation = nil
    }
}
