import Foundation
import XCTest
@testable import MemoEcho

final class ConfigStoreTests: XCTestCase {
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

    @MainActor
    func testFreshConfigurationUsesCurrentDefaults() throws {
        let store = ConfigStore(configDirectory: tempDirectory)
        XCTAssertEqual(store.generalConfig.hotkey, .default)
        XCTAssertTrue(store.requiresInitialSetup)
        XCTAssertTrue(store.audioInputConfig.usesSystemDefault)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent("config.json").path))
    }

    @MainActor
    func testIncompleteConfigurationIsReportedForRepair() throws {
        let configURL = tempDirectory.appendingPathComponent("config.json")
        let incomplete = Data(#"{"general":{"hotkey":{"keyCode":49,"modifiers":0,"displayString":"Space"}}}"#.utf8)
        try incomplete.write(to: configURL)
        let store = ConfigStore(configDirectory: tempDirectory)
        XCTAssertTrue(store.configLoadFailed)
        XCTAssertTrue(store.canOpenSettings)
        XCTAssertEqual(try Data(contentsOf: configURL), incomplete)
    }

    @MainActor
    func testDraftProgressResumesAndCorruptExistingFileOpensSettingsForRepair() throws {
        let store = ConfigStore(configDirectory: tempDirectory)
        try store.saveOnboardingProgress(.init(lastVisitedStep: .llm))
        let draft = ConfigStore(configDirectory: tempDirectory)
        XCTAssertTrue(draft.requiresInitialSetup)
        XCTAssertFalse(draft.canOpenSettings)
        XCTAssertEqual(draft.onboardingProgress.lastVisitedStep, .llm)

        let configURL = tempDirectory.appendingPathComponent("config.json")
        let damaged = Data("{invalid".utf8)
        try damaged.write(to: configURL)
        let corrupt = ConfigStore(configDirectory: tempDirectory)
        XCTAssertTrue(corrupt.configLoadFailed)
        XCTAssertFalse(corrupt.requiresInitialSetup)
        XCTAssertTrue(corrupt.canOpenSettings)
        XCTAssertEqual(try Data(contentsOf: configURL), damaged)
    }

    @MainActor
    func testOnboardingProgressSurvivesAllConfigurationSaves() throws {
        let store = ConfigStore(configDirectory: tempDirectory)
        let progress = OnboardingProgress(lastVisitedStep: .tryIt, hasFinishedPresentation: true,
                                          hasConfirmedHotkey: true, hasAttemptedAccessibilityDrag: true)
        try store.saveOnboardingProgress(progress)
        try store.saveLLMConfig(LLMConfig(baseURL: "https://example.com/v1", model: "test-model"), apiKey: "test-key")
        try store.saveGeneralConfig(store.generalConfig)
        try store.saveASRConfig(store.asrConfig)
        try store.saveAudioInputConfig(.systemDefault)

        let restored = ConfigStore(configDirectory: tempDirectory)
        XCTAssertEqual(restored.onboardingProgress, progress)
        XCTAssertTrue(restored.hasCompletedInitialSetup)
    }

    @MainActor
    func testAccessibilityDragAttemptPersistsWithoutCompletingOnboarding() throws {
        let store = ConfigStore(configDirectory: tempDirectory)

        var progress = store.onboardingProgress
        progress.hasAttemptedAccessibilityDrag = true
        try store.saveOnboardingProgress(progress)

        let restored = ConfigStore(configDirectory: tempDirectory)
        XCTAssertTrue(restored.onboardingProgress.hasAttemptedAccessibilityDrag)
        XCTAssertFalse(restored.hasCompletedInitialSetup)
    }

    @MainActor
    func testGeneralConfigAndHotkeyConfirmationAreSavedTogether() throws {
        let store = ConfigStore(configDirectory: tempDirectory)
        let progress = OnboardingProgress(lastVisitedStep: .hotkey)
        try store.saveOnboardingProgress(progress)
        var config = store.generalConfig
        config.hotkey = .special(modifiers: [HotkeyModifierSpec(key: .command, side: .right)])
        try store.saveGeneralConfig(config, confirmingHotkey: true)

        XCTAssertEqual(store.generalConfig, config)
        XCTAssertTrue(store.onboardingProgress.hasConfirmedHotkey)
        XCTAssertEqual(store.onboardingProgress.lastVisitedStep, .hotkey)
        XCTAssertFalse(store.onboardingProgress.hasFinishedPresentation)
        let restored = ConfigStore(configDirectory: tempDirectory)
        XCTAssertEqual(restored.generalConfig, config)
        XCTAssertEqual(restored.onboardingProgress, store.onboardingProgress)

        try store.saveGeneralConfig(config)
        XCTAssertTrue(store.onboardingProgress.hasConfirmedHotkey)
    }

    @MainActor
    func testFailedGeneralConfigSaveChangesNeitherHotkeyNorConfirmation() throws {
        let store = ConfigStore(configDirectory: tempDirectory)
        let originalConfig = store.generalConfig
        let originalProgress = store.onboardingProgress
        var config = originalConfig
        config.hotkey = .special(modifiers: [HotkeyModifierSpec(key: .command, side: .right)])
        let configURL = tempDirectory.appendingPathComponent("config.json")
        try FileManager.default.removeItem(at: configURL)
        try FileManager.default.createDirectory(at: configURL, withIntermediateDirectories: false)

        XCTAssertThrowsError(try store.saveGeneralConfig(config, confirmingHotkey: true))
        XCTAssertEqual(store.generalConfig, originalConfig)
        XCTAssertEqual(store.onboardingProgress, originalProgress)
    }

    @MainActor
    func testFailedProgressSaveDoesNotUpdateInMemoryCompletion() throws {
        let store = ConfigStore(configDirectory: tempDirectory)
        let configURL = tempDirectory.appendingPathComponent("config.json")
        try FileManager.default.removeItem(at: configURL)
        try FileManager.default.createDirectory(at: configURL, withIntermediateDirectories: false)

        XCTAssertThrowsError(try store.saveOnboardingProgress(
            OnboardingProgress(lastVisitedStep: .tryIt, hasFinishedPresentation: true, hasConfirmedHotkey: true)
        ))
        XCTAssertEqual(store.onboardingProgress, OnboardingProgress())
        XCTAssertFalse(store.hasCompletedInitialSetup)
    }

    @MainActor
    func testSaveAndReloadNewCloudASRConfig() throws {
        let firstStore = ConfigStore(configDirectory: tempDirectory)
        var asrConfig = firstStore.asrConfig
        asrConfig.selectedPlatform = .volcengineSentence
        asrConfig.volcengine.apiKey = "volc-key"
        asrConfig.aliyun.accessKeyId = "ak"
        asrConfig.aliyun.accessKeySecret = "secret"
        asrConfig.aliyun.appKey = "app"
        asrConfig.xiaomiMiMo.apiKey = "mimo-key"
        asrConfig.xiaomiMiMoTokenPlan.apiKey = "token-plan-key"
        try firstStore.saveASRConfig(asrConfig)
        try firstStore.updateCloudValidationState(for: .volcengineSentence, status: .verified)
        try firstStore.updateCloudValidationState(for: .xiaomiMiMoASR, status: .verified)
        try firstStore.updateCloudValidationState(for: .xiaomiMiMoTokenPlanASR, status: .verified)

        let secondStore = ConfigStore(configDirectory: tempDirectory)
        XCTAssertEqual(secondStore.asrConfig.selectedPlatform, .volcengineSentence)
        XCTAssertEqual(secondStore.asrConfig.volcengine.apiKey, "volc-key")
        XCTAssertEqual(secondStore.asrConfig.volcengine.validationStatus, .verified)
        XCTAssertEqual(secondStore.asrConfig.aliyun.accessKeyId, "ak")
        XCTAssertEqual(secondStore.asrConfig.aliyun.accessKeySecret, "secret")
        XCTAssertEqual(secondStore.asrConfig.aliyun.appKey, "app")
        XCTAssertEqual(secondStore.asrConfig.xiaomiMiMo.apiKey, "mimo-key")
        XCTAssertEqual(secondStore.asrConfig.xiaomiMiMo.validationStatus, .verified)
        XCTAssertEqual(secondStore.asrConfig.xiaomiMiMoTokenPlan.apiKey, "token-plan-key")
        XCTAssertEqual(secondStore.asrConfig.xiaomiMiMoTokenPlan.validationStatus, .verified)
    }

    @MainActor
    func testChangingCloudCredentialsInvalidatesValidationState() throws {
        let store = ConfigStore(configDirectory: tempDirectory)
        var asrConfig = store.asrConfig
        asrConfig.selectedPlatform = .tencentCloudSentence
        asrConfig.tencentCloud.secretId = "secret-id"
        asrConfig.tencentCloud.secretKey = "secret-key"
        try store.saveASRConfig(asrConfig)
        try store.updateCloudValidationState(for: .tencentCloudSentence, status: .verified)

        var changedConfig = store.asrConfig
        changedConfig.tencentCloud.secretKey = "new-secret-key"
        try store.saveASRConfig(changedConfig)

        XCTAssertEqual(store.asrConfig.tencentCloud.validationStatus, .unvalidated)
        XCTAssertNil(store.asrConfig.tencentCloud.lastValidationError)
    }

    @MainActor
    func testSaveAndReloadGeneralConfigPersistsInteractionSoundEnabled() throws {
        let firstStore = ConfigStore(configDirectory: tempDirectory)
        let config = GeneralConfig(
            hotkey: .default,
            interactionSoundEnabled: false
        )
        try firstStore.saveGeneralConfig(config)

        let secondStore = ConfigStore(configDirectory: tempDirectory)
        XCTAssertFalse(secondStore.generalConfig.interactionSoundEnabled)
    }

    @MainActor
    func testSaveAndReloadSpecialHotkeyConfig() throws {
        let firstStore = ConfigStore(configDirectory: tempDirectory)
        let specialHotkey = HotkeyCombo.special(
            modifiers: [
                HotkeyModifierSpec(key: .command, side: .right),
                HotkeyModifierSpec(key: .option, side: .left),
            ]
        )

        try firstStore.saveGeneralConfig(
            GeneralConfig(
                hotkey: specialHotkey,
                interactionSoundEnabled: true
            )
        )

        let secondStore = ConfigStore(configDirectory: tempDirectory)
        XCTAssertEqual(secondStore.generalConfig.hotkey, specialHotkey)
    }

    @MainActor
    func testSaveAndReloadFnHotkeyConfig() throws {
        let firstStore = ConfigStore(configDirectory: tempDirectory)
        let fnHotkey = HotkeyCombo.special(
            modifiers: [HotkeyModifierSpec(key: .function)]
        )

        try firstStore.saveGeneralConfig(
            GeneralConfig(
                hotkey: fnHotkey,
                interactionSoundEnabled: true
            )
        )

        let secondStore = ConfigStore(configDirectory: tempDirectory)
        XCTAssertEqual(secondStore.generalConfig.hotkey, fnHotkey)
        XCTAssertEqual(secondStore.generalConfig.hotkey.displayString, "Fn")
    }

    @MainActor
    func testSaveAndReloadAudioInputConfig() throws {
        let firstStore = ConfigStore(configDirectory: tempDirectory)
        let config = AudioInputConfig(
            selectedDeviceID: "device-1",
            selectedDeviceName: "Studio Display 麦克风"
        )
        try firstStore.saveAudioInputConfig(config)

        let secondStore = ConfigStore(configDirectory: tempDirectory)
        XCTAssertEqual(secondStore.audioInputConfig, config)
    }


}
