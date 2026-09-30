import XCTest
@testable import MemoEcho

final class MiMoASRConfigTests: XCTestCase {
    func testDefaultsRequireNewCredentials() throws {
        let config = MiMoASRConfig()
        XCTAssertEqual(config.requestURL?.absoluteString, "https://api.xiaomimimo.com/v1/chat/completions")
        XCTAssertEqual(config.model, "mimo-v2.5-asr")
        XCTAssertFalse(config.isComplete)
        XCTAssertFalse(config.hasUserConfiguration)
        XCTAssertEqual(try JSONDecoder().decode(MiMoASRConfig.self, from: Data("{}".utf8)), config)
    }

    func testEquivalentBaseAndFullEndpointShareIdentity() {
        let base = MiMoASRConfig(baseURL: " HTTPS://ASR.example/v1/// ", apiKey: " synthetic ", model: " test ")
        let full = MiMoASRConfig(baseURL: "https://asr.example/v1/chat/completions", apiKey: "synthetic", model: "test")
        XCTAssertTrue(base.isComplete)
        XCTAssertEqual(base.connectionIdentity, full.connectionIdentity)
        XCTAssertTrue(MiMoASRConfig(baseURL: "https://token-plan-cn.xiaomimimo.com/v1", apiKey: "synthetic").isComplete)
    }

    func testRejectsUnsafeAndWrongProtocolAddresses() {
        for address in ["http://localhost:8000/v1", "https://user:key@example.com/v1", "https://example.com/v1?key=secret",
                        "https://example.com/v1#fragment", "https://example.com:65536/v1", "https://example.com:0/v1",
                        "https://ex ample.com/v1", "https://example.com/v1/audio/transcriptions", "file:///v1"] {
            let config = MiMoASRConfig(baseURL: address, apiKey: "synthetic")
            XCTAssertNil(config.requestURL, address)
            XCTAssertFalse(config.isComplete, address)
        }
        XCTAssertFalse(MiMoASRConfig(apiKey: "key\r\nHeader: value").isComplete)
        XCTAssertFalse(MiMoASRConfig(apiKey: "synthetic", model: "asr\nother").isComplete)
    }

    func testSerializationExcludesRuntimeValidation() throws {
        var config = MiMoASRConfig(apiKey: "synthetic")
        config.validationStatus = .verified
        config.lastValidationError = "runtime-error"
        let data = try JSONEncoder().encode(config)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("runtime-error"))
        let decoded = try JSONDecoder().decode(MiMoASRConfig.self, from: data)
        XCTAssertEqual(decoded.validationStatus, .unvalidated)
        XCTAssertEqual(decoded.apiKey, "synthetic")
    }
}
