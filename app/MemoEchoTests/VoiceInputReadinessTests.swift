import XCTest
@testable import MemoEcho

final class VoiceInputReadinessTests: XCTestCase {
    func testMenuBlockerUsesConfirmedStatesAndSelectsRelevantSettings() {
        var readiness = VoiceInputReadiness(hotkey: .ready, microphone: .ready,
                                           accessibility: .pending("unchecked"), asr: .pending("checking"), llm: .ready)
        XCTAssertNil(readiness.confirmedBlockerTab)
        readiness.llm = .blocked("missing")
        XCTAssertEqual(readiness.confirmedBlockerTab, .ai)
        readiness.llm = .ready
        readiness.accessibility = .blocked("denied")
        XCTAssertEqual(readiness.confirmedBlockerTab, .permissions)
        readiness.asr = .blocked("missing")
        XCTAssertEqual(readiness.confirmedBlockerTab, .asr)
    }

    func testEveryCombinationRoutesToFirstRequiredStep() {
        for mask in 0..<32 {
            let statuses = (0..<5).map { mask & (1 << $0) != 0 ? ReadinessStatus.ready : .blocked("未就绪") }
            let readiness = VoiceInputReadiness(
                hotkey: statuses[4], microphone: statuses[2], accessibility: statuses[3],
                asr: statuses[0], llm: statuses[1]
            )
            let routes: [SetupStep] = [.asr, .llm, .permissions, .permissions, .hotkey]
            let firstBlocked = statuses.firstIndex { !$0.isReady }
            XCTAssertEqual(readiness.isReady, mask == 31, "mask=\(mask)")
            XCTAssertEqual(readiness.nextRequiredStep, firstBlocked.map { routes[$0] }, "mask=\(mask)")
        }
    }

    func testPendingCannotCompleteReadiness() {
        var snapshot = VoiceInputReadiness(hotkey: .ready, microphone: .ready, accessibility: .ready, asr: .ready, llm: .ready)
        snapshot.asr = .pending("正在下载")
        XCTAssertFalse(snapshot.isReady)
        XCTAssertEqual(snapshot.nextRequiredStep, .asr)
    }

    func testLocalModelFilesAreRequiredEvenIfSavedStatusIsReady() {
        var config = ASRConfig()
        config.local.modelStatus = .ready
        let snapshot = make(asrConfig: config, localModelsAvailable: false)
        XCTAssertFalse(snapshot.asr.isReady)
        XCTAssertEqual(snapshot.nextRequiredStep, .asr)
    }

    func testLocalDownloadStatesAndFilesAreEvaluatedDynamically() {
        var config = ASRConfig()
        for state in [LocalModelStatus.notDownloaded, .downloading, .failed, .ready] {
            config.local.modelStatus = state
            let snapshot = make(asrConfig: config, localModelsAvailable: false)
            XCTAssertFalse(snapshot.isReady)
            if state == .downloading {
                XCTAssertEqual(snapshot.asr, .pending("语音模型正在下载"))
            }
        }
        XCTAssertTrue(make(asrConfig: config, localModelsAvailable: true).asr.isReady)
    }

    func testExistingFilesDoNotCompleteReadinessWhileDownloadIsFinishing() {
        var config = ASRConfig()
        config.local.modelStatus = .downloading
        let snapshot = make(asrConfig: config, localModelsAvailable: true)
        XCTAssertEqual(snapshot.asr, .pending("语音模型正在下载"))
        XCTAssertFalse(snapshot.isReady)
        XCTAssertEqual(snapshot.nextRequiredStep, .asr)
    }

    func testCloudConfigurationMustBeCompleteAndValidated() {
        var config = ASRConfig()
        config.selectedPlatform = .tencentCloudRealtime
        XCTAssertFalse(make(asrConfig: config, cloudStatus: .ready).asr.isReady)
        config.tencentCloud.appID = "123456"
        config.tencentCloud.secretId = "test-id"
        config.tencentCloud.secretKey = "test-key"
        for status in [CloudASRValidationDisplayStatus.incomplete, .checking, .failed] {
            XCTAssertFalse(make(asrConfig: config, cloudStatus: status).asr.isReady)
        }
        XCTAssertTrue(make(asrConfig: config, cloudStatus: .ready).asr.isReady)
    }

    func testEveryMicrophoneDenialAndAccessibilityRevocationBlock() {
        for status in [MicrophonePermission.notDetermined, .denied, .restricted] {
            let snapshot = make(microphone: status)
            XCTAssertFalse(snapshot.microphone.isReady)
            XCTAssertEqual(snapshot.nextRequiredStep, .permissions)
        }
        XCTAssertFalse(make(accessibility: .requiresManualEnable).accessibility.isReady)
    }

    func testHotkeyNeedsBothSuccessfulRegistrationAndExplicitConfirmation() {
        XCTAssertFalse(make(hotkeyResult: .failure("冲突")).hotkey.isReady)
        XCTAssertFalse(make(hasConfirmedHotkey: false).hotkey.isReady)
        XCTAssertTrue(make().isReady)
    }

    func testLLMCheckingFailureAndMissingConfigurationBlock() {
        for status in [LLMModelStatus.incomplete, .checking, .failed] {
            let snapshot = make(llmStatus: status)
            XCTAssertFalse(snapshot.llm.isReady)
            XCTAssertEqual(snapshot.nextRequiredStep, .llm)
        }
    }

    func testStepOrderAndProgressNumbersMatchOnboarding() {
        XCTAssertEqual(SetupStep.allCases, [.welcome, .asr, .llm, .permissions, .hotkey, .tryIt])
        XCTAssertNil(SetupStep.welcome.number)
        XCTAssertEqual(SetupStep.allCases.compactMap(\.number), [1, 2, 3, 4, 5])
    }

    private func make(
        asrConfig: ASRConfig = ASRConfig(),
        localModelsAvailable: Bool = true,
        cloudStatus: CloudASRValidationDisplayStatus = .ready,
        microphone: MicrophonePermission = .granted,
        accessibility: AccessibilityPermission = .granted,
        hotkeyResult: HotkeyRegistrationResult = .success,
        hasConfirmedHotkey: Bool = true,
        llmStatus: LLMModelStatus = .ready
    ) -> VoiceInputReadiness {
        VoiceInputReadiness.make(
            hotkeyResult: hotkeyResult, hasConfirmedHotkey: hasConfirmedHotkey,
            microphone: microphone, accessibility: accessibility, asrConfig: asrConfig,
            localModelsAvailable: localModelsAvailable, cloudStatus: cloudStatus, llmStatus: llmStatus
        )
    }
}
