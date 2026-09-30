import AVFoundation
import XCTest
@testable import MemoEcho

@MainActor
final class SessionCoordinatorLearningTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testBeginPostInjectionLearningSkipsTranslateMode() async {
        let learner = MockPostInjectionLearner()
        let coordinator = makeCoordinator(
            dictionaryStore: PersonalDictionaryStore(directoryURL: tempDirectory),
            learner: learner
        )

        coordinator.beginPostInjectionLearningIfNeeded(
            generation: 0,
            mode: .translate,
            sessionID: "session-test",
            beforeInjection: .init(pid: 42, bundleID: "com.example.app", identity: .init(token: "input"), value: "", selection: NSRange(location: 0, length: 0), isComposing: false),
            insertedText: "联系普林"
        )

        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(learner.observeCallCount, 0)
    }

    func testBeginPostInjectionLearningEmitsHUDNoticeForLearnedTerm() async {
        let learner = MockPostInjectionLearner()
        learner.learnedTerm = "朴邻"
        let coordinator = makeCoordinator(
            dictionaryStore: PersonalDictionaryStore(directoryURL: tempDirectory),
            learner: learner
        )

        var receivedEvents: [SessionFeedbackEvent] = []
        coordinator.onFeedbackEvent = { event in
            receivedEvents.append(event)
        }

        coordinator.beginPostInjectionLearningIfNeeded(
            generation: 0,
            mode: .polish,
            sessionID: "session-test",
            beforeInjection: .init(pid: 42, bundleID: "com.example.app", identity: .init(token: "input"), value: "", selection: NSRange(location: 0, length: 0), isComposing: false),
            insertedText: "联系普林"
        )

        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(learner.observeCallCount, 1)
        XCTAssertEqual(receivedEvents.count, 1)
        guard case .dictionaryTermLearned(let term) = receivedEvents.first else {
            return XCTFail("expected dictionaryTermLearned event")
        }
        XCTAssertEqual(term, "朴邻")
    }

    func testStartRecordingFailsBeforeHUDWhenAccessibilityPermissionMissing() {
        let learner = MockPostInjectionLearner()
        let coordinator = makeCoordinator(
            dictionaryStore: PersonalDictionaryStore(directoryURL: tempDirectory),
            learner: learner,
            ensureMicrophoneAuthorized: {},
            ensureAccessibilityAuthorized: {
                throw PermissionError.accessibilityPermissionDenied
            }
        )

        var receivedEvents: [SessionFeedbackEvent] = []
        coordinator.onFeedbackEvent = { event in
            receivedEvents.append(event)
        }

        coordinator.startRecording()

        XCTAssertEqual(coordinator.state, .error)
        XCTAssertEqual(coordinator.currentError, .accessibilityPermissionDenied)
        XCTAssertEqual(receivedEvents.count, 1)
        guard case .processingFailed(.permissionDenied) = receivedEvents.first else {
            return XCTFail("expected permission failure event")
        }
    }

    func testQuickStartThenImmediateStopSilentlyCancelsWithoutProcessingHUD() throws {
        let learner = MockPostInjectionLearner()
        let coordinator = makeCoordinator(
            dictionaryStore: PersonalDictionaryStore(directoryURL: tempDirectory),
            learner: learner,
            ensureMicrophoneAuthorized: {},
            ensureAccessibilityAuthorized: {},
            configureConfigStore: { configStore in
                var config = ASRConfig()
                config.selectedPlatform = .tencentCloudRealtime
                config.tencentCloud.appID = "123456"
                config.tencentCloud.secretId = "test-secret-id"
                config.tencentCloud.secretKey = "test-secret-key"
                try! configStore.saveASRConfig(config)
                try! configStore.updateCloudValidationState(
                    for: .tencentCloudRealtime,
                    status: .verified
                )
            }
        )

        var receivedEvents: [SessionFeedbackEvent] = []
        coordinator.onFeedbackEvent = { event in
            receivedEvents.append(event)
        }

        coordinator.startRecording()
        coordinator.finishRecording()

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertNil(coordinator.currentError)
        XCTAssertNil(coordinator.lastRecordedAudio)
        XCTAssertEqual(receivedEvents.count, 2)
        guard case .recordingStarted = receivedEvents[0] else {
            return XCTFail("expected recordingStarted event")
        }
        guard case .processingCancelled = receivedEvents[1] else {
            return XCTFail("expected processingCancelled event")
        }
    }

    func testEndCuePrecedesCaptureStopAndDuplicateFinishIsIgnored() async {
        let recorder = FakeAudioRecorder()
        let coordinator = makeAudioCoordinator(recorder)
        var stoppedEvents = 0
        coordinator.onFeedbackEvent = { if case .recordingStopped = $0 { stoppedEvents += 1 } }
        coordinator.startRecording(output: .onboardingTrial { _ in true })
        await waitForRecorder(recorder, starts: 1)
        coordinator.finishRecording()
        coordinator.finishRecording()
        XCTAssertEqual(stoppedEvents, 1)
        XCTAssertEqual(recorder.stopCount, 0, "End must be emitted while capture remains open")
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(recorder.stopCount, 0)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(recorder.stopCount, 1)
    }

    func testCancelDuringEndDelayCannotStopNextRecording() async {
        let recorder = FakeAudioRecorder()
        let coordinator = makeAudioCoordinator(recorder)
        coordinator.startRecording(output: .onboardingTrial { _ in true })
        await waitForRecorder(recorder, starts: 1)
        coordinator.finishRecording()
        coordinator.cancel()
        XCTAssertEqual(recorder.stopCount, 1)
        coordinator.startRecording(output: .onboardingTrial { _ in true })
        await waitForRecorder(recorder, starts: 2)
        try? await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(recorder.stopCount, 1)
        XCTAssertEqual(coordinator.state, .recording)
        coordinator.cancel()
    }

    func testShortCaptureClosesImmediatelyWithoutEndCue() async {
        let recorder = FakeAudioRecorder()
        recorder.durationMs = 499
        let coordinator = makeAudioCoordinator(recorder)
        var stoppedEvents = 0
        coordinator.onFeedbackEvent = { if case .recordingStopped = $0 { stoppedEvents += 1 } }
        coordinator.startRecording(output: .onboardingTrial { _ in true })
        await waitForRecorder(recorder, starts: 1)
        coordinator.finishRecording()
        XCTAssertEqual(stoppedEvents, 0)
        XCTAssertEqual(recorder.stopCount, 1)
        XCTAssertEqual(coordinator.state, .idle)
    }

    private func makeAudioCoordinator(_ recorder: FakeAudioRecorder) -> SessionCoordinator {
        makeCoordinator(dictionaryStore: nil, learner: MockPostInjectionLearner(),
                        audioRecorder: recorder, ensureMicrophoneAuthorized: {}, ensureAccessibilityAuthorized: {},
                        configureConfigStore: { store in
            var config = ASRConfig()
            config.selectedPlatform = .tencentCloudRealtime
            config.tencentCloud.appID = "123456"
            config.tencentCloud.secretId = "test-id"
            config.tencentCloud.secretKey = "test-key"
            try! store.saveASRConfig(config)
            try! store.updateCloudValidationState(for: .tencentCloudRealtime, status: .verified)
        })
    }

    private func waitForRecorder(_ recorder: FakeAudioRecorder, starts: Int) async {
        for _ in 0..<100 {
            if recorder.startCount == starts { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Recorder did not start")
    }

    @MainActor
    private final class FakeAudioRecorder: AudioRecording {
    var onCaptureEvent: (@MainActor @Sendable (AudioCaptureEvent) -> Void)?
        var durationMs = 800
        var startCount = 0
        var stopCount = 0
        var running = false
        var currentDurationMs: Int { running ? durationMs : 0 }
        func startRecording(device: AVCaptureDevice?, onPCMChunk: (@Sendable (Data) -> Void)?) async throws {
            startCount += 1
            running = true
        }
        func currentLevel() -> Float { 0 }
        func stopRecording() -> AudioRecordingResult {
            stopCount += 1
            running = false
            return .init(data: Data(), durationMs: durationMs)
        }
    }

    private func makeCoordinator(
        dictionaryStore: PersonalDictionaryStore?,
        learner: any PostInjectionDictionaryLearning,
        audioRecorder: any AudioRecording = AudioRecorder(),
        ensureMicrophoneAuthorized: @escaping @MainActor @Sendable () throws -> Void = {
            try PermissionsManager().ensureMicrophoneAuthorized()
        },
        ensureAccessibilityAuthorized: @escaping @MainActor @Sendable () throws -> Void = {
            try PermissionsManager().ensureAccessibilityAuthorized()
        },
        configureConfigStore: (@MainActor (ConfigStore) -> Void)? = nil
    ) -> SessionCoordinator {
        let configStore = ConfigStore(configDirectory: tempDirectory)
        configureConfigStore?(configStore)
        let audioDeviceManager = AudioDeviceManager(configStore: configStore)
        return SessionCoordinator(
            permissionsManager: PermissionsManager(),
            configStore: configStore,
            audioDeviceManager: audioDeviceManager,
            audioRecorder: audioRecorder,
            dictionaryStore: dictionaryStore,
            postInjectionLearner: learner,
            ensureMicrophoneAuthorized: ensureMicrophoneAuthorized,
            ensureAccessibilityAuthorized: ensureAccessibilityAuthorized
        )
    }

    private final class MockPostInjectionLearner: PostInjectionDictionaryLearning, @unchecked Sendable {
        var observeCallCount = 0
        var learnedTerm: String?

        func observe(
            beforeInjection: FocusedElementTextSnapshot,
            insertedText: String,
            store: PersonalDictionaryStore,
            shouldContinue: @escaping @MainActor @Sendable () -> Bool,
            onObservation: @escaping @MainActor @Sendable (PostInjectionObservationEvent) -> Void,
            onDecision: @escaping @MainActor @Sendable (PostInjectionLearningDecision) -> Void
        ) async {
            observeCallCount += 1
            guard shouldContinue(), let learnedTerm else { return }
            _ = try? store.addLearnedTermIfNeeded(learnedTerm)
            onDecision(.learned(learnedTerm))
        }
    }
}
