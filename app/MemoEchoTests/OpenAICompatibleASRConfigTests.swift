import XCTest
@testable import MemoEcho

final class OpenAICompatibleASRConfigTests: XCTestCase {
    func testBaseAndFullTranscriptionEndpointsHaveSameIdentity() {
        for format in [OpenAIASRFormat.audioTranscriptions] {
            let base = OpenAICompatibleASRConfig(apiFormat: format, baseURL: " HTTPS://ASR.example:8443/proxy/v1///\n", model: " test ")
            let full = OpenAICompatibleASRConfig(apiFormat: format, baseURL: "https://asr.example:8443/proxy/v1" + format.endpointSuffix, model: "test")
            XCTAssertEqual(base.connectionIdentity, full.connectionIdentity)
            XCTAssertTrue(base.isComplete)
            XCTAssertEqual(base.requestURL?.absoluteString, full.baseURL)
        }
    }

    func testLegacyChatConfigurationDecodesButIsNeverReady() throws {
        let data = Data(#"{"apiFormat":"chatCompletions","baseURL":"https://example.com/v1","apiKey":"old-key","model":"asr"}"#.utf8)
        let config = try JSONDecoder().decode(OpenAICompatibleASRConfig.self, from: data)
        XCTAssertEqual(config.apiFormat, .chatCompletions)
        XCTAssertNil(config.requestURL)
        XCTAssertFalse(config.isComplete)
        XCTAssertTrue(config.incompleteReason(platformName: "OpenAI 兼容").contains("MiMo"))
        XCTAssertEqual(try JSONDecoder().decode(OpenAICompatibleASRConfig.self, from: JSONEncoder().encode(config)), config)
    }

    func testLocalHTTPAddressesAndOptionalKey() {
        for host in ["localhost", "localhost.", "asr.local", "127.0.0.1", "10.0.0.2", "172.16.0.1", "172.31.255.254", "192.168.2.3", "[::1]", "[fd12::1]", "[fc00::2]"] {
            let config = OpenAICompatibleASRConfig(baseURL: "http://\(host):8000/v1", model: "asr")
            XCTAssertTrue(config.isComplete, host)
            XCTAssertEqual(config.requestURL?.port, 8000)
        }
    }

    func testRejectsPublicHTTPMalformedEndpointsAndSecretsInURL() {
        for base in ["http://example.com/v1", "http://8.8.8.8/v1", "http://172.15.0.1/v1", "http://172.32.0.1/v1",
                     "http://localhost.example/v1", "http://[2001:db8::1]/v1", "http://[::ffff:8.8.8.8]/v1",
                     "http://127.0.0.1:0/v1", "http://127.0.0.1:65536/v1", "http://127.0.0.1:abc/v1",
                     "https://user:key@example.com/v1", "https://example.com/v1?key=secret", "https://example.com/v1#frag",
                     "https:///v1", "https://ex ample.com/v1", "file:///v1", "example.com/v1"] {
            let config = OpenAICompatibleASRConfig(baseURL: base, model: "asr")
            XCTAssertNil(config.requestURL, base)
            XCTAssertFalse(config.isComplete, base)
        }
    }

    func testCompleteEndpointMustMatchSelectedFormat() {
        for format in OpenAIASRFormat.allCases {
            let other: OpenAIASRFormat = format == .audioTranscriptions ? .chatCompletions : .audioTranscriptions
            let config = OpenAICompatibleASRConfig(apiFormat: format, baseURL: "https://example.com/v1" + other.endpointSuffix, model: "asr")
            XCTAssertNil(config.requestURL)
        }
        XCTAssertEqual(OpenAICompatibleASRConfig(baseURL: "https://example.com", model: "asr").requestURL?.path, "/audio/transcriptions")
    }

    func testControlCharactersCannotInjectMultipartOrAuthorization() {
        XCTAssertFalse(OpenAICompatibleASRConfig(baseURL: "https://example.com/v1", apiKey: "key\r\nHeader: value", model: "asr").isComplete)
        XCTAssertFalse(OpenAICompatibleASRConfig(baseURL: "https://example.com/v1", model: "asr\r\n--boundary").isComplete)
        XCTAssertFalse(OpenAICompatibleASRConfig(baseURL: "https://example.com/v1", model: "  ").isComplete)
    }

    func testPartialConfigRoundTripsWithoutRuntimeState() throws {
        for original in [OpenAICompatibleASRConfig(apiFormat: .chatCompletions), .init(baseURL: "partial"), .init(model: "asr")] {
            var asr = ASRConfig()
            asr.openAICompatible = original
            asr.openAICompatible.validationStatus = .verified
            asr.openAICompatible.lastValidationError = "runtime-error"
            let data = try JSONEncoder().encode(asr)
            let decoded = try JSONDecoder().decode(ASRConfig.self, from: data)
            XCTAssertEqual(decoded.openAICompatible, original)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("runtime-error"))
        }
        let old = try JSONDecoder().decode(ASRConfig.self, from: Data(#"{"selectedPlatform":"tencentCloudRealtime"}"#.utf8))
        XCTAssertEqual(old.openAICompatible, .init())
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        XCTAssertNil(encoded["openAICompatible"])
    }

    @MainActor
    func testEachConnectionFieldInvalidatesPersistedVerification() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(configDirectory: directory)
        let original = OpenAICompatibleASRConfig(baseURL: "http://localhost:8000/v1", model: "asr")
        for field in ["baseURL", "model", "apiKey", "apiFormat"] {
            var config = store.asrConfig
            config.selectedPlatform = .openAICompatibleASR
            config.openAICompatible = original
            try store.saveASRConfig(config)
            try store.updateCloudValidationState(for: .openAICompatibleASR, status: .verified)
            XCTAssertTrue(ConfigStore(configDirectory: directory).isASRReady)
            var edited = store.asrConfig
            switch field {
            case "baseURL": edited.openAICompatible.baseURL = "http://localhost:8001/v1"
            case "model": edited.openAICompatible.model = "other-asr"
            case "apiFormat": edited.openAICompatible.apiFormat = .chatCompletions
            default: edited.openAICompatible.apiKey = "synthetic-key"
            }
            try store.saveASRConfig(edited)
            XCTAssertFalse(store.isASRReady)
            XCTAssertFalse(ConfigStore(configDirectory: directory).isASRReady)
        }
    }

    @MainActor
    func testRemovedSelectionsFailWithoutMigratingOrOverwritingFile() throws {
        for platform in ["xiaomiMiMoASR", "xiaomiMiMoTokenPlanASR"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            _ = ConfigStore(configDirectory: directory)
            let url = directory.appendingPathComponent("config.json")
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            json["asr"] = ["selectedPlatform": platform, "xiaomiMiMo": ["apiKey": "old-key"]]
            let data = try JSONSerialization.data(withJSONObject: json)
            try data.write(to: url)
            let restored = ConfigStore(configDirectory: directory)
            XCTAssertTrue(restored.configLoadFailed)
            XCTAssertEqual(try Data(contentsOf: url), data)
            XCTAssertEqual(restored.asrConfig.openAICompatible, .init())
        }
    }

    func testRetainedPlatformIgnoresUnusedOldKeysWithoutImportingThem() throws {
        let data = Data(#"{"selectedPlatform":"aliyunRealtime","xiaomiMiMo":{"apiKey":"old-key"}}"#.utf8)
        let config = try JSONDecoder().decode(ASRConfig.self, from: data)
        XCTAssertEqual(config.selectedPlatform, .aliyunRealtime)
        XCTAssertEqual(config.openAICompatible, .init())
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(config), as: UTF8.self).contains("old-key"))
        XCTAssertTrue(ASRPlatform.allCases.contains(.mimoASR))
        XCTAssertEqual(ASRPlatform.openAICompatibleASR.displayName, "OpenAI 兼容")
    }
}
