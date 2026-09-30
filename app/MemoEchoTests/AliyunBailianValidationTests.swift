import XCTest
@testable import MemoEcho

@MainActor
final class AliyunBailianValidationTests: XCTestCase {
    func testIncompleteOrInvalidConfigurationDoesNotCreateValidator() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(configDirectory: directory)
        let service = CloudASRValidationService(configStore: store, validatorFactory: { _ in
            XCTFail("Invalid configuration must not send credentials")
            return BailianValidationGate()
        })
        for connection in [AliyunBailianASRConfig(), .init(baseURL: "https://example.com", apiKey: "key")] {
            var config = store.asrConfig
            config.selectedPlatform = .aliyunBailianASR
            config.aliyunBailian = connection
            try store.saveASRConfig(config)
            service.validate(.init(platform: .aliyunBailianASR, asrConfig: store.asrConfig))
            XCTAssertEqual(service.status, .incomplete)
            XCTAssertFalse(store.isASRReady)
        }
    }

    func testRecognizedTestSpeechValidatesAndRestoresIndependentState() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try configuredStore(directory: directory)
        try store.updateCloudValidationState(for: .aliyunRealtime, status: .failed, error: "other service failed")
        let service = service(store: store)
        service.validate(.init(platform: .aliyunBailianASR, asrConfig: store.asrConfig))
        await waitUntil { service.status == .ready }
        XCTAssertEqual(store.asrConfig.aliyunBailian.validationStatus, .verified)
        XCTAssertEqual(store.asrConfig.aliyun.validationStatus, .failed)
        let restored = ConfigStore(configDirectory: directory)
        let restoredService = CloudASRValidationService(configStore: restored)
        restoredService.syncFromConfig(for: .init(platform: .aliyunBailianASR, asrConfig: restored.asrConfig))
        XCTAssertEqual(restoredService.status, .ready)
        XCTAssertTrue(restored.isASRReady)
    }

    func testRealtimeProtocolAndAuthenticationFailuresCannotValidate() async throws {
        for error in [MemoEchoError.cloudASRAuthenticationFailure, .cloudASRInvalidResponse(detail: "实时会话未收到结束确认")] {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try configuredStore(directory: directory)
            let service = service(store: store, error: error)
            service.validate(.init(platform: .aliyunBailianASR, asrConfig: store.asrConfig))
            await waitUntil { service.status == .failed }
            XCTAssertEqual(store.asrConfig.aliyunBailian.validationStatus, .failed)
            XCTAssertFalse(store.isASRReady)
            XCTAssertEqual(ConfigStore(configDirectory: directory).asrConfig.aliyunBailian.validationStatus, .unvalidated)
        }
    }

    func testChangingAnyConnectionFieldDiscardsOldVerificationResult() async throws {
        for field in ["baseURL", "model", "apiKey"] {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try configuredStore(directory: directory)
            let gate = BailianValidationGate()
            let service = CloudASRValidationService(configStore: store, validatorFactory: { _ in gate })
            service.validate(.init(platform: .aliyunBailianASR, asrConfig: store.asrConfig))
            await gate.waitUntilStarted()
            var changed = store.asrConfig
            switch field {
            case "baseURL": changed.aliyunBailian.baseURL = "wss://other.example/api-ws/v1/inference"
            case "model": changed.aliyunBailian.model = "different-model"
            default: changed.aliyunBailian.apiKey = "different-key"
            }
            try store.saveASRConfig(changed)
            await gate.finish()
            await waitUntil { service.status == .incomplete }
            XCTAssertEqual(store.asrConfig.aliyunBailian.validationStatus, .unvalidated)
            XCTAssertFalse(ConfigStore(configDirectory: directory).isASRReady)
        }
    }

    func testNewConfigurationCancelsOldValidationAndRetainsLatestSuccess() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try configuredStore(directory: directory)
        let gate = BailianValidationGate()
        let service = CloudASRValidationService(configStore: store, validatorFactory: { input in
            if input.asrConfig.aliyunBailian.apiKey == "new-key" {
                return BailianCompletedValidator()
            }
            return gate
        })
        service.validate(.init(platform: .aliyunBailianASR, asrConfig: store.asrConfig))
        await gate.waitUntilStarted()
        var changed = store.asrConfig
        changed.aliyunBailian.apiKey = "new-key"
        try store.saveASRConfig(changed)
        service.syncFromConfig(for: .init(platform: .aliyunBailianASR, asrConfig: store.asrConfig))
        service.validate(.init(platform: .aliyunBailianASR, asrConfig: store.asrConfig))
        await waitUntil { service.status == .ready }
        await gate.finish()
        await waitUntil { await gate.hasFinished }
        XCTAssertEqual(service.status, .ready)
        XCTAssertEqual(store.asrConfig.aliyunBailian.apiKey, "new-key")
        XCTAssertEqual(store.asrConfig.aliyunBailian.validationStatus, .verified)
        let cancelled = await gate.wasCancelled
        XCTAssertTrue(cancelled)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func configuredStore(directory: URL) throws -> ConfigStore {
        let store = ConfigStore(configDirectory: directory)
        var config = store.asrConfig
        config.selectedPlatform = .aliyunBailianASR
        config.aliyunBailian = .init(baseURL: "wss://example.com/api-ws/v1/inference", apiKey: "synthetic-key")
        try store.saveASRConfig(config)
        return store
    }

    private func service(store: ConfigStore, error: MemoEchoError? = nil) -> CloudASRValidationService {
        CloudASRValidationService(configStore: store, validatorFactory: { input in
            XCTAssertEqual(input.platform, .aliyunBailianASR)
            return BailianCompletedValidator(error: error)
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

private struct BailianCompletedValidator: CloudASRValidating {
    var error: MemoEchoError?
    func validateCredentials() async throws {
        if let error { throw error }
    }
}

private actor BailianValidationGate: CloudASRValidating {
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
