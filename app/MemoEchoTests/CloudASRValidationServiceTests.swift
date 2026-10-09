import XCTest
@testable import MemoEcho

final class CloudASRValidationServiceTests: XCTestCase {
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
    func testMenuSnapshotDoesNotValidateAndSeparatesTransientFromConfirmedFailure() async throws {
        let store = try configuredTencentStore()
        try store.saveLLMConfig(.init(baseURL: "https://example.test/v1", model: "synthetic"), apiKey: "synthetic")
        let counter = ValidationCounter()
        let cloud = CloudASRValidationService(configStore: store, validatorFactory: { _ in
            counter.increment()
            return StubCloudASRValidator {}
        })
        let llm = LLMValidationService(validator: { _, _ in })
        let readiness = VoiceInputReadinessService(configStore: store, permissionsManager: PermissionsManager(),
            llmValidationService: llm, cloudASRValidationService: cloud)
        for _ in 0..<3 {
            if case .pending = readiness.menuSnapshot.asr {} else { XCTFail("Untested credentials are pending") }
            if case .pending = readiness.menuSnapshot.llm {} else { XCTFail("Untested credentials are pending") }
        }
        XCTAssertEqual(counter.currentValue(), 0)
        let input = CloudASRValidationInput(platform: .tencentCloudRealtime, asrConfig: store.asrConfig)
        let llmInput = LLMValidationInput(baseURL: store.llmConfig.baseURL, apiKey: store.openAIAPIKey,
            model: store.llmConfig.model, omitThinkingParameter: false)
        cloud.validate(input)
        llm.validate(llmInput)
        await waitUntil { cloud.status == .ready && llm.status == .ready }
        cloud.invalidateCurrentValidation(isTransient: true)
        llm.invalidateCurrentValidation(isTransient: true)
        if case .pending = readiness.menuSnapshot.asr {} else { XCTFail("Transient errors must not leave a menu blocker") }
        if case .pending = readiness.menuSnapshot.llm {} else { XCTFail("Transient errors must not leave a menu blocker") }
        XCTAssertFalse(readiness.snapshot.asr.isReady, "Runtime safety validation still applies")
        XCTAssertFalse(readiness.snapshot.llm.isReady)
        cloud.invalidateCurrentValidation()
        llm.invalidateCurrentValidation()
        if case .blocked = readiness.menuSnapshot.asr {} else { XCTFail("Confirmed failures require settings") }
        if case .blocked = readiness.menuSnapshot.llm {} else { XCTFail("Confirmed failures require settings") }
        cloud.invalidateCurrentValidation(isTransient: true)
        llm.invalidateCurrentValidation(isTransient: true)
        cloud.validate(input, force: true)
        llm.validate(llmInput, force: true)
        XCTAssertFalse(cloud.isTransientRuntimeFailure)
        XCTAssertFalse(llm.isTransientRuntimeFailure)
        await waitUntil { cloud.status == .ready && llm.status == .ready }
        XCTAssertEqual(counter.currentValue(), 2)
    }

    @MainActor
    func testIncompleteInputDoesNotRunValidator() async {
        let store = ConfigStore(configDirectory: tempDirectory)
        let counter = ValidationCounter()
        let service = CloudASRValidationService(
            configStore: store,
            validatorFactory: { _ in
                counter.increment()
                return StubCloudASRValidator {}
            }
        )

        service.validate(
            CloudASRValidationInput(
                platform: .tencentCloudRealtime,
                asrConfig: ASRConfig()
            )
        )

        XCTAssertEqual(service.status, .incomplete)
        XCTAssertNil(service.lastErrorMessage)
        XCTAssertEqual(counter.currentValue(), 0)
    }

    @MainActor
    func testSuccessfulValidationTransitionsToReadyAndPersistsState() async throws {
        let store = ConfigStore(configDirectory: tempDirectory)
        var config = store.asrConfig
        config.selectedPlatform = .tencentCloudRealtime
        config.tencentCloud.appID = "123456"
        config.tencentCloud.secretId = "id"
        config.tencentCloud.secretKey = "key"
        try store.saveASRConfig(config)

        let service = CloudASRValidationService(
            configStore: store,
            validatorFactory: { _ in
                StubCloudASRValidator {
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
        )

        service.validate(CloudASRValidationInput(platform: .tencentCloudRealtime, asrConfig: store.asrConfig))

        XCTAssertEqual(service.status, .checking)
        await waitUntil { service.status == .ready }
        XCTAssertEqual(store.asrConfig.tencentCloud.validationStatus, .verified)
    }

    @MainActor
    func testValidationFailureExposesUserFacingErrorAndPersistsFailure() async throws {
        let store = ConfigStore(configDirectory: tempDirectory)
        var config = store.asrConfig
        config.selectedPlatform = .aliyunRealtime
        config.aliyun.accessKeyId = "ak"
        config.aliyun.accessKeySecret = "secret"
        config.aliyun.appKey = "app"
        try store.saveASRConfig(config)

        let service = CloudASRValidationService(
            configStore: store,
            validatorFactory: { _ in
                StubCloudASRValidator {
                    throw MemoEchoError.cloudASRAuthenticationFailure
                }
            }
        )

        service.validate(CloudASRValidationInput(platform: .aliyunRealtime, asrConfig: store.asrConfig))

        await waitUntil { service.status == .failed }
        XCTAssertEqual(service.lastErrorMessage, "云端 ASR 认证失败，请检查当前平台凭据")
        XCTAssertEqual(store.asrConfig.aliyun.validationStatus, .failed)
        XCTAssertEqual(store.asrConfig.aliyun.lastValidationError, "云端 ASR 认证失败，请检查当前平台凭据")
    }

    @MainActor
    func testLatestValidationWinsOverCancelledRequest() async throws {
        let store = ConfigStore(configDirectory: tempDirectory)
        var config = store.asrConfig
        config.selectedPlatform = .xunfeiRealtime
        config.xunfei.appID = "appid"
        config.xunfei.realtimeAPIKey = "key"
        config.xunfei.apiSecret = "secret"
        try store.saveASRConfig(config)

        let service = CloudASRValidationService(
            configStore: store,
            validatorFactory: { input in
                StubCloudASRValidator {
                    if input.asrConfig.xunfei.realtimeAPIKey == "key" {
                        try await Task.sleep(for: .milliseconds(150))
                        throw MemoEchoError.cloudASRNetworkFailure(message: "old request should be cancelled")
                    }
                }
            }
        )

        service.validate(CloudASRValidationInput(platform: .xunfeiRealtime, asrConfig: store.asrConfig))

        var nextConfig = store.asrConfig
        nextConfig.xunfei.realtimeAPIKey = "new-key"
        try store.saveASRConfig(nextConfig)
        service.validate(CloudASRValidationInput(platform: .xunfeiRealtime, asrConfig: store.asrConfig))

        await waitUntil { service.status == .ready }
        XCTAssertNil(service.lastErrorMessage)
        XCTAssertEqual(store.asrConfig.xunfei.validationStatus, .verified)
    }

    @MainActor
    func testSyncFromConfigRestoresVerifiedState() throws {
        let store = ConfigStore(configDirectory: tempDirectory)
        var config = store.asrConfig
        config.selectedPlatform = .tencentCloudRealtime
        config.tencentCloud.appID = "123456"
        config.tencentCloud.secretId = "id"
        config.tencentCloud.secretKey = "key"
        try store.saveASRConfig(config)
        try store.updateCloudValidationState(for: .tencentCloudRealtime, status: .verified)

        let service = CloudASRValidationService(configStore: store)
        service.syncFromConfig(
            for: CloudASRValidationInput(platform: .tencentCloudRealtime, asrConfig: store.asrConfig)
        )

        XCTAssertEqual(service.status, .ready)
        XCTAssertNil(service.lastErrorMessage)
    }

    @MainActor
    func testSyncFromConfigRestoresFailedStateAndMessage() throws {
        let store = ConfigStore(configDirectory: tempDirectory)
        var config = store.asrConfig
        config.selectedPlatform = .aliyunRealtime
        config.aliyun.accessKeyId = "ak"
        config.aliyun.accessKeySecret = "secret"
        config.aliyun.appKey = "app"
        try store.saveASRConfig(config)
        try store.updateCloudValidationState(
            for: .aliyunRealtime,
            status: .failed,
            error: "云端 ASR 认证失败，请检查当前平台凭据"
        )

        let service = CloudASRValidationService(configStore: store)
        service.syncFromConfig(
            for: CloudASRValidationInput(platform: .aliyunRealtime, asrConfig: store.asrConfig)
        )

        XCTAssertEqual(service.status, .failed)
        XCTAssertEqual(service.lastErrorMessage, "云端 ASR 认证失败，请检查当前平台凭据")
    }

    @MainActor
    func testSyncFromConfigDoesNotTreatOrphanedValidatingAsReady() throws {
        let store = ConfigStore(configDirectory: tempDirectory)
        var config = store.asrConfig
        config.selectedPlatform = .volcengineRealtime
        config.volcengine.apiKey = "api-key"
        try store.saveASRConfig(config)
        try store.updateCloudValidationState(for: .volcengineRealtime, status: .validating)

        let service = CloudASRValidationService(configStore: store)
        service.syncFromConfig(
            for: CloudASRValidationInput(platform: .volcengineRealtime, asrConfig: store.asrConfig)
        )

        XCTAssertEqual(service.status, .incomplete)
        XCTAssertNil(service.lastErrorMessage)
    }

    @MainActor
    func testSyncWhileCheckingPreservesSingleFlightAndNeverReportsReady() async throws {
        let store = try configuredTencentStore()
        let counter = ValidationCounter()
        let service = CloudASRValidationService(configStore: store, validatorFactory: { _ in
            counter.increment()
            return StubCloudASRValidator { try await Task.sleep(for: .milliseconds(30)) }
        })
        let input = CloudASRValidationInput(platform: .tencentCloudRealtime, asrConfig: store.asrConfig)
        service.validate(input)
        await waitUntil { store.asrConfig.tencentCloud.validationStatus == .validating }
        let updatedInput = CloudASRValidationInput(platform: .tencentCloudRealtime, asrConfig: store.asrConfig)
        service.syncFromConfig(for: updatedInput)
        service.validate(updatedInput)
        service.validate(updatedInput, force: true)
        XCTAssertEqual(service.status(for: updatedInput), .checking)
        await waitUntil { service.status == .ready }
        XCTAssertEqual(counter.currentValue(), 1)
    }

    @MainActor
    func testCredentialChangeBeforeOldRequestCompletesDoesNotPersistOldSuccess() async throws {
        let store = try configuredTencentStore()
        let service = CloudASRValidationService(configStore: store, validatorFactory: { _ in
            StubCloudASRValidator { try await Task.sleep(for: .milliseconds(40)) }
        })
        service.validate(CloudASRValidationInput(platform: .tencentCloudRealtime, asrConfig: store.asrConfig))
        await waitUntil { store.asrConfig.tencentCloud.validationStatus == .validating }
        var changedConfig = store.asrConfig
        changedConfig.tencentCloud.secretKey = "different-key"
        try store.saveASRConfig(changedConfig)
        await waitUntil { service.status == .incomplete }
        XCTAssertEqual(store.asrConfig.tencentCloud.validationStatus, .unvalidated)
        XCTAssertEqual(service.status(for: CloudASRValidationInput(platform: .tencentCloudRealtime, asrConfig: store.asrConfig)), .incomplete)
    }

    @MainActor
    func testFailureIsCachedAndUnknownErrorsAreNotPersisted() async throws {
        let store = try configuredTencentStore()
        let counter = ValidationCounter()
        let service = CloudASRValidationService(configStore: store, validatorFactory: { _ in
            counter.increment()
            return StubCloudASRValidator {
                throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "test-key response body"])
            }
        })
        let input = CloudASRValidationInput(platform: .tencentCloudRealtime, asrConfig: store.asrConfig)
        service.validate(input)
        await waitUntil { service.status == .failed }
        service.syncFromConfig(for: CloudASRValidationInput(platform: .tencentCloudRealtime, asrConfig: store.asrConfig))
        service.validate(input)
        XCTAssertEqual(counter.currentValue(), 1)
        XCTAssertEqual(store.asrConfig.tencentCloud.lastValidationError, "云端识别验证失败，请检查配置或网络后重试")
        service.validate(input, force: true)
        await waitUntil { service.status == .failed }
        XCTAssertEqual(counter.currentValue(), 2)
    }

    @MainActor
    func testCopiedVerifiedStateCannotValidateDifferentCredentials() throws {
        let store = try configuredTencentStore()
        try store.updateCloudValidationState(for: .tencentCloudRealtime, status: .verified)
        let service = CloudASRValidationService(configStore: store)
        let verified = CloudASRValidationInput(platform: .tencentCloudRealtime, asrConfig: store.asrConfig)
        service.syncFromConfig(for: verified)
        var edited = store.asrConfig
        edited.tencentCloud.secretKey = "different-key"
        XCTAssertEqual(service.status(for: CloudASRValidationInput(platform: .tencentCloudRealtime, asrConfig: edited)), .incomplete)
        XCTAssertEqual(service.status(for: verified), .ready)
    }

    @MainActor
    func testRuntimeInvalidationBlocksCachedVerifiedConfiguration() async throws {
        let store = try configuredTencentStore()
        try store.updateCloudValidationState(for: .tencentCloudRealtime, status: .verified)
        let service = CloudASRValidationService(configStore: store, validatorFactory: { _ in StubCloudASRValidator {} })
        let input = CloudASRValidationInput(platform: .tencentCloudRealtime, asrConfig: store.asrConfig)
        service.syncFromConfig(for: input)
        service.invalidateCurrentValidation()
        XCTAssertEqual(service.status(for: input), .failed)
        XCTAssertEqual(store.asrConfig.tencentCloud.validationStatus, .failed)
        service.validate(input)
        XCTAssertEqual(service.status, .failed)
        service.validate(input, force: true)
        await waitUntil { service.status == .ready }
    }

    @MainActor
    private func configuredTencentStore() throws -> ConfigStore {
        let store = ConfigStore(configDirectory: tempDirectory)
        var config = store.asrConfig
        config.selectedPlatform = .tencentCloudRealtime
        config.tencentCloud.appID = "123456"
        config.tencentCloud.secretId = "test-id"
        config.tencentCloud.secretKey = "test-key"
        try store.saveASRConfig(config)
        return store
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < timeout {
            if condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for condition")
    }
}

private struct StubCloudASRValidator: CloudASRValidating {
    let action: @Sendable () async throws -> Void

    init(action: @escaping @Sendable () async throws -> Void) {
        self.action = action
    }

    func validateCredentials() async throws {
        try await action()
    }
}

private final class ValidationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func currentValue() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
