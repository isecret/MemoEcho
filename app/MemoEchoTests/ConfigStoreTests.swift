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
    func testWindowContextDefaultsOnAndPersistsOffAcrossOtherSaves() throws {
        let store = ConfigStore(configDirectory: tempDirectory)
        XCTAssertTrue(store.windowContextEnabled)
        try store.saveWindowContextEnabled(false)
        try store.saveGeneralConfig(store.generalConfig)
        try store.saveLLMConfig(.init(baseURL: "https://example.com/v1", model: "test"), apiKey: "synthetic-key")
        let reloaded = ConfigStore(configDirectory: tempDirectory)
        XCTAssertFalse(reloaded.windowContextEnabled)
        XCTAssertFalse(reloaded.configLoadFailed)
        try reloaded.saveWindowContextEnabled(true)
        XCTAssertTrue(ConfigStore(configDirectory: tempDirectory).windowContextEnabled)
    }

    @MainActor
    func testFailedWindowContextSaveKeepsActualSetting() throws {
        let store = ConfigStore(configDirectory: tempDirectory)
        let url = tempDirectory.appendingPathComponent("config.json")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.saveWindowContextEnabled(false))
        XCTAssertTrue(store.windowContextEnabled)
    }

    @MainActor
    func testFreshConfigurationUsesCurrentDefaults() throws {
        let store = ConfigStore(configDirectory: tempDirectory)
        XCTAssertEqual(store.generalConfig.hotkey, .default)
        XCTAssertTrue(store.requiresInitialSetup)
        XCTAssertTrue(store.audioInputConfig.usesAutomaticSelection)
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
        let configURL = tempDirectory.appendingPathComponent("state.json")
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
            selectedDeviceID: "device-1"
        )
        try firstStore.saveAudioInputConfig(config)

        let secondStore = ConfigStore(configDirectory: tempDirectory)
        XCTAssertEqual(secondStore.audioInputConfig, config)
    }

    @MainActor
    func testAudioSelectionModesRemainDistinctAfterReload() throws {
        let store = ConfigStore(configDirectory: tempDirectory)
        for config in [AudioInputConfig.automatic, .systemDefault,
                       .init(selectedDeviceID: "headset")] {
            try store.saveAudioInputConfig(config)
            XCTAssertEqual(ConfigStore(configDirectory: tempDirectory).audioInputConfig, config)
        }
    }


    @MainActor
    func testFilesSeparateSettingsCredentialsAndDurableState() throws {
        let store = ConfigStore(configDirectory: tempDirectory)
        try store.saveLLMConfig(.init(baseURL: "https://example.com/v1", model: "test"), apiKey: "synthetic-llm-secret")
        var asr = store.asrConfig
        asr.tencentCloud.secretId = "synthetic-id"
        asr.tencentCloud.secretKey = "synthetic-asr-secret"
        asr.aliyun.accessKeyId = "partially-filled"
        try store.saveASRConfig(asr)
        let before = try Data(contentsOf: tempDirectory.appendingPathComponent("config.json"))
        try store.saveOnboardingProgress(.init(lastVisitedStep: .llm))
        try store.markThinkingParameterUnsupported(for: store.llmConfig, apiKey: store.openAIAPIKey)
        try store.updateCloudValidationState(for: .tencentCloudSentence, status: .verified)
        store.updateLocalModelStatus(.downloading)
        XCTAssertEqual(try Data(contentsOf: tempDirectory.appendingPathComponent("config.json")), before)
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: before) as? [String: Any])
        XCTAssertEqual(Set(settings.keys), ["general", "llm", "asr", "audio"])
        let providers = try XCTUnwrap(settings["asr"] as? [String: Any])
        XCTAssertEqual(Set(providers.keys), ["selectedPlatform", "tencentCloud", "aliyun"])
        let restored = ConfigStore(configDirectory: tempDirectory)
        XCTAssertEqual(restored.asrConfig.aliyun.accessKeyId, "partially-filled")
        XCTAssertTrue(restored.omitThinkingParameter)
        XCTAssertEqual(restored.asrConfig.tencentCloud.validationStatus, .verified)
        let configText = String(decoding: before, as: UTF8.self)
        for key in ["modelStatus", "validationStatus", "lastError", "onboarding", "thinkingDisabled", "omitThinkingParameter", "launchAtLogin", "selectedDeviceName", "displayString"] {
            XCTAssertFalse(configText.contains("\"\(key)\""), key)
        }
        let stateText = try String(contentsOf: tempDirectory.appendingPathComponent("state.json"), encoding: .utf8)
        XCTAssertFalse(stateText.contains("synthetic-llm-secret"))
        XCTAssertFalse(stateText.contains("synthetic-asr-secret"))
        XCTAssertTrue(configText.contains("synthetic-llm-secret"))
        XCTAssertTrue(configText.contains("synthetic-asr-secret"))
        for name in ["config.json", "state.json"] {
            let attributes = try FileManager.default.attributesOfItem(atPath: tempDirectory.appendingPathComponent(name).path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    @MainActor
    func testTransientDownloadAndValidationStatesDoNotSurviveRestart() throws {
        let store = ConfigStore(configDirectory: tempDirectory)
        var asr = store.asrConfig
        asr.volcengine.apiKey = "synthetic"
        try store.saveASRConfig(asr)
        let configBefore = try Data(contentsOf: tempDirectory.appendingPathComponent("config.json"))
        for status in [CloudASRValidationStatus.validating, .failed] {
            try store.updateCloudValidationState(for: .volcengineSentence, status: .verified)
            try store.updateCloudValidationState(for: .volcengineSentence, status: status, error: "synthetic error")
            store.updateLocalModelStatus(.downloading, error: "synthetic download error")
            let restored = ConfigStore(configDirectory: tempDirectory)
            XCTAssertEqual(restored.asrConfig.volcengine.validationStatus, .unvalidated)
            XCTAssertNil(restored.asrConfig.volcengine.lastValidationError)
            XCTAssertNotEqual(restored.asrConfig.local.modelStatus, .downloading)
            XCTAssertNil(restored.asrConfig.local.lastError)
            XCTAssertEqual(try Data(contentsOf: tempDirectory.appendingPathComponent("config.json")), configBefore)
            let state = try String(contentsOf: tempDirectory.appendingPathComponent("state.json"), encoding: .utf8)
            XCTAssertFalse(state.contains("synthetic error"))
            XCTAssertFalse(state.contains("synthetic download error"))
        }
    }

    @MainActor
    func testCapabilityCacheMatchesCurrentLLMIdentity() throws {
        let store = ConfigStore(configDirectory: tempDirectory)
        let original = LLMConfig(baseURL: "https://example.com/v1", model: "one")
        for (config, key) in [(LLMConfig(baseURL: "https://other.example/v1", model: "one"), "key"),
                              (LLMConfig(baseURL: "https://example.com/v1", model: "two"), "key"),
                              (original, "other-key")] {
            try store.saveLLMConfig(original, apiKey: "key")
            try store.markThinkingParameterUnsupported(for: store.llmConfig, apiKey: store.openAIAPIKey)
            XCTAssertTrue(store.omitThinkingParameter)
            try store.saveLLMConfig(config, apiKey: key)
            XCTAssertFalse(store.omitThinkingParameter)
            XCTAssertFalse(ConfigStore(configDirectory: tempDirectory).omitThinkingParameter)
        }
    }

    @MainActor
    func testExternalCredentialEditCannotReuseCloudVerification() throws {
        let store = ConfigStore(configDirectory: tempDirectory)
        var asr = store.asrConfig
        asr.volcengine.apiKey = "original"
        try store.saveASRConfig(asr)
        try store.updateCloudValidationState(for: .volcengineSentence, status: .verified)
        let url = tempDirectory.appendingPathComponent("config.json")
        var json = try String(contentsOf: url, encoding: .utf8)
        json = json.replacingOccurrences(of: "original", with: "different")
        try Data(json.utf8).write(to: url)
        let restored = ConfigStore(configDirectory: tempDirectory)
        XCTAssertFalse(restored.configLoadFailed)
        XCTAssertEqual(restored.asrConfig.volcengine.validationStatus, .unvalidated)
    }

    @MainActor
    func testCorruptStatePreservesCredentialsAndSettings() throws {
        let store = ConfigStore(configDirectory: tempDirectory)
        try store.saveLLMConfig(.init(baseURL: "https://example.com/v1", model: "one"), apiKey: "synthetic")
        try store.saveWindowContextEnabled(false)
        let url = tempDirectory.appendingPathComponent("config.json")
        let before = try Data(contentsOf: url)
        try Data("{invalid".utf8).write(to: tempDirectory.appendingPathComponent("state.json"))
        let restored = ConfigStore(configDirectory: tempDirectory)
        XCTAssertFalse(restored.configLoadFailed)
        XCTAssertEqual(restored.openAIAPIKey, "synthetic")
        XCTAssertFalse(restored.windowContextEnabled)
        XCTAssertFalse(restored.omitThinkingParameter)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    @MainActor
    func testDeletingConfigResetsExistingOnboardingAndCapabilityState() throws {
        let store = ConfigStore(configDirectory: tempDirectory)
        try store.saveLLMConfig(.init(baseURL: "https://example.com/v1", model: "one"), apiKey: "synthetic")
        try store.markThinkingParameterUnsupported(for: store.llmConfig, apiKey: store.openAIAPIKey)
        try store.saveOnboardingProgress(.init(lastVisitedStep: .tryIt, hasFinishedPresentation: true, hasConfirmedHotkey: true))
        try FileManager.default.removeItem(at: tempDirectory.appendingPathComponent("config.json"))
        let restored = ConfigStore(configDirectory: tempDirectory)
        XCTAssertFalse(restored.configLoadFailed)
        XCTAssertTrue(restored.requiresInitialSetup)
        XCTAssertEqual(restored.onboardingProgress, OnboardingProgress())
        XCTAssertFalse(restored.omitThinkingParameter)
        XCTAssertTrue(restored.openAIAPIKey.isEmpty)
    }

    @MainActor
    func testFailedStateWriteRollsBackChangedHotkey() throws {
        let store = ConfigStore(configDirectory: tempDirectory)
        try store.saveGeneralConfig(store.generalConfig, confirmingHotkey: true)
        let url = tempDirectory.appendingPathComponent("state.json")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        var changed = store.generalConfig
        changed.hotkey = .special(modifiers: [.init(key: .option, side: .right)])
        XCTAssertThrowsError(try store.saveGeneralConfig(changed, confirmingHotkey: true))
        XCTAssertEqual(store.generalConfig.hotkey, .default)
        XCTAssertTrue(store.onboardingProgress.hasConfirmedHotkey)
        let restored = ConfigStore(configDirectory: tempDirectory)
        XCTAssertEqual(restored.generalConfig.hotkey, .default)
        XCTAssertFalse(restored.onboardingProgress.hasConfirmedHotkey)
    }

    @MainActor
    func testTransientStateStillUpdatesWhenConfigIsNotWritable() throws {
        let store = ConfigStore(configDirectory: tempDirectory)
        let url = tempDirectory.appendingPathComponent("config.json")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        store.updateLocalModelStatus(.failed, error: "download failed")
        try store.updateCloudValidationState(for: .volcengineSentence, status: .validating)
        try store.saveOnboardingProgress(.init(lastVisitedStep: .llm))
        XCTAssertEqual(store.asrConfig.local.modelStatus, .failed)
        XCTAssertEqual(store.asrConfig.volcengine.validationStatus, .validating)
        XCTAssertEqual(store.onboardingProgress.lastVisitedStep, .llm)
    }
    @MainActor
    func testLateCapabilityResultCannotChangeNewConfiguration() throws {
        let store = ConfigStore(configDirectory: tempDirectory)
        let old = LLMConfig(baseURL: "https://example.com/v1", model: "old-model")
        try store.saveLLMConfig(old, apiKey: "old-key")
        try store.saveLLMConfig(.init(baseURL: "https://example.com/v1", model: "new-model"), apiKey: "new-key")
        try store.markThinkingParameterUnsupported(for: old, apiKey: "old-key")
        XCTAssertFalse(store.omitThinkingParameter)
        XCTAssertFalse(ConfigStore(configDirectory: tempDirectory).omitThinkingParameter)
    }
}
