import Foundation
import XCTest
@testable import MemoEcho

@MainActor
final class ModelDownloadManagerTests: XCTestCase {
    func testProgressDoesNotFallBackToHalfAfterLargeModelFileCompletes() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoEchoModelProgressTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let configRoot = fixtureRoot.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
        try Data(#"{"onboarding":{}}"#.utf8).write(to: configRoot.appendingPathComponent("config.json"))
        let configStore = ConfigStore(configDirectory: configRoot)

        var finishModel: CheckedContinuation<Void, Never>?
        var finishTokens: CheckedContinuation<Void, Never>?
        let manager = ModelDownloadManager(
            configStore: configStore,
            modelRoot: fixtureRoot.appendingPathComponent("models", isDirectory: true),
            downloadTransport: { remoteURL, report in
                if remoteURL.lastPathComponent == LocalASRConfig.modelFileName {
                    report(95, 100)
                    await withCheckedContinuation { finishModel = $0 }
                    let tempURL = fixtureRoot.appendingPathComponent("model.download")
                    try Data(repeating: 1, count: 100).write(to: tempURL)
                    return tempURL
                }
                report(1, 10)
                await withCheckedContinuation { finishTokens = $0 }
                let tempURL = fixtureRoot.appendingPathComponent("tokens.download")
                try Data("token".utf8).write(to: tempURL)
                return tempURL
            }
        )

        manager.startDownload()
        await waitUntil { finishModel != nil && manager.progress >= 0.95 }
        let nearCompleteProgress = manager.progress
        finishModel?.resume()
        finishModel = nil
        await waitUntil { finishTokens != nil }

        XCTAssertGreaterThanOrEqual(manager.progress, nearCompleteProgress,
                                    "Completing the large model file must not send the onboarding indicator back to 50%")

        finishTokens?.resume()
        finishTokens = nil
        await waitUntil { !manager.isDownloading }
        XCTAssertEqual(manager.progress, 1)
    }

    func testExistingLargeModelDoesNotDropWhenTokensBeginDownloading() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoEchoModelProgressTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let configRoot = fixtureRoot.appendingPathComponent("config", isDirectory: true)
        let modelRoot = fixtureRoot.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: modelRoot, withIntermediateDirectories: true)
        try Data(#"{"onboarding":{}}"#.utf8).write(to: configRoot.appendingPathComponent("config.json"))
        try Data(repeating: 1, count: 100).write(to: modelRoot.appendingPathComponent(LocalASRConfig.modelFileName))
        let configStore = ConfigStore(configDirectory: configRoot)

        var finishTokens: CheckedContinuation<Void, Never>?
        let manager = ModelDownloadManager(
            configStore: configStore,
            modelRoot: modelRoot,
            downloadTransport: { _, report in
                report(1, 10)
                await withCheckedContinuation { finishTokens = $0 }
                let tempURL = fixtureRoot.appendingPathComponent("tokens.download")
                try Data("token".utf8).write(to: tempURL)
                return tempURL
            }
        )

        manager.startDownload()
        await waitUntil { finishTokens != nil }
        XCTAssertGreaterThan(manager.progress, 0.9,
                             "An existing large model must count toward the aggregate before tokens start")

        finishTokens?.resume()
        finishTokens = nil
        await waitUntil { !manager.isDownloading }
        XCTAssertEqual(manager.progress, 1)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for a controlled download stage")
    }
}
