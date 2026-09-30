import XCTest
@testable import MemoEcho

@MainActor
final class OpenAICompatibleASRValidationTests: XCTestCase {
    func testIncompleteOrInvalidConfigurationDoesNotCreateValidator() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(configDirectory: directory)
        let service = CloudASRValidationService(configStore: store, validatorFactory: { _ in
            XCTFail("Invalid configuration must not send credentials")
            return OpenAIValidationGate()
        })
        for connection in [OpenAICompatibleASRConfig(), .init(baseURL: "https://example.com/v1", model: "")] {
            var config = store.asrConfig
            config.selectedPlatform = .openAICompatibleASR
            config.openAICompatible = connection
            try store.saveASRConfig(config)
            service.validate(.init(platform: .openAICompatibleASR, asrConfig: store.asrConfig))
            XCTAssertEqual(service.status, .incomplete)
            XCTAssertFalse(store.isASRReady)
        }
    }

    func testRecognizedTestSpeechValidatesAndRestoresIndependentState() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try configuredStore(directory: directory)
        try store.updateCloudValidationState(for: .aliyunRealtime, status: .failed, error: "other service failed")
        let service = service(store: store, body: #"{"text":"你好，语音识别测试。"}"#)
        service.validate(.init(platform: .openAICompatibleASR, asrConfig: store.asrConfig))
        await waitUntil { service.status == .ready }
        XCTAssertEqual(store.asrConfig.openAICompatible.validationStatus, .verified)
        XCTAssertEqual(store.asrConfig.aliyun.validationStatus, .failed)
        let restored = ConfigStore(configDirectory: directory)
        let restoredService = CloudASRValidationService(configStore: restored)
        restoredService.syncFromConfig(for: .init(platform: .openAICompatibleASR, asrConfig: restored.asrConfig))
        XCTAssertEqual(restoredService.status, .ready)
        XCTAssertTrue(restored.isASRReady)
    }

    func testProtocolErrorsAndAuthenticationFailureCannotValidate() async throws {
        for (body, status) in [("{}", 200), (#"{"text":""}"#, 200), (#"{"text":null}"#, 200),
                               (#"{"error":{"message":"private"},"text":""}"#, 200),
                               (#"{"text":""}"#, 401)] {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try configuredStore(directory: directory)
            let service = service(store: store, body: body, status: status)
            service.validate(.init(platform: .openAICompatibleASR, asrConfig: store.asrConfig))
            await waitUntil { service.status == .failed }
            XCTAssertEqual(store.asrConfig.openAICompatible.validationStatus, .failed)
            XCTAssertFalse(store.isASRReady)
            XCTAssertFalse(service.lastErrorMessage?.contains("private") ?? false)
            XCTAssertEqual(ConfigStore(configDirectory: directory).asrConfig.openAICompatible.validationStatus, .unvalidated)
        }
    }

    func testChangingAnyConnectionFieldDiscardsOldVerificationResult() async throws {
        for field in ["baseURL", "model", "apiKey", "apiFormat"] {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try configuredStore(directory: directory)
            let gate = OpenAIValidationGate()
            let service = CloudASRValidationService(configStore: store, validatorFactory: { _ in gate })
            service.validate(.init(platform: .openAICompatibleASR, asrConfig: store.asrConfig))
            await gate.waitUntilStarted()
            var changed = store.asrConfig
            switch field {
            case "baseURL": changed.openAICompatible.baseURL = "https://other.example/v1"
            case "model": changed.openAICompatible.model = "different-model"
            case "apiFormat": changed.openAICompatible.apiFormat = .chatCompletions
            default: changed.openAICompatible.apiKey = "different-key"
            }
            try store.saveASRConfig(changed)
            await gate.finish()
            await waitUntil { service.status == .incomplete }
            XCTAssertEqual(store.asrConfig.openAICompatible.validationStatus, .unvalidated)
            XCTAssertFalse(ConfigStore(configDirectory: directory).isASRReady)
        }
    }

    func testNewConfigurationCancelsOldValidationAndRetainsLatestSuccess() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try configuredStore(directory: directory)
        let gate = OpenAIValidationGate()
        let service = CloudASRValidationService(configStore: store, validatorFactory: { input in
            if input.asrConfig.openAICompatible.model == "new-model" {
                return OpenAICompatibleASRProvider(config: input.asrConfig.openAICompatible,
                                              httpClient: OpenAIValidationHTTPClient(body: #"{"text":"你好，语音识别测试。"}"#, status: 200))
            }
            return gate
        })
        service.validate(.init(platform: .openAICompatibleASR, asrConfig: store.asrConfig))
        await gate.waitUntilStarted()
        var changed = store.asrConfig
        changed.openAICompatible.model = "new-model"
        try store.saveASRConfig(changed)
        service.syncFromConfig(for: .init(platform: .openAICompatibleASR, asrConfig: store.asrConfig))
        service.validate(.init(platform: .openAICompatibleASR, asrConfig: store.asrConfig))
        await waitUntil { service.status == .ready }
        await gate.finish()
        await waitUntil { await gate.hasFinished }
        XCTAssertEqual(service.status, .ready)
        XCTAssertEqual(store.asrConfig.openAICompatible.model, "new-model")
        XCTAssertEqual(store.asrConfig.openAICompatible.validationStatus, .verified)
        let cancelled = await gate.wasCancelled
        XCTAssertTrue(cancelled)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func configuredStore(directory: URL) throws -> ConfigStore {
        let store = ConfigStore(configDirectory: directory)
        var config = store.asrConfig
        config.selectedPlatform = .openAICompatibleASR
        config.openAICompatible = .init(baseURL: "https://example.com/v1", model: "test-asr")
        try store.saveASRConfig(config)
        return store
    }

    private func service(store: ConfigStore, body: String, status: Int = 200) -> CloudASRValidationService {
        CloudASRValidationService(configStore: store, validatorFactory: { input in
            XCTAssertEqual(input.platform, .openAICompatibleASR)
            return OpenAICompatibleASRProvider(config: input.asrConfig.openAICompatible,
                                          httpClient: OpenAIValidationHTTPClient(body: body, status: status))
        })
    }

    private func waitUntil(condition: () async -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Validation did not reach the expected state")
    }
}

private struct OpenAIValidationHTTPClient: OpenAIASRHTTPClient {
    let body: String
    let status: Int
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private actor OpenAIValidationGate: CloudASRValidating {
    private var continuation: CheckedContinuation<Void, Never>?
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private(set) var wasCancelled = false
    private(set) var hasFinished = false

    func validateCredentials() async throws {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            startedWaiter?.resume()
            startedWaiter = nil
        }
        wasCancelled = Task.isCancelled
        hasFinished = true
    }

    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}
