import XCTest
@testable import MemoEcho

@MainActor
final class OnboardingTestFixture {
    let directory: URL
    let store: ConfigStore
    let permissionsManager: PermissionsManager
    let readinessService: VoiceInputReadinessService
    let coordinator: OnboardingCoordinator

    init(microphone: MicrophonePermission = .granted, accessibility: AccessibilityPermission = .granted) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MemoEchoOnboardingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = ConfigStore(configDirectory: directory)
        permissionsManager = PermissionsManager(operations: .init(
            microphoneStatus: { microphone }, accessibilityStatus: { accessibility },
            requestMicrophone: {}, openMicrophoneSettings: {}, openAccessibilitySettings: {}
        ), accessibilityStatusQueryEnabled: true)
        let llm = LLMValidationService(validator: { _, _ in })
        let cloud = CloudASRValidationService(configStore: store, validatorFactory: { _ in ReadyCloudValidator() })
        readinessService = VoiceInputReadinessService(configStore: store, permissionsManager: permissionsManager,
                                                     llmValidationService: llm, cloudASRValidationService: cloud)
        coordinator = OnboardingCoordinator(configStore: store, permissionsManager: permissionsManager,
                                             modelDownloadManager: ModelDownloadManager(configStore: store),
                                             llmModelListService: LLMModelListService(), llmValidationService: llm,
                                             cloudASRValidationService: cloud, readinessService: readinessService)
    }

    func makeReady() async throws {
        var asr = store.asrConfig
        asr.selectedPlatform = .tencentCloudSentence
        asr.tencentCloud.secretId = "test-id"
        asr.tencentCloud.secretKey = "test-secret"
        try store.saveASRConfig(asr)
        try store.saveLLMConfig(.init(baseURL: "https://example.com/v1", model: "test-model"), apiKey: "test-key")
        readinessService.hotkeyRegistrationResult = .success
        coordinator.refresh()
        for _ in 0..<100 {
            if coordinator.readiness.asr.isReady && coordinator.readiness.llm.isReady { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Fake validators did not finish")
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }

    private struct ReadyCloudValidator: CloudASRValidating {
        func validateCredentials() async throws {}
    }
}

@MainActor
final class OnboardingCoordinatorTests: XCTestCase {
    func testCompletedUserCanTryVoiceInputWithoutEditorClick() async throws {
        let fixture = try OnboardingTestFixture()
        defer { fixture.cleanup() }
        try await fixture.makeReady()
        try fixture.store.saveOnboardingProgress(.init(lastVisitedStep: .tryIt, hasFinishedPresentation: true,
                                                     hasConfirmedHotkey: true))
        let coordinator = fixture.coordinator
        coordinator.prepareForPresentation(at: .tryIt)
        // The foreground trial page already owns the result destination. A user
        // following its shortcut prompt must not need an extra editor click.
        let trialID = try XCTUnwrap(coordinator.beginTrial())
        XCTAssertTrue(fixture.store.hasCompletedInitialSetup)
        XCTAssertFalse(coordinator.canContinue)
        XCTAssertTrue(coordinator.receiveTrialText("明天下午三点，一起讨论新方案。", for: trialID))
        coordinator.handleTrialFeedback(.processingFinished, error: nil)
        XCTAssertEqual(coordinator.trialText, "明天下午三点，一起讨论新方案。")
        XCTAssertTrue(coordinator.canContinue)
        XCTAssertTrue(fixture.store.hasCompletedInitialSetup)
    }

    func testNewUserStartsAtWelcomeAndReopeningResumesLastStep() throws {
        let fixture = try OnboardingTestFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator
        coordinator.prepareForPresentation()
        XCTAssertEqual(coordinator.step, .welcome)
        coordinator.goForward()
        XCTAssertEqual(coordinator.step, .asr)
        coordinator.go(to: .llm)
        coordinator.dismissed()
        coordinator.prepareForPresentation()
        XCTAssertEqual(coordinator.step, .llm)
        XCTAssertFalse(fixture.store.hasCompletedInitialSetup)
    }

    func testLocalModelDownloadCannotLeaveASRStep() throws {
        let fixture = try OnboardingTestFixture()
        defer { fixture.cleanup() }
        try fixture.store.updateLocalModelStatus(.downloading)
        fixture.coordinator.prepareForPresentation(at: .asr)
        XCTAssertFalse(fixture.coordinator.canContinue)
        fixture.coordinator.goForward()
        XCTAssertEqual(fixture.coordinator.step, .asr)
        XCTAssertFalse(fixture.store.hasCompletedInitialSetup)
    }

    func testClosingOrLeavingTrialCancelsItAndRejectsLateResults() async throws {
        let fixture = try OnboardingTestFixture()
        defer { fixture.cleanup() }
        try await fixture.makeReady()
        try fixture.store.saveOnboardingProgress(.init(lastVisitedStep: .tryIt, hasFinishedPresentation: true,
                                                     hasConfirmedHotkey: true))
        let coordinator = fixture.coordinator
        coordinator.prepareForPresentation(at: .tryIt)
        var cancellations = 0
        coordinator.onCancelTrial = { cancellations += 1 }
        let firstID = try XCTUnwrap(coordinator.beginTrial())
        XCTAssertNil(coordinator.beginTrial(), "一次只允许一个试用")
        coordinator.goBack()
        XCTAssertEqual(coordinator.step, .tryIt, "试用页不允许返回配置步骤")
        coordinator.go(to: .hotkey)
        XCTAssertEqual(cancellations, 1)
        XCTAssertFalse(coordinator.receiveTrialText("迟到结果", for: firstID))
        coordinator.go(to: .tryIt)
        let secondID = try XCTUnwrap(coordinator.beginTrial())
        XCTAssertFalse(coordinator.receiveTrialText("上次结果", for: firstID))
        coordinator.dismissed()
        XCTAssertEqual(cancellations, 2)
        XCTAssertFalse(coordinator.receiveTrialText("关窗后结果", for: secondID))
        XCTAssertEqual(coordinator.trialText, "")
        XCTAssertTrue(fixture.store.hasCompletedInitialSetup)
    }

    func testOtherPagesAndUnreadyConfigurationCannotStartTrial() async throws {
        let fixture = try OnboardingTestFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator
        coordinator.prepareForPresentation(at: .tryIt)
        XCTAssertNil(coordinator.beginTrial())
        try await fixture.makeReady()
        try fixture.store.saveOnboardingProgress(.init(hasConfirmedHotkey: true))
        coordinator.go(to: .hotkey)
        XCTAssertNil(coordinator.beginTrial())
    }

    func testRepeatedPresentationDoesNotJumpAwayFromActiveStep() throws {
        let fixture = try OnboardingTestFixture()
        defer { fixture.cleanup() }
        fixture.coordinator.prepareForPresentation(at: .llm)
        fixture.coordinator.prepareForPresentation(at: .permissions)
        XCTAssertEqual(fixture.coordinator.step, .llm)
    }

    func testExplicitWelcomeEntryPreservesCompletedSetupAndConfiguration() async throws {
        let fixture = try OnboardingTestFixture()
        defer { fixture.cleanup() }
        try await fixture.makeReady()
        try fixture.store.saveOnboardingProgress(.init(lastVisitedStep: .permissions,
                                                      hasFinishedPresentation: true, hasConfirmedHotkey: true))
        fixture.coordinator.prepareForPresentation(at: .welcome)
        XCTAssertEqual(fixture.coordinator.step, .welcome)
        XCTAssertTrue(fixture.store.hasCompletedInitialSetup)
        XCTAssertTrue(fixture.store.onboardingProgress.hasConfirmedHotkey)
        XCTAssertEqual(fixture.store.llmConfig.model, "test-model")
        XCTAssertTrue(fixture.coordinator.readiness.isReady)
        XCTAssertEqual(fixture.coordinator.trialPhase, .idle)
    }

    func testDefaultShortcutRequiresExplicitAcceptanceBeforeCompletion() async throws {
        let fixture = try OnboardingTestFixture()
        defer { fixture.cleanup() }
        try await fixture.makeReady()
        let coordinator = fixture.coordinator
        coordinator.prepareForPresentation(at: .hotkey)
        XCTAssertFalse(coordinator.readiness.hotkey.isReady)
        XCTAssertEqual(coordinator.primaryActionTitle, "完成设置")
        XCTAssertTrue(coordinator.canContinue)
        coordinator.goForward()
        XCTAssertTrue(fixture.store.onboardingProgress.hasConfirmedHotkey)
        XCTAssertEqual(coordinator.step, .tryIt)
        XCTAssertTrue(coordinator.readiness.isReady)
        XCTAssertEqual(coordinator.primaryActionTitle, "开始使用")
        XCTAssertEqual(coordinator.trialPhase, .idle)
        XCTAssertTrue(coordinator.canContinue, "试用是可选项，不应阻止已就绪用户开始使用")
        XCTAssertTrue(fixture.store.hasCompletedInitialSetup)
        var finishes = 0
        coordinator.onFinish = { finishes += 1 }
        coordinator.goForward()
        XCTAssertTrue(fixture.store.hasCompletedInitialSetup)
        XCTAssertFalse(coordinator.isPresented)
        XCTAssertEqual(finishes, 1)
    }

    func testCannotFinishHotkeyStepWithMissingConfiguration() throws {
        let fixture = try OnboardingTestFixture()
        defer { fixture.cleanup() }
        fixture.coordinator.prepareForPresentation(at: .hotkey)
        fixture.coordinator.onFinish = { XCTFail("Must not complete") }
        fixture.coordinator.goForward()
        XCTAssertFalse(fixture.store.hasCompletedInitialSetup)
        XCTAssertTrue(fixture.coordinator.isPresented)
    }

    func testFinishedUserRecoveryOpensSettingsInsteadOfWizardStep() async throws {
        let fixture = try OnboardingTestFixture()
        defer { fixture.cleanup() }
        try await fixture.makeReady()
        try fixture.store.saveOnboardingProgress(.init(lastVisitedStep: .tryIt, hasFinishedPresentation: true, hasConfirmedHotkey: true))
        try fixture.store.saveLLMConfig(.init(baseURL: "", model: ""), apiKey: "")
        fixture.coordinator.prepareForPresentation(at: .tryIt)
        var recoveryStep: SetupStep?
        fixture.coordinator.onOpenRecoverySettings = { recoveryStep = $0 }
        fixture.coordinator.openRecoverySettings(for: try XCTUnwrap(fixture.coordinator.readiness.nextRequiredStep))
        XCTAssertEqual(recoveryStep, .llm)
        XCTAssertEqual(fixture.coordinator.step, .tryIt)
        XCTAssertFalse(fixture.coordinator.readiness.isReady)
    }

    func testFailedHotkeyDoesNotConfirmOrMoveForward() throws {
        let fixture = try OnboardingTestFixture()
        defer { fixture.cleanup() }
        fixture.coordinator.go(to: .hotkey)
        fixture.coordinator.onApplyHotkey = { _ in .failure("快捷键冲突") }
        XCTAssertFalse(fixture.coordinator.applyHotkey(.default))
        XCTAssertEqual(fixture.coordinator.lastErrorMessage, "快捷键冲突")
        XCTAssertFalse(fixture.store.onboardingProgress.hasConfirmedHotkey)
        fixture.coordinator.goForward()
        XCTAssertEqual(fixture.coordinator.step, .hotkey)
    }

    func testClosingWindowRestoresSuspendedHotkeyCapture() throws {
        let fixture = try OnboardingTestFixture()
        defer { fixture.cleanup() }
        var suspensions: [Bool] = []
        fixture.coordinator.onHotkeyCaptureSuspended = { suspensions.append($0) }
        fixture.coordinator.setHotkeyCaptureSuspended(true)
        fixture.coordinator.dismissed()
        XCTAssertEqual(suspensions, [true, false])
    }
}
