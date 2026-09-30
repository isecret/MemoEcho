import XCTest
@testable import MemoEcho

final class AliyunBailianConfigTests: XCTestCase {
    func testEndpointNormalizationSupportsWSSOnly() {
        let expected = "wss://workspace.example.com" + AliyunBailianASRConfig.endpointSuffix
        for address in [" WSS://WORKSPACE.example.com/api-ws/v1/inference///\n", expected, expected + "/"] {
            let config = AliyunBailianASRConfig(baseURL: address, apiKey: "key")
            XCTAssertEqual(config.requestURL?.absoluteString, expected)
            XCTAssertTrue(config.isComplete)
        }
        for host in ["dashscope.aliyuncs.com", "dashscope-intl.aliyuncs.com", "workspace.ap-southeast-1.maas.aliyuncs.com"] {
            let config = AliyunBailianASRConfig(baseURL: "wss://\(host)/api-ws/v1/inference", apiKey: "key")
            XCTAssertEqual(config.requestURL?.host, host)
        }
    }

    func testRetiredHTTPConfigurationCannotBecomeReady() throws {
        let data = Data(#"{"baseURL":"https://example.com/api/v1","apiKey":"synthetic-key","model":"qwen-audio-3.1-asr-flash"}"#.utf8)
        var config = try JSONDecoder().decode(AliyunBailianASRConfig.self, from: data)
        config.validationStatus = .verified
        XCTAssertFalse(config.isReady)
        XCTAssertNil(config.requestURL)
        XCTAssertTrue(config.incompleteReason(platformName: "阿里云百炼").contains("WSS"))
        XCTAssertEqual(try JSONDecoder().decode(AliyunBailianASRConfig.self, from: Data("{}".utf8)), AliyunBailianASRConfig())
        XCTAssertFalse(AliyunBailianASRConfig().hasUserConfiguration)
    }

    func testInvalidAddressesCannotBecomeReady() {
        for address in ["", "example.com/api/v1", "http://example.com/api/v1", "file:///api/v1", "https:///api/v1",
                        "https://user:password@example.com/api/v1", "https://example.com/api/v1?key=secret",
                        "https://example.com/api/v1#fragment", "https://example.com", "https://example.com/v1",
                        "https://example.com/api/v1/chat/completions", "https://exam ple.com/api/v1"] {
            var config = AliyunBailianASRConfig(baseURL: address, apiKey: "key")
            config.validationStatus = .verified
            XCTAssertNil(config.requestURL, address)
            XCTAssertFalse(config.isComplete, address)
            XCTAssertFalse(config.isReady, address)
        }
    }

    func testBlankFieldsAndHeaderNewlinesAreIncomplete() {
        for config in [AliyunBailianASRConfig(baseURL: "wss://example.com/api-ws/v1/inference", apiKey: " "),
                       .init(baseURL: "wss://example.com/api-ws/v1/inference", apiKey: "key", model: " \n"),
                       .init(baseURL: "wss://example.com/api-ws/v1/inference", apiKey: "key\r\nInjected: value")] {
            XCTAssertFalse(config.isComplete)
        }
    }

    func testFingerprintUsesCanonicalEndpointModelAndKey() {
        var config = ASRConfig()
        config.aliyunBailian = .init(baseURL: "wss://example.com/api-ws/v1/inference", apiKey: "key", model: AliyunBailianASRConfig.defaultModel)
        let original = CloudASRValidationInput(platform: .aliyunBailianASR, asrConfig: config).fingerprint
        var equivalent = config
        equivalent.aliyunBailian.baseURL += "/"
        equivalent.aliyunBailian.model = " paraformer-realtime-v2 "
        XCTAssertEqual(CloudASRValidationInput(platform: .aliyunBailianASR, asrConfig: equivalent).fingerprint, original)
        for changed in [AliyunBailianASRConfig(baseURL: "wss://other.example/api-ws/v1/inference", apiKey: "key", model: AliyunBailianASRConfig.defaultModel),
                        .init(baseURL: "wss://example.com/api-ws/v1/inference", apiKey: "other-key", model: AliyunBailianASRConfig.defaultModel),
                        .init(baseURL: "wss://example.com/api-ws/v1/inference", apiKey: "key", model: "other-model")] {
            config.aliyunBailian = changed
            XCTAssertNotEqual(CloudASRValidationInput(platform: .aliyunBailianASR, asrConfig: config).fingerprint, original)
        }
    }

    func testOldConfigurationsDoNotNeedBailianField() throws {
        let data = Data(#"{"selectedPlatform":"aliyunRealtime","aliyun":{"accessKeyId":"id","accessKeySecret":"secret","appKey":"app"}}"#.utf8)
        let config = try JSONDecoder().decode(ASRConfig.self, from: data)
        XCTAssertEqual(config.selectedPlatform, .aliyunRealtime)
        XCTAssertEqual(config.aliyun.appKey, "app")
        XCTAssertEqual(config.aliyunBailian, AliyunBailianASRConfig())
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        XCTAssertNil(encoded["aliyunBailian"])
    }

    func testPartialConfigAndExplicitlyClearedModelRoundTripWithoutRuntimeState() throws {
        for fields in [AliyunBailianASRConfig(baseURL: "half-entered"), .init(apiKey: "synthetic"), .init(model: "")] {
            var config = ASRConfig()
            config.aliyunBailian = fields
            config.aliyunBailian.validationStatus = .failed
            config.aliyunBailian.lastValidationError = "temporary error"
            let data = try JSONEncoder().encode(config)
            let decoded = try JSONDecoder().decode(ASRConfig.self, from: data)
            XCTAssertEqual(decoded.aliyunBailian, fields)
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(text.contains("validationStatus"))
            XCTAssertFalse(text.contains("temporary error"))
        }
    }

    func testReadinessRequiresVerifiedBailianAndFactoryRoutesIndependently() {
        var config = ASRConfig()
        config.selectedPlatform = .aliyunBailianASR
        config.aliyunBailian = .init(baseURL: "wss://example.com/api-ws/v1/inference", apiKey: "key")
        config.aliyun.validationStatus = .verified
        XCTAssertFalse(config.isReady(localModelsAvailable: true))
        config.aliyunBailian.validationStatus = .verified
        XCTAssertTrue(config.isReady(localModelsAvailable: false))
        XCTAssertNil(config.notReadyReason(localModelsAvailable: false))
        XCTAssertTrue(config.selectedPlatform.isRealtime)
        XCTAssertEqual(ASRPlatform.aliyunBailianASR.displayName, "阿里云 · 百炼实时语音识别")
        XCTAssertEqual(ASRPlatform.aliyunRealtime.displayName, "阿里云 · 实时语音识别")
    }

    @MainActor
    func testConnectionEditsInvalidatePersistedVerificationAndKeepOtherPlatforms() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(configDirectory: directory)
        var config = store.asrConfig
        config.selectedPlatform = .aliyunBailianASR
        let original = AliyunBailianASRConfig(baseURL: "wss://example.com/api-ws/v1/inference", apiKey: "synthetic-key")
        config.aliyunBailian = original
        config.aliyun.accessKeyId = "id"
        config.aliyun.accessKeySecret = "synthetic-secret"
        config.aliyun.appKey = "app"
        try store.saveASRConfig(config)
        try store.updateCloudValidationState(for: .aliyunRealtime, status: .verified)
        for changed in [AliyunBailianASRConfig(baseURL: "wss://other.example/api-ws/v1/inference", apiKey: "synthetic-key"),
                        .init(baseURL: original.baseURL, apiKey: "new-key"),
                        .init(baseURL: original.baseURL, apiKey: original.apiKey, model: "other-model")] {
            var reset = store.asrConfig
            reset.aliyunBailian = original
            try store.saveASRConfig(reset)
            try store.updateCloudValidationState(for: .aliyunBailianASR, status: .verified)
            let verified = ConfigStore(configDirectory: directory)
            XCTAssertEqual(verified.asrConfig.aliyunBailian.validationStatus, .verified)
            XCTAssertEqual(verified.asrConfig.aliyunBailian.baseURL, original.baseURL)
            XCTAssertEqual(verified.asrConfig.aliyunBailian.model, original.model)
            XCTAssertEqual(verified.asrConfig.aliyunBailian.apiKey, original.apiKey)
            var edited = store.asrConfig
            edited.aliyunBailian = changed
            edited.aliyunBailian.validationStatus = .verified
            try store.saveASRConfig(edited)
            XCTAssertEqual(store.asrConfig.aliyunBailian.validationStatus, .unvalidated)
            let restored = ConfigStore(configDirectory: directory)
            XCTAssertEqual(restored.asrConfig.aliyunBailian.validationStatus, .unvalidated)
            XCTAssertEqual(restored.asrConfig.aliyun.validationStatus, .verified)
            XCTAssertEqual(restored.asrConfig.selectedPlatform, .aliyunBailianASR)
        }
        let state = try String(contentsOf: directory.appendingPathComponent("state.json"), encoding: .utf8)
        XCTAssertFalse(state.contains("synthetic-key"))
        XCTAssertFalse(state.contains("https://example.com"))
    }
}
