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
    func testLegacyVolcengineFileConfigurationAndSuccessRecordSurviveReload() throws {
        let initial = ConfigStore(configDirectory: tempDirectory)
        try initial.saveLLMConfig(.init(baseURL: "https://example.com/v1", model: "synthetic-model"), apiKey: "synthetic-llm")
        let configURL = tempDirectory.appendingPathComponent("config.json")
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any])
        root["asr"] = ["selectedPlatform": "volcengineSentence", "volcengine": ["apiKey": "synthetic-file-key"]]
        let legacyData = try JSONSerialization.data(withJSONObject: root)
        try legacyData.write(to: configURL)
        let state = AppStateStore(directory: tempDirectory)
        var value = state.value
        value.verifiedCloudConfigurations["volcengineSentence"] = AppStateStore.fingerprint("volcengineSentence\nsynthetic-file-key")
        try state.save(value)

        let store = ConfigStore(configDirectory: tempDirectory)
        XCTAssertFalse(store.configLoadFailed)
        XCTAssertEqual(try Data(contentsOf: configURL), legacyData, "Loading must not rewrite historical settings")
        XCTAssertEqual(store.asrConfig.selectedPlatform, .volcengineSentence)
        XCTAssertEqual(store.asrConfig.volcengine.apiKey, "synthetic-file-key")
        XCTAssertEqual(store.asrConfig.volcengine.fileValidationStatus, .verified)
        XCTAssertEqual(store.asrConfig.volcengine.validationStatus, .unvalidated)
        XCTAssertEqual(store.openAIAPIKey, "synthetic-llm")
        XCTAssertTrue(store.isASRReady)
        try store.saveASRConfig(store.asrConfig)
        let reloaded = ConfigStore(configDirectory: tempDirectory)
        XCTAssertFalse(reloaded.configLoadFailed)
        XCTAssertEqual(reloaded.asrConfig.selectedPlatform, .volcengineSentence)
        XCTAssertEqual(reloaded.asrConfig.volcengine.apiKey, "synthetic-file-key")
        XCTAssertEqual(reloaded.openAIAPIKey, "synthetic-llm")
        XCTAssertEqual(reloaded.llmConfig.model, "synthetic-model")
        XCTAssertTrue(reloaded.isASRReady)
    }

    @MainActor
    func testVolcengineModelVersionDoesNotInvalidateFileButKeyInvalidatesAllThree() throws {
        let store = ConfigStore(configDirectory: tempDirectory)
        var config = store.asrConfig
        config.volcengine.apiKey = "synthetic-key"
        config.volcengine.modelVersion = .v1
        config.selectedPlatform = .volcengineSentence
        try store.saveASRConfig(config)
        for platform in [ASRPlatform.volcengineSentence, .volcengineRealtime, .volcengineBigModelSentence] {
            try store.updateCloudValidationState(for: platform, status: .verified)
        }
        config = store.asrConfig
        config.volcengine.modelVersion = .v2
        try store.saveASRConfig(config)
        XCTAssertEqual(store.asrConfig.volcengine.fileValidationStatus, .verified)
        XCTAssertEqual(store.asrConfig.volcengine.validationStatus, .unvalidated)
        XCTAssertEqual(store.asrConfig.volcengine.bigModelSentenceValidationStatus, .unvalidated)
        XCTAssertTrue(ConfigStore(configDirectory: tempDirectory).isASRReady)

        for platform in [ASRPlatform.volcengineRealtime, .volcengineBigModelSentence] {
            try store.updateCloudValidationState(for: platform, status: .verified)
        }
        config = store.asrConfig
        config.volcengine.apiKey = "replacement-key"
        try store.saveASRConfig(config)
        XCTAssertEqual(store.asrConfig.volcengine.fileValidationStatus, .unvalidated)
        XCTAssertEqual(store.asrConfig.volcengine.validationStatus, .unvalidated)
        XCTAssertEqual(store.asrConfig.volcengine.bigModelSentenceValidationStatus, .unvalidated)
        XCTAssertFalse(ConfigStore(configDirectory: tempDirectory).isASRReady)
    }

    @MainActor
    func testVolcengineFileVerificationNeverMarksWebSocketProductsReady() throws {
        let store = ConfigStore(configDirectory: tempDirectory)
        var config = store.asrConfig
        config.volcengine.apiKey = "synthetic-key"
        config.selectedPlatform = .volcengineSentence
        try store.saveASRConfig(config)
        try store.updateCloudValidationState(for: .volcengineSentence, status: .failed, error: "synthetic-error")
        XCTAssertEqual(store.asrConfig.volcengine.fileLastValidationError, "synthetic-error")
        XCTAssertNil(store.asrConfig.volcengine.lastValidationError)
        try store.updateCloudValidationState(for: .volcengineSentence, status: .verified)
        let reloaded = ConfigStore(configDirectory: tempDirectory)
        XCTAssertTrue(reloaded.asrConfig.volcengine.fileState.isReady)
        XCTAssertFalse(reloaded.asrConfig.volcengine.isReady)
        XCTAssertFalse(reloaded.asrConfig.volcengine.bigModelSentenceState.isReady)
    }

    @MainActor
    func testLegacySentenceSelectionPreservesIATCredentialsButRequiresRealtimeValidation() throws {
        _ = ConfigStore(configDirectory: tempDirectory)
        let configURL = tempDirectory.appendingPathComponent("config.json")
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any])
        root["asr"] = ["selectedPlatform": "xunfeiSentence", "xunfei": ["appID": "synthetic-app", "apiKey": "synthetic-iat", "apiSecret": "synthetic-secret", "realtimeAPIKey": "synthetic-rtasr"]]
        try JSONSerialization.data(withJSONObject: root).write(to: configURL)
        let store = ConfigStore(configDirectory: tempDirectory)
        XCTAssertFalse(store.configLoadFailed)
        XCTAssertEqual(store.asrConfig.selectedPlatform, .xunfeiIAT)
        XCTAssertEqual(store.asrConfig.xunfei.apiKey, "synthetic-iat")
        XCTAssertEqual(store.asrConfig.xunfei.apiSecret, "synthetic-secret")
        XCTAssertEqual(store.asrConfig.xunfei.realtimeAPIKey, "synthetic-rtasr")
        XCTAssertFalse(store.isASRReady)
        try store.updateCloudValidationState(for: .xunfeiIAT, status: .verified)
        try store.saveASRConfig(store.asrConfig)
        let reloaded = ConfigStore(configDirectory: tempDirectory)
        XCTAssertEqual(reloaded.asrConfig.selectedPlatform, .xunfeiIAT)
        XCTAssertTrue(reloaded.isASRReady)
        XCTAssertEqual(reloaded.asrConfig.xunfei.validationStatus, .unvalidated)
    }

    @MainActor
    func testBailianHTTPAndRealtimeConfigurationsPersistSeparately() throws {
        let store = ConfigStore(configDirectory: tempDirectory)
        var config = store.asrConfig
        config.selectedPlatform = .aliyunBailianHTTPASR
        config.aliyunBailianHTTP = .init(baseURL: "https://example.com/api/v1", apiKey: "synthetic-http", model: "custom-http-model")
        config.aliyunBailian = .init(baseURL: "wss://example.com/api-ws/v1/inference", apiKey: "synthetic-wss", model: "custom-realtime-model")
        try store.saveASRConfig(config)
        try store.updateCloudValidationState(for: .aliyunBailianHTTPASR, status: .verified)
        XCTAssertEqual(store.asrConfig.aliyunBailian.validationStatus, .unvalidated)
        try store.updateCloudValidationState(for: .aliyunBailianASR, status: .verified)
        let restored = ConfigStore(configDirectory: tempDirectory)
        XCTAssertEqual(restored.asrConfig.selectedPlatform, .aliyunBailianHTTPASR)
        XCTAssertEqual(restored.asrConfig.aliyunBailianHTTP.model, "custom-http-model")
        XCTAssertEqual(restored.asrConfig.aliyunBailian.model, "custom-realtime-model")
        XCTAssertTrue(restored.isASRReady)
        var edited = restored.asrConfig
        edited.aliyunBailianHTTP.model = "changed-http-model"
        try restored.saveASRConfig(edited)
        XCTAssertEqual(restored.asrConfig.aliyunBailianHTTP.validationStatus, .unvalidated)
        XCTAssertEqual(restored.asrConfig.aliyunBailian.validationStatus, .verified)
        XCTAssertEqual(ConfigStore(configDirectory: tempDirectory).asrConfig.aliyunBailian.validationStatus, .verified)
    }

    @MainActor
    func testSentenceAndRealtimeValidationPersistIndependently() throws {
        let store = ConfigStore(configDirectory: tempDirectory)
        var config = store.asrConfig
        config.tencentCloud.appID = "synthetic-app"
        config.tencentCloud.secretId = "synthetic-id"
        config.tencentCloud.secretKey = "synthetic-key"
        config.selectedPlatform = .tencentCloudSentence
        try store.saveASRConfig(config)
        try store.updateCloudValidationState(for: .tencentCloudSentence, status: .verified)
        XCTAssertEqual(store.asrConfig.tencentCloud.validationStatus, .unvalidated)
        try store.updateCloudValidationState(for: .tencentCloudRealtime, status: .verified)

        let restored = ConfigStore(configDirectory: tempDirectory)
        XCTAssertEqual(restored.asrConfig.selectedPlatform, .tencentCloudSentence)
        XCTAssertEqual(restored.asrConfig.tencentCloud.sentenceValidationStatus, .verified)
        XCTAssertEqual(restored.asrConfig.tencentCloud.validationStatus, .verified)
        var edited = restored.asrConfig
        edited.tencentCloud.appID = "changed-realtime-app"
        try restored.saveASRConfig(edited)
        XCTAssertEqual(restored.asrConfig.tencentCloud.sentenceValidationStatus, .verified)
        XCTAssertEqual(restored.asrConfig.tencentCloud.validationStatus, .unvalidated)
        edited = restored.asrConfig
        edited.tencentCloud.secretKey = "changed-shared-key"
        try restored.saveASRConfig(edited)
        XCTAssertEqual(restored.asrConfig.tencentCloud.sentenceValidationStatus, .unvalidated)
        XCTAssertEqual(ConfigStore(configDirectory: tempDirectory).asrConfig.tencentCloud.sentenceValidationStatus, .unvalidated)
    }

    @MainActor
    func testEditingIATCredentialsDoesNotInvalidateRTASR() throws {
        let store = ConfigStore(configDirectory: tempDirectory)
        var config = store.asrConfig
        config.xunfei.appID = "synthetic-app"
        config.xunfei.apiKey = "synthetic-iat"
        config.xunfei.apiSecret = "synthetic-secret"
        config.xunfei.realtimeAPIKey = "synthetic-rtasr"
        try store.saveASRConfig(config)
        try store.updateCloudValidationState(for: .xunfeiIAT, status: .verified)
        try store.updateCloudValidationState(for: .xunfeiRealtime, status: .verified)
        config = store.asrConfig
        config.xunfei.apiKey = "changed-iat-key"
        try store.saveASRConfig(config)
        XCTAssertEqual(store.asrConfig.xunfei.iatValidationStatus, .unvalidated)
        XCTAssertEqual(store.asrConfig.xunfei.validationStatus, .verified)
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
        asrConfig.selectedPlatform = .volcengineRealtime
        asrConfig.volcengine.apiKey = "volc-key"
        asrConfig.aliyun.accessKeyId = "ak"
        asrConfig.aliyun.accessKeySecret = "secret"
        asrConfig.aliyun.appKey = "app"
        asrConfig.openAICompatible = .init(baseURL: "http://localhost:8000/v1", model: "asr")
        try firstStore.saveASRConfig(asrConfig)
        try firstStore.updateCloudValidationState(for: .volcengineRealtime, status: .verified)
        try firstStore.updateCloudValidationState(for: .openAICompatibleASR, status: .verified)

        let secondStore = ConfigStore(configDirectory: tempDirectory)
        XCTAssertEqual(secondStore.asrConfig.selectedPlatform, .volcengineRealtime)
        XCTAssertEqual(secondStore.asrConfig.volcengine.apiKey, "volc-key")
        XCTAssertEqual(secondStore.asrConfig.volcengine.validationStatus, .verified)
        XCTAssertEqual(secondStore.asrConfig.aliyun.accessKeyId, "ak")
        XCTAssertEqual(secondStore.asrConfig.aliyun.accessKeySecret, "secret")
        XCTAssertEqual(secondStore.asrConfig.aliyun.appKey, "app")
        XCTAssertEqual(secondStore.asrConfig.openAICompatible.model, "asr")
        XCTAssertEqual(secondStore.asrConfig.openAICompatible.apiKey, "")
        XCTAssertEqual(secondStore.asrConfig.openAICompatible.validationStatus, .verified)
    }

    @MainActor
    func testChangingCloudCredentialsInvalidatesValidationState() throws {
        let store = ConfigStore(configDirectory: tempDirectory)
        var asrConfig = store.asrConfig
        asrConfig.selectedPlatform = .tencentCloudRealtime
        asrConfig.tencentCloud.appID = "123456"
        asrConfig.tencentCloud.secretId = "secret-id"
        asrConfig.tencentCloud.secretKey = "secret-key"
        try store.saveASRConfig(asrConfig)
        try store.updateCloudValidationState(for: .tencentCloudRealtime, status: .verified)

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
    func testRealtimeCredentialChangesInvalidateOnlyTheirVerification() throws {
        let store = ConfigStore(configDirectory: tempDirectory)
        var asr = store.asrConfig
        asr.tencentCloud.appID = "123456"
        asr.tencentCloud.secretId = "synthetic-id"
        asr.tencentCloud.secretKey = "synthetic-secret"
        asr.xunfei.appID = "synthetic-app"
        asr.xunfei.realtimeAPIKey = "synthetic-rtasr-key"
        asr.mimo.apiKey = "synthetic-mimo-key"
        try store.saveASRConfig(asr)
        for platform in [ASRPlatform.tencentCloudRealtime, .xunfeiRealtime, .mimoASR] {
            try store.updateCloudValidationState(for: platform, status: .verified)
        }
        var edited = store.asrConfig
        edited.tencentCloud.appID = "654321"
        try store.saveASRConfig(edited)
        XCTAssertEqual(store.asrConfig.tencentCloud.validationStatus, .unvalidated)
        XCTAssertEqual(store.asrConfig.xunfei.validationStatus, .verified)
        XCTAssertEqual(store.asrConfig.mimo.validationStatus, .verified)
        edited = store.asrConfig
        edited.xunfei.realtimeAPIKey = "changed-rtasr-key"
        try store.saveASRConfig(edited)
        XCTAssertEqual(store.asrConfig.xunfei.validationStatus, .unvalidated)
        XCTAssertEqual(store.asrConfig.mimo.validationStatus, .verified)
        let restored = ConfigStore(configDirectory: tempDirectory)
        XCTAssertEqual(restored.asrConfig.tencentCloud.validationStatus, .unvalidated)
        XCTAssertEqual(restored.asrConfig.xunfei.validationStatus, .unvalidated)
        XCTAssertEqual(restored.asrConfig.mimo.validationStatus, .verified)
    }

    @MainActor
    func testMiMoConnectionEditsInvalidateIndependentVerification() throws {
        let store = ConfigStore(configDirectory: tempDirectory)
        var asr = store.asrConfig
        asr.selectedPlatform = .mimoASR
        asr.mimo.apiKey = "synthetic-key"
        asr.openAICompatible = .init(baseURL: "http://localhost:8000/v1", model: "asr")
        try store.saveASRConfig(asr)
        try store.updateCloudValidationState(for: .openAICompatibleASR, status: .verified)
        for field in ["baseURL", "apiKey", "model"] {
            var reset = store.asrConfig
            reset.mimo = .init(apiKey: "synthetic-key")
            try store.saveASRConfig(reset)
            try store.updateCloudValidationState(for: .mimoASR, status: .verified)
            XCTAssertTrue(ConfigStore(configDirectory: tempDirectory).isASRReady)
            var edited = store.asrConfig
            switch field {
            case "baseURL": edited.mimo.baseURL = "https://other.example/v1"
            case "apiKey": edited.mimo.apiKey = "other-key"
            default: edited.mimo.model = "other-model"
            }
            try store.saveASRConfig(edited)
            XCTAssertEqual(store.asrConfig.mimo.validationStatus, .unvalidated)
            XCTAssertEqual(store.asrConfig.openAICompatible.validationStatus, .verified)
            XCTAssertFalse(ConfigStore(configDirectory: tempDirectory).isASRReady)
        }
    }

    @MainActor
    func testVolcengineModelChangeInvalidatesBothLargeModelServices() throws {
        let store = ConfigStore(configDirectory: tempDirectory)
        var config = store.asrConfig
        config.volcengine.apiKey = "synthetic-key"
        config.volcengine.modelVersion = .v1
        try store.saveASRConfig(config)
        for platform in [ASRPlatform.volcengineRealtime, .volcengineBigModelSentence] {
            try store.updateCloudValidationState(for: platform, status: .verified)
        }
        config = store.asrConfig
        config.volcengine.modelVersion = .v2
        try store.saveASRConfig(config)
        XCTAssertEqual(store.asrConfig.volcengine.validationStatus, .unvalidated)
        XCTAssertEqual(store.asrConfig.volcengine.bigModelSentenceValidationStatus, .unvalidated)
        let restored = ConfigStore(configDirectory: tempDirectory)
        XCTAssertEqual(restored.asrConfig.volcengine.modelVersion, .v2)
        XCTAssertEqual(restored.asrConfig.volcengine.validationStatus, .unvalidated)
        XCTAssertEqual(restored.asrConfig.volcengine.bigModelSentenceValidationStatus, .unvalidated)
    }

    @MainActor
    func testTraditionalClusterChangesKeepTheOtherServiceIdentity() throws {
        let store = ConfigStore(configDirectory: tempDirectory)
        var config = store.asrConfig
        config.volcengineTraditional = .init(appID: "app", accessToken: "synthetic-token", sentenceCluster: "short", realtimeCluster: "stream")
        try store.saveASRConfig(config)
        try store.updateCloudValidationState(for: .volcengineTraditionalSentence, status: .verified)
        try store.updateCloudValidationState(for: .volcengineTraditionalRealtime, status: .verified)
        config = store.asrConfig
        let previous = CloudASRValidationInput(platform: .volcengineTraditionalRealtime, asrConfig: store.asrConfig).fingerprint
        let short = CloudASRValidationInput(platform: .volcengineTraditionalSentence, asrConfig: store.asrConfig).fingerprint
        config.volcengineTraditional.sentenceCluster = "other-short"
        try store.saveASRConfig(config)
        XCTAssertEqual(store.asrConfig.volcengineTraditional.sentenceValidationStatus, .unvalidated)
        XCTAssertEqual(store.asrConfig.volcengineTraditional.realtimeValidationStatus, .verified)
        XCTAssertEqual(CloudASRValidationInput(platform: .volcengineTraditionalRealtime, asrConfig: store.asrConfig).fingerprint, previous)
        XCTAssertNotEqual(CloudASRValidationInput(platform: .volcengineTraditionalSentence, asrConfig: store.asrConfig).fingerprint, short)
        let restored = ConfigStore(configDirectory: tempDirectory)
        XCTAssertEqual(restored.asrConfig.volcengineTraditional.sentenceCluster, "other-short")
        XCTAssertEqual(restored.asrConfig.volcengineTraditional.realtimeCluster, "stream")
        XCTAssertEqual(restored.asrConfig.volcengineTraditional.accessToken, "synthetic-token")
    }

    @MainActor
    func testTraditionalSharedCredentialsInvalidateBothProductsOnly() throws {
        for field in ["appID", "accessToken"] {
            let store = ConfigStore(configDirectory: tempDirectory.appendingPathComponent(field))
            var config = store.asrConfig
            config.volcengine.apiKey = "large-model-key"
            config.volcengineTraditional = .init(appID: "app", accessToken: "synthetic-token",
                sentenceCluster: "short", realtimeCluster: "stream")
            try store.saveASRConfig(config)
            for platform in [ASRPlatform.volcengineTraditionalSentence, .volcengineTraditionalRealtime, .volcengineRealtime] {
                try store.updateCloudValidationState(for: platform, status: .verified)
            }
            config = store.asrConfig
            if field == "appID" { config.volcengineTraditional.appID = "other-app" }
            else { config.volcengineTraditional.accessToken = "other-token" }
            try store.saveASRConfig(config)
            XCTAssertEqual(store.asrConfig.volcengineTraditional.sentenceValidationStatus, .unvalidated)
            XCTAssertEqual(store.asrConfig.volcengineTraditional.realtimeValidationStatus, .unvalidated)
            XCTAssertEqual(store.asrConfig.volcengine.validationStatus, .verified)
        }
    }

    @MainActor
    func testFilesSeparateSettingsCredentialsAndDurableState() throws {
        let store = ConfigStore(configDirectory: tempDirectory)
        try store.saveLLMConfig(.init(baseURL: "https://example.com/v1", model: "test"), apiKey: "synthetic-llm-secret")
        var asr = store.asrConfig
        asr.tencentCloud.appID = "123456"
        asr.tencentCloud.secretId = "synthetic-id"
        asr.tencentCloud.secretKey = "synthetic-asr-secret"
        asr.aliyun.accessKeyId = "partially-filled"
        try store.saveASRConfig(asr)
        let before = try Data(contentsOf: tempDirectory.appendingPathComponent("config.json"))
        try store.saveOnboardingProgress(.init(lastVisitedStep: .llm))
        try store.markThinkingParameterUnsupported(for: store.llmConfig, apiKey: store.openAIAPIKey)
        try store.updateCloudValidationState(for: .tencentCloudRealtime, status: .verified)
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
            try store.updateCloudValidationState(for: .volcengineRealtime, status: .verified)
            try store.updateCloudValidationState(for: .volcengineRealtime, status: status, error: "synthetic error")
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
        try store.updateCloudValidationState(for: .volcengineRealtime, status: .verified)
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
        try store.updateCloudValidationState(for: .volcengineRealtime, status: .validating)
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
