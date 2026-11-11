import XCTest
@testable import MemoEcho

@MainActor
final class AppCoordinatorHotkeyTests: XCTestCase {

    func testFirstHoldAfterLaunchEndsRecordingWhenAccessibilityIsAlreadyGranted() async throws {
        let coordinator = try makeHoldCoordinator()
        let store = coordinator.configStore
        try store.saveOnboardingProgress(.init(hasFinishedPresentation: true, hasConfirmedHotkey: true))
        var asr = store.asrConfig
        asr.selectedPlatform = .tencentCloudRealtime
        asr.tencentCloud.appID = "123456"
        asr.tencentCloud.secretId = "test-id"
        asr.tencentCloud.secretKey = "test-secret"
        try store.saveASRConfig(asr)
        coordinator.cloudASRValidationService.recordSuccess(.init(platform: asr.selectedPlatform, asrConfig: asr))
        try store.saveLLMConfig(.init(baseURL: "https://example.com/v1", model: "test-model"), apiKey: "test-key")
        coordinator.llmValidationService.recordSuccess(.init(
            baseURL: store.llmConfig.baseURL, apiKey: store.openAIAPIKey, model: store.llmConfig.model,
            omitThinkingParameter: store.omitThinkingParameter
        ))

        let hotkeyManager = coordinator.hotkeyManager
        hotkeyManager.testInstallHandler = { _ in .success }
        coordinator.setupHotkey()
        XCTAssertEqual(coordinator.permissionsManager.accessibilityStatus, .unchecked)
        let session = coordinator.sessionCoordinator
        defer { session.cancel() }
        let finished = XCTestExpectation(description: "Release finishes the short recording")
        session.onFeedbackEvent = { event in
            if case .processingCancelled = event { finished.fulfill() }
        }
        var gestures: [HotkeyGestureAction] = []
        let handleGesture = hotkeyManager.onGestureAction
        hotkeyManager.onGestureAction = { action in
            gestures.append(action)
            handleGesture?(action)
        }

        hotkeyManager.consumeEvent(.modifiersChanged([.rightCommand]), at: 0)
        XCTAssertEqual(coordinator.permissionsManager.accessibilityStatus, .granted)
        XCTAssertEqual(session.state, .recording)
        hotkeyManager.consumeEvent(.modifiersChanged([]), at: 0.1)

        let expected: [HotkeyGestureAction] = [.holdBegan(1), .holdEnded(1)]
        guard gestures == expected else {
            XCTFail("Expected \(expected), received \(gestures)")
            return
        }
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertEqual(session.state, .idle)
    }

    func testAccessibilityGrantRetriesFailedHotkeyRegistration() throws {
        let coordinator = try makeHoldCoordinator()
        coordinator.hotkeyManager.testInstallHandler = { _ in .failure("Monitor unavailable") }
        coordinator.setupHotkey()
        XCTAssertNil(coordinator.hotkeyManager.registeredHotkey)

        coordinator.hotkeyManager.testInstallHandler = { _ in .success }
        coordinator.permissionsManager.checkAccessibilityPermissionForUserAction()

        XCTAssertEqual(coordinator.hotkeyManager.registeredHotkey, coordinator.configStore.generalConfig.hotkey)
        XCTAssertEqual(coordinator.readinessService.hotkeyRegistrationResult, .success)
    }

    private func makeHoldCoordinator() throws -> AppCoordinator {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(configDirectory: directory)
        try store.saveGeneralConfig(.init(hotkey: .default.withTriggerMode(.hold), windowContextEnabled: false))
        return AppCoordinator(
            configStore: store,
            permissionsManager: PermissionsManager(operations: .init(
                microphoneStatus: { .granted }, accessibilityStatus: { .granted },
                requestMicrophone: {}, openMicrophoneSettings: {}, openAccessibilitySettings: {}
            )),
            dictionaryStore: PersonalDictionaryStore(directoryURL: directory)
        )
    }

    func testHotkeyStartsRecordingWhenSessionCanRestart() {
        let restartableStates: [SessionState] = [.idle, .done, .error, .cancelled]

        for state in restartableStates {
            XCTAssertEqual(
                AppCoordinator.hotkeyAction(for: state),
                .startRecording
            )
        }
    }

    func testHotkeyFinishesRecordingWhenAlreadyRecording() {
        XCTAssertEqual(
            AppCoordinator.hotkeyAction(for: .recording),
            .finishRecording
        )
    }

    func testHotkeyDoesNotInterruptProcessingStates() {
        let activeStates: [SessionState] = [.transcribing, .polishing, .injecting]

        for state in activeStates {
            XCTAssertNil(AppCoordinator.hotkeyAction(for: state))
        }
    }

    func testTrialRoutingRequiresForegroundTrialWindowAfterSetupCompletion() {
        XCTAssertTrue(AppCoordinator.shouldStartOnboardingTrial(
            isSetupComplete: true, isOnboardingPresented: true, isOnboardingWindowKey: true, step: .tryIt
        ))
        XCTAssertFalse(AppCoordinator.shouldStartOnboardingTrial(
            isSetupComplete: true, isOnboardingPresented: true, isOnboardingWindowKey: false, step: .tryIt
        ), "切到其他应用时应走日常输入")
        XCTAssertFalse(AppCoordinator.shouldStartOnboardingTrial(
            isSetupComplete: false, isOnboardingPresented: true, isOnboardingWindowKey: true, step: .tryIt
        ))
        XCTAssertFalse(AppCoordinator.shouldStartOnboardingTrial(
            isSetupComplete: true, isOnboardingPresented: true, isOnboardingWindowKey: true, step: .hotkey
        ))
    }

    func testPureModifierPressShowsPendingHUDWithoutStartingRecording() {
        var interaction = AppCoordinator.SpecialHotkeyInteraction()

        let effect = interaction.handle(.began, sessionState: .idle)

        XCTAssertEqual(effect, .showPendingHUD)
        XCTAssertEqual(interaction.pendingAction, .startRecording)
    }

    func testCleanPureModifierReleaseConfirmsPendingRecordingAction() {
        var interaction = AppCoordinator.SpecialHotkeyInteraction()
        _ = interaction.handle(.began, sessionState: .idle)

        let effect = interaction.handle(.confirmed, sessionState: .idle)

        XCTAssertEqual(effect, .perform(.startRecording))
        XCTAssertNil(interaction.pendingAction)
    }

    func testChordCancelsPendingHUDWithoutStartingRecording() {
        var interaction = AppCoordinator.SpecialHotkeyInteraction()
        _ = interaction.handle(.began, sessionState: .idle)

        let effect = interaction.handle(.cancelled, sessionState: .idle)

        XCTAssertEqual(effect, .dismissPendingHUD)
        XCTAssertNil(interaction.pendingAction)
    }

    func testChordDoesNotStopAnExistingRecording() {
        var interaction = AppCoordinator.SpecialHotkeyInteraction()

        XCTAssertEqual(interaction.handle(.began, sessionState: .recording), .none)
        XCTAssertEqual(interaction.pendingAction, .finishRecording)
        XCTAssertEqual(interaction.handle(.cancelled, sessionState: .recording), .none)
        XCTAssertNil(interaction.pendingAction)
    }

    func testCleanPureModifierReleaseStopsAnExistingRecording() {
        var interaction = AppCoordinator.SpecialHotkeyInteraction()
        _ = interaction.handle(.began, sessionState: .recording)

        XCTAssertEqual(
            interaction.handle(.confirmed, sessionState: .recording),
            .perform(.finishRecording)
        )
    }
}
