import AppKit
import Sparkle
import XCTest
@testable import MemoEcho

@MainActor
final class AppUpdateServiceTests: XCTestCase {
    func testManualUpdateShowsDockWithoutAddingAnUnreadBadge() throws {
        var policies: [NSApplication.ActivationPolicy] = []
        var badges: [String?] = []
        let presence = ApplicationWindowPresence(applyPolicy: { policies.append($0) }, restoreWindow: { _ in })
        let service = AppUpdateService(windowPresence: presence, setUpdateBadge: { badges.append($0) })
        let update = try makeUpdate()
        let state = try XCTUnwrap(SPUUserUpdateState(coder: UpdateStateCoder(userInitiated: true)))

        service.standardUserDriverWillHandleShowingUpdate(true, forUpdate: update, state: state)

        XCTAssertEqual(policies, [.regular])
        XCTAssertTrue(badges.isEmpty)
        service.standardUserDriverWillFinishUpdateSession()
        XCTAssertEqual(policies, [.regular, .accessory])
        XCTAssertEqual(badges, [nil])
    }

    func testScheduledUpdateProvidesVisibleDockReminderAndCleansUpWhenFinished() throws {
        let application = NSApplication.shared
        let previousPolicy = application.activationPolicy()
        let previousBadge = application.dockTile.badgeLabel
        defer {
            application.setActivationPolicy(previousPolicy)
            application.dockTile.badgeLabel = previousBadge
        }
        application.setActivationPolicy(.accessory)
        application.dockTile.badgeLabel = nil
        let service = AppUpdateService()
        let delegate = try XCTUnwrap(service as AnyObject as? SPUStandardUserDriverDelegate)
        let update = try makeUpdate()
        let state = try XCTUnwrap(SPUUserUpdateState(coder: UpdateStateCoder(userInitiated: false)))

        XCTAssertEqual(delegate.supportsGentleScheduledUpdateReminders, true)
        delegate.standardUserDriverWillHandleShowingUpdate?(true, forUpdate: update, state: state)

        XCTAssertEqual(application.activationPolicy(), .regular)
        XCTAssertEqual(application.dockTile.badgeLabel, "1")
        delegate.standardUserDriverDidReceiveUserAttention?(forUpdate: update)
        XCTAssertNil(application.dockTile.badgeLabel)
        XCTAssertEqual(application.activationPolicy(), .regular)
        delegate.standardUserDriverWillFinishUpdateSession?()
        XCTAssertEqual(application.activationPolicy(), .accessory)
    }

    private func makeUpdate() throws -> SUAppcastItem {
        try XCTUnwrap(SUAppcastItem(dictionary: [
            "title": "Test update",
            "enclosure": ["url": "https://example.com/update.zip", "sparkle:version": "99.0"]
        ]))
    }

    func testDebugInstallationCannotUsePublicUpdateFeed() {
        #if DEBUG
        XCTAssertEqual(Bundle.main.bundleIdentifier, "me.wangmao.memoecho.debug")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "MemoEcho Dev")
        let service = AppUpdateService()
        service.start()
        service.setAutomaticallyChecksForUpdates(true)
        service.checkForUpdates()
        XCTAssertFalse(service.isAvailable)
        XCTAssertFalse(service.canCheckForUpdates)
        XCTAssertFalse(service.automaticallyChecksForUpdates)
        #endif
    }
}

private final class UpdateStateCoder: NSCoder {
    let userInitiated: Bool

    init(userInitiated: Bool) { self.userInitiated = userInitiated }

    override var allowsKeyedCoding: Bool { true }

    override func decodeInteger(forKey key: String) -> Int {
        SPUUserUpdateStage.notDownloaded.rawValue
    }

    override func decodeBool(forKey key: String) -> Bool { userInitiated }
}
