import XCTest
@testable import MemoEcho

final class ASRConfigTests: XCTestCase {

    func testRemovedASRPlatformValueIsRejected() {
        XCTAssertThrowsError(try JSONDecoder().decode(ASRPlatform.self, from: Data(#""localFunASR""#.utf8)))
    }
    func testReadinessForEachPlatform() {
        var config = ASRConfig()

        config.selectedPlatform = .localSenseVoice
        XCTAssertFalse(config.isReady(localModelsAvailable: false))
        XCTAssertTrue(config.isReady(localModelsAvailable: true))

        config.selectedPlatform = .tencentCloudRealtime
        config.tencentCloud.appID = "123456"
        config.tencentCloud.secretId = "id"
        config.tencentCloud.secretKey = "key"
        XCTAssertFalse(config.isReady(localModelsAvailable: false))
        config.tencentCloud.validationStatus = .verified
        XCTAssertTrue(config.isReady(localModelsAvailable: false))

        config.selectedPlatform = .aliyunRealtime
        config.aliyun.accessKeyId = "ak"
        config.aliyun.accessKeySecret = "secret"
        config.aliyun.appKey = "app"
        XCTAssertFalse(config.isReady(localModelsAvailable: false))
        config.aliyun.validationStatus = .verified
        XCTAssertTrue(config.isReady(localModelsAvailable: false))

        config.selectedPlatform = .volcengineRealtime
        config.volcengine.apiKey = "api-key"
        XCTAssertFalse(config.isReady(localModelsAvailable: false))
        config.volcengine.validationStatus = .verified
        XCTAssertTrue(config.isReady(localModelsAvailable: false))

        config.selectedPlatform = .xunfeiRealtime
        config.xunfei.appID = "appid"
        config.xunfei.realtimeAPIKey = "api-key"
        config.xunfei.apiSecret = "api-secret"
        XCTAssertFalse(config.isReady(localModelsAvailable: false))
        config.xunfei.validationStatus = .verified
        XCTAssertTrue(config.isReady(localModelsAvailable: false))

        config.selectedPlatform = .openAICompatibleASR
        config.openAICompatible = .init(baseURL: "http://localhost:8000/v1", model: "asr")
        XCTAssertFalse(config.isReady(localModelsAvailable: false))
        config.openAICompatible.validationStatus = .verified
        XCTAssertTrue(config.isReady(localModelsAvailable: false))
    }

    func testSentenceSelectionRemainsSentenceWithoutTrustingUnverifiedCredentials() throws {
        for (old, current) in [("tencentCloudSentence", ASRPlatform.tencentCloudSentence),
                               ("aliyunSentence", .aliyunSentence),
                               ("xunfeiSentence", .xunfeiIAT)] {
            let data = try JSONSerialization.data(withJSONObject: ["selectedPlatform": old])
            let config = try JSONDecoder().decode(ASRConfig.self, from: data)
            XCTAssertEqual(config.selectedPlatform, current)
            XCTAssertFalse(config.isReady(localModelsAvailable: true))
            let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
            XCTAssertEqual(encoded["selectedPlatform"] as? String, current.rawValue)
        }
    }

    func testXunfeiDoesNotUseIATCredentialsForRTASR() throws {
        let data = Data(#"{"selectedPlatform":"xunfeiRealtime","xunfei":{"appID":"app","apiKey":"old-iat-key","apiSecret":"old-secret"}}"#.utf8)
        let config = try JSONDecoder().decode(ASRConfig.self, from: data)
        XCTAssertEqual(config.selectedPlatform, .xunfeiRealtime)
        XCTAssertTrue(config.xunfei.realtimeAPIKey.isEmpty)
        XCTAssertFalse(config.xunfei.isComplete)
        XCTAssertFalse(config.isReady(localModelsAvailable: true))
    }

    func testMiMoDoesNotImportLegacyOrGenericChatCredentials() throws {
        let data = Data(#"{"selectedPlatform":"openAICompatibleASR","openAICompatible":{"apiFormat":"chatCompletions","baseURL":"https://example.com/v1","apiKey":"generic-old-key","model":"asr"},"xiaomiMiMo":{"apiKey":"old-key"}}"#.utf8)
        let config = try JSONDecoder().decode(ASRConfig.self, from: data)
        XCTAssertEqual(config.mimo, MiMoASRConfig())
        XCTAssertFalse(config.isReady(localModelsAvailable: true))
        XCTAssertTrue(config.notReadyReason(localModelsAvailable: true)?.contains("重新配置") ?? false)
    }

    func testNotReadyReasonMatchesPlatform() {
        var config = ASRConfig()

        config.selectedPlatform = .aliyunRealtime
        XCTAssertEqual(
            config.notReadyReason(localModelsAvailable: false),
            "阿里云 ASR 配置不完整，请填写 AccessKey ID、AccessKey Secret 和 AppKey"
        )

        config.aliyun.accessKeyId = "ak"
        config.aliyun.accessKeySecret = "secret"
        config.aliyun.appKey = "app"
        XCTAssertEqual(
            config.notReadyReason(localModelsAvailable: false),
            "阿里云 ASR 尚未通过真实请求验证，请先在设置页完成验证"
        )

        config.selectedPlatform = .volcengineRealtime
        XCTAssertEqual(
            config.notReadyReason(localModelsAvailable: false),
            "火山引擎 ASR 配置不完整，请填写 API Key"
        )

        config.selectedPlatform = .xunfeiRealtime
        XCTAssertEqual(
            config.notReadyReason(localModelsAvailable: false),
            "科大讯飞 ASR 配置不完整，请填写 AppID 和实时转写 RTASR API Key"
        )

        config.selectedPlatform = .openAICompatibleASR
        XCTAssertEqual(config.notReadyReason(localModelsAvailable: false),
                       "OpenAI 兼容 ASR 配置不完整，请填写 Base URL 和 Model，API Key 可选")
    }


    func testRealtimeFactoryRejectsBatchUploadsAndNonRealtimeSessions() async throws {
        let factory = ASRProviderFactory(runtimeManager: SenseVoiceRuntimeManager())
        for platform in ASRPlatform.allCases {
            var config = ASRConfig()
            config.selectedPlatform = platform
            if platform.isRealtime {
                if platform == .aliyunBailianASR { config.aliyunBailian.apiKey = "synthetic-key" }
                config.volcengineTraditional = .init(appID: "synthetic-app", accessToken: "synthetic-token",
                    sentenceCluster: "sentence-cluster", realtimeCluster: "streaming-cluster")
                XCTAssertTrue(try ASRProviderFactory.makeRealtimeSession(for: config) is RealtimeCloudASRSession)
                do {
                    _ = try await factory.makeProvider(for: config).recognize(audioData: Data([1]), timeout: 1)
                    XCTFail("A realtime entry must never upload a completed WAV")
                } catch MemoEchoError.asrPlatformNotReady { }
            } else {
                XCTAssertThrowsError(try ASRProviderFactory.makeRealtimeSession(for: config))
            }
        }
    }

    func testVendorGroupsCoverAllEntriesOnceAndNameProducts() {
        let grouped = ASRVendorGroup.allCases.flatMap(\.platforms)
        XCTAssertEqual(Set(grouped), Set(ASRPlatform.allCases))
        XCTAssertEqual(grouped.count, ASRPlatform.allCases.count)
        XCTAssertEqual(ASRVendorGroup.aliyun.platforms, [.aliyunBailianASR, .aliyunBailianHTTPASR, .aliyunRealtime, .aliyunSentence])
        for platform in [ASRPlatform.tencentCloudSentence, .aliyunSentence] {
            XCTAssertFalse(platform.isRealtime)
        }
        XCTAssertEqual(ASRPlatform.tencentCloudSentence.pickerTitle, "腾讯云 · 一句话识别")
        XCTAssertEqual(ASRPlatform.tencentCloudRealtime.pickerTitle, "腾讯云 · 实时语音识别")
        XCTAssertEqual(ASRPlatform.aliyunBailianHTTPASR.pickerTitle, "阿里云 · 百炼语音识别")
        XCTAssertEqual(ASRPlatform.volcengineRealtime.pickerTitle, "火山引擎 · 大模型流式语音识别")
        XCTAssertEqual(ASRVendorGroup.xunfei.platforms, [.xunfeiRealtime, .xunfeiIAT])
        XCTAssertTrue(ASRPlatform.xunfeiIAT.isRealtime)
        XCTAssertEqual(ASRPlatform.xunfeiIAT.pickerTitle, "科大讯飞 · 语音听写")
        XCTAssertEqual(ASRPlatform.xunfeiRealtime.pickerTitle, "科大讯飞 · 实时语音转写")
    }

    func testVolcengineFiveEntriesKeepStreamingIdentityAndCapabilities() {
        XCTAssertEqual(ASRVendorGroup.volcengine.platforms, [.volcengineRealtime, .volcengineBigModelSentence,
            .volcengineSentence, .volcengineTraditionalRealtime, .volcengineTraditionalSentence])
        XCTAssertEqual(ASRPlatform(rawValue: "volcengineSentence"), .volcengineSentence)
        XCTAssertFalse(ASRPlatform.volcengineSentence.isRealtime)
        XCTAssertEqual(ASRPlatform.volcengineSentence.displayName, "火山引擎 · 录音文件极速版")
        XCTAssertEqual(ASRPlatform(rawValue: "volcengineRealtime"), .volcengineRealtime)
        XCTAssertTrue(ASRPlatform.volcengineBigModelSentence.isRealtime)
        XCTAssertTrue(ASRPlatform.volcengineTraditionalRealtime.isRealtime)
        XCTAssertTrue(ASRPlatform.volcengineTraditionalSentence.isRealtime)
        XCTAssertEqual(ASRPlatform.volcengineBigModelSentence.displayName, "火山引擎 · 大模型一句话识别")
        XCTAssertEqual(ASRPlatform.volcengineTraditionalSentence.displayName, "火山引擎 · 一句话识别")
        XCTAssertEqual(ASRPlatform.volcengineTraditionalRealtime.displayName, "火山引擎 · 流式语音识别")
    }

    func testLegacyVolcengineFileSelectionRemainsFileWithoutMapping() throws {
        let json = #"{"selectedPlatform":"volcengineSentence","volcengine":{"apiKey":"synthetic-key","modelVersion":"1.0"},"tencentCloud":{"secretId":"other-id","secretKey":"other-key"}}"#
        let decoded = try JSONDecoder().decode(ASRConfig.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.selectedPlatform, .volcengineSentence)
        XCTAssertEqual(decoded.volcengine.apiKey, "synthetic-key")
        XCTAssertEqual(decoded.volcengine.modelVersion, .v1)
        XCTAssertEqual(decoded.tencentCloud.secretId, "other-id")
        XCTAssertFalse(decoded.isReady(localModelsAvailable: false))
        XCTAssertFalse(decoded.isReady(localModelsAvailable: true))
        let saved = try JSONEncoder().encode(decoded)
        let restored = try JSONDecoder().decode(ASRConfig.self, from: saved)
        XCTAssertEqual(restored.selectedPlatform, .volcengineSentence)
        XCTAssertEqual(restored.volcengine.apiKey, "synthetic-key")
    }

    func testFileServiceReadinessAndFingerprintAreIndependentOfRealtimeVersion() throws {
        var config = ASRConfig()
        config.selectedPlatform = .volcengineSentence
        config.volcengine.apiKey = "synthetic-key"
        config.volcengine.validationStatus = .verified
        config.volcengine.bigModelSentenceValidationStatus = .verified
        XCTAssertFalse(config.isReady(localModelsAvailable: true))
        config.volcengine.fileValidationStatus = .verified
        XCTAssertTrue(config.isReady(localModelsAvailable: false))
        let identity = CloudASRValidationInput(platform: .volcengineSentence, asrConfig: config).fingerprint
        XCTAssertEqual(identity, "volcengineSentence\nsynthetic-key")
        config.volcengine.modelVersion = .v1
        XCTAssertEqual(CloudASRValidationInput(platform: .volcengineSentence, asrConfig: config).fingerprint, identity)
        XCTAssertThrowsError(try ASRProviderFactory.realtimeConfiguration(for: config))
        let saved = try JSONEncoder().encode(config)
        let restored = try JSONDecoder().decode(ASRConfig.self, from: saved)
        XCTAssertEqual(restored.volcengine.fileValidationStatus, .unvalidated)
    }

    func testVolcengineMissingVersionDefaultsToV2AndRoutesVersion() throws {
        let decoded = try JSONDecoder().decode(VolcengineASRConfig.self, from: Data(#"{"apiKey":"synthetic-key"}"#.utf8))
        XCTAssertEqual(decoded.modelVersion, .v2)
        XCTAssertEqual(decoded.apiKey, "synthetic-key")
        XCTAssertEqual(VolcengineASRConfig().modelVersion, .v2)
        XCTAssertFalse(VolcengineASRConfig().hasUserConfiguration)
        XCTAssertEqual(VolcengineASRModelVersion.allCases, [.v2, .v1])
        let explicitV1 = try JSONDecoder().decode(VolcengineASRConfig.self,
            from: Data(#"{"apiKey":"synthetic-key","modelVersion":"1.0"}"#.utf8))
        XCTAssertEqual(explicitV1.modelVersion, .v1)
        for version in VolcengineASRModelVersion.allCases {
            for platform in [ASRPlatform.volcengineBigModelSentence, .volcengineRealtime] {
                var config = ASRConfig()
                config.selectedPlatform = platform
                config.volcengine = decoded
                config.volcengine.modelVersion = version
                guard case .volcengine(let key, let resource, let mode, _) = try ASRProviderFactory.realtimeConfiguration(for: config) else {
                    return XCTFail("Expected large-model V3 route")
                }
                XCTAssertEqual(key, "synthetic-key")
                XCTAssertEqual(resource, version == .v1 ? "volc.bigasr.sauc.duration" : "volc.seedasr.sauc.duration")
                XCTAssertEqual(mode, platform == .volcengineBigModelSentence ? .sentence : .streaming)
            }
        }
    }

    func testVolcengineLargeModelServicesHaveIndependentReadinessAndFingerprint() {
        var config = ASRConfig()
        config.volcengine.apiKey = "synthetic-key"
        config.volcengine.modelVersion = .v1
        config.volcengine.validationStatus = .verified
        config.selectedPlatform = .volcengineBigModelSentence
        XCTAssertFalse(config.isReady(localModelsAvailable: true))
        config.volcengine.bigModelSentenceValidationStatus = .verified
        XCTAssertTrue(config.isReady(localModelsAvailable: false))
        let streaming = CloudASRValidationInput(platform: .volcengineRealtime, asrConfig: config).fingerprint
        let sentence = CloudASRValidationInput(platform: .volcengineBigModelSentence, asrConfig: config).fingerprint
        XCTAssertNotEqual(streaming, sentence)
        config.volcengine.modelVersion = .v2
        XCTAssertNotEqual(CloudASRValidationInput(platform: .volcengineRealtime, asrConfig: config).fingerprint, streaming)
        XCTAssertNotEqual(CloudASRValidationInput(platform: .volcengineBigModelSentence, asrConfig: config).fingerprint, sentence)
    }

    func testTraditionalConfigPreservesPartialFieldsAndReadinessIsIndependent() throws {
        var config = ASRConfig()
        config.volcengineTraditional = .init(appID: "synthetic-app", accessToken: "synthetic-token", sentenceCluster: "sentence-cluster")
        config.volcengineTraditional.sentenceValidationStatus = .verified
        XCTAssertTrue(config.volcengineTraditional.sentenceState.isComplete)
        XCTAssertTrue(config.volcengineTraditional.realtimeState.isComplete)
        let roundTrip = try JSONDecoder().decode(ASRConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(roundTrip.volcengineTraditional.appID, "synthetic-app")
        XCTAssertEqual(roundTrip.volcengineTraditional.sentenceCluster, "sentence-cluster")
        XCTAssertEqual(roundTrip.volcengineTraditional.normalizedRealtimeCluster, "volcengine_streaming")
        XCTAssertEqual(roundTrip.volcengineTraditional.sentenceValidationStatus, .unvalidated)
        config.selectedPlatform = .volcengineTraditionalSentence
        XCTAssertTrue(config.isReady(localModelsAvailable: false))
        XCTAssertTrue(CloudASRValidationInput(platform: config.selectedPlatform, asrConfig: config).isComplete)
        XCTAssertNil(config.notReadyReason(localModelsAvailable: false))
        config.selectedPlatform = .volcengineTraditionalRealtime
        XCTAssertFalse(config.isReady(localModelsAvailable: true))
        XCTAssertTrue(CloudASRValidationInput(platform: config.selectedPlatform, asrConfig: config).isComplete)
        XCTAssertTrue(config.notReadyReason(localModelsAvailable: true)?.contains("尚未通过真实请求验证") ?? false)
        XCTAssertNoThrow(try ASRProviderFactory.realtimeConfiguration(for: config))
    }

    func testTraditionalCredentialsOnlyConfigurationsResolveProductClusters() throws {
        XCTAssertFalse(VolcengineTraditionalASRConfig().hasUserConfiguration)
        XCTAssertFalse(VolcengineTraditionalASRConfig().sentenceState.isComplete)
        for json in [#"{"appID":"app","accessToken":"synthetic-token"}"#,
                     #"{"appID":"app","accessToken":"synthetic-token","sentenceCluster":"","realtimeCluster":"  "}"#] {
            var config = ASRConfig()
            config.volcengineTraditional = try JSONDecoder().decode(VolcengineTraditionalASRConfig.self, from: Data(json.utf8))
            for platform in [ASRPlatform.volcengineTraditionalSentence, .volcengineTraditionalRealtime] {
                config.selectedPlatform = platform
                XCTAssertTrue(CloudASRValidationInput(platform: platform, asrConfig: config).isComplete)
                guard case .volcengineTraditional(_, _, let cluster, _) = try ASRProviderFactory.realtimeConfiguration(for: config) else {
                    return XCTFail("Expected traditional route")
                }
                XCTAssertEqual(cluster, platform == .volcengineTraditionalSentence ? "volcengine_input" : "volcengine_streaming")
            }
            let encoded = try JSONEncoder().encode(config.volcengineTraditional)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertNil(object["sentenceCluster"])
            XCTAssertNil(object["realtimeCluster"])
        }
    }

    func testTraditionalRoutesUseIndependentClustersAndDoNotBorrowLargeModelKey() throws {
        var config = ASRConfig()
        config.volcengine.apiKey = "large-model-key"
        config.selectedPlatform = .volcengineTraditionalSentence
        XCTAssertThrowsError(try ASRProviderFactory.realtimeConfiguration(for: config))
        config.volcengineTraditional = .init(appID: " synthetic-app ", accessToken: " synthetic-token ",
            sentenceCluster: " sentence-cluster ", realtimeCluster: " realtime-cluster ")
        for platform in [ASRPlatform.volcengineTraditionalSentence, .volcengineTraditionalRealtime] {
            config.selectedPlatform = platform
            guard case .volcengineTraditional(let appID, let token, let cluster, let mode) = try ASRProviderFactory.realtimeConfiguration(for: config) else {
                return XCTFail("Expected traditional V2 route")
            }
            XCTAssertEqual(appID, "synthetic-app")
            XCTAssertEqual(token, "synthetic-token")
            XCTAssertEqual(cluster, platform == .volcengineTraditionalSentence ? "sentence-cluster" : "realtime-cluster")
            XCTAssertEqual(mode, platform == .volcengineTraditionalSentence ? .sentence : .streaming)
        }
        let sentence = CloudASRValidationInput(platform: .volcengineTraditionalSentence, asrConfig: config).fingerprint
        let realtime = CloudASRValidationInput(platform: .volcengineTraditionalRealtime, asrConfig: config).fingerprint
        config.volcengineTraditional.sentenceCluster = "new-sentence-cluster"
        XCTAssertNotEqual(CloudASRValidationInput(platform: .volcengineTraditionalSentence, asrConfig: config).fingerprint, sentence)
        XCTAssertEqual(CloudASRValidationInput(platform: .volcengineTraditionalRealtime, asrConfig: config).fingerprint, realtime)
    }

    func testSentenceFactoryRoutesToRestoredProviders() throws {
        let factory = ASRProviderFactory(runtimeManager: SenseVoiceRuntimeManager())
        for (platform, expected) in [(ASRPlatform.tencentCloudSentence, "TencentSentenceASRProvider"),
                                     (.aliyunSentence, "AliyunSentenceASRProvider"),
                                     (.volcengineSentence, "VolcengineSentenceASRProvider"),
                                     (.aliyunBailianHTTPASR, "AliyunBailianHTTPASRProvider")] {
            var config = ASRConfig()
            config.selectedPlatform = platform
            XCTAssertEqual(String(describing: type(of: factory.makeProvider(for: config))), expected)
            XCTAssertNotNil(ASRProviderFactory.makeSentenceProvider(for: config))
            XCTAssertThrowsError(try ASRProviderFactory.makeRealtimeSession(for: config))
        }
    }

    func testSentenceCredentialsAndReadinessAreIndependentOfRealtime() {
        var config = ASRConfig()
        config.tencentCloud.secretId = "synthetic-id"
        config.tencentCloud.secretKey = "synthetic-key"
        config.tencentCloud.sentenceValidationStatus = .verified
        config.selectedPlatform = .tencentCloudSentence
        XCTAssertTrue(config.isReady(localModelsAvailable: false))
        config.selectedPlatform = .tencentCloudRealtime
        XCTAssertFalse(config.isReady(localModelsAvailable: false))

        config.xunfei.appID = "synthetic-app"
        config.xunfei.apiKey = "synthetic-iat-key"
        config.xunfei.apiSecret = "synthetic-iat-secret"
        config.xunfei.iatValidationStatus = .verified
        config.selectedPlatform = .xunfeiIAT
        XCTAssertTrue(config.isReady(localModelsAvailable: false))
        config.selectedPlatform = .xunfeiRealtime
        XCTAssertFalse(config.isReady(localModelsAvailable: false))
    }

    func testProviderFactoryRoutesToExpectedProviderType() {
        let runtimeManager = SenseVoiceRuntimeManager()
        let factory = ASRProviderFactory(runtimeManager: runtimeManager)

        var config = ASRConfig()
        config.selectedPlatform = .localSenseVoice
        let local = factory.makeProvider(for: config)
        XCTAssertEqual(String(describing: type(of: local)), "SenseVoiceASRProvider")

        for platform in [ASRPlatform.tencentCloudRealtime, .aliyunRealtime, .aliyunBailianASR, .volcengineRealtime, .xunfeiRealtime] {
            XCTAssertTrue(platform.isRealtime)
        }
        XCTAssertFalse(ASRPlatform.localSenseVoice.isRealtime)
        XCTAssertFalse(ASRPlatform.openAICompatibleASR.isRealtime)
        XCTAssertFalse(ASRPlatform.mimoASR.isRealtime)

        config.selectedPlatform = .openAICompatibleASR
        XCTAssertTrue(factory.makeProvider(for: config) is OpenAICompatibleASRProvider)
        config.selectedPlatform = .mimoASR
        XCTAssertTrue(factory.makeProvider(for: config) is MiMoASRProvider)
    }


}
