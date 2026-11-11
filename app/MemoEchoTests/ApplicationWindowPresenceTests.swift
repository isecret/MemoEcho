import AppKit
import XCTest
@testable import MemoEcho

@MainActor
final class ApplicationWindowPresenceTests: XCTestCase {
    func testUpdateKeepsDockVisibleAfterSettingsCloseAndRestoresItsWindow() {
        var policies: [NSApplication.ActivationPolicy] = []
        var updateReopens = 0
        let presence = ApplicationWindowPresence(applyPolicy: { policies.append($0) }, restoreWindow: { _ in
            XCTFail("The update should receive the reopen request")
        })
        let delegate = MemoEchoApplicationDelegate()
        delegate.windowPresence = presence
        let settings = NSWindow()
        presence.windowOpened(settings)
        presence.updateSessionOpened { updateReopens += 1 }
        presence.updateSessionOpened { updateReopens += 1 }

        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: settings)

        XCTAssertEqual(policies, [.regular])
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true))
        XCTAssertEqual(updateReopens, 1)
        presence.updateSessionClosed()
        presence.updateSessionClosed()
        XCTAssertEqual(policies, [.regular, .accessory])
        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
    }

    func testFinishingUpdateKeepsSettingsAvailableUntilTheirWindowCloses() {
        var policies: [NSApplication.ActivationPolicy] = []
        var restored: NSWindow?
        let presence = ApplicationWindowPresence(applyPolicy: { policies.append($0) }, restoreWindow: { restored = $0 })
        let settings = NSWindow()
        presence.updateSessionOpened {}
        presence.windowOpened(settings)

        presence.updateSessionClosed()

        XCTAssertEqual(policies, [.regular])
        XCTAssertTrue(presence.reopen())
        XCTAssertTrue(restored === settings)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: settings)
        XCTAssertEqual(policies, [.regular, .accessory])
    }

    func testMultipleWindowsAndRepeatedOpenOnlyChangePolicyAtBoundaries() {
        var policies: [NSApplication.ActivationPolicy] = []
        let presence = ApplicationWindowPresence(applyPolicy: { policies.append($0) }, restoreWindow: { _ in })
        let settings = NSWindow(), onboarding = NSWindow(), hud = NSWindow()
        presence.windowOpened(settings)
        presence.windowOpened(settings)
        presence.windowOpened(onboarding)
        XCTAssertEqual(policies, [.regular])
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: hud)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: settings)
        XCTAssertEqual(policies, [.regular])
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: onboarding)
        XCTAssertEqual(policies, [.regular, .accessory])
        XCTAssertFalse(presence.reopen())
        presence.windowOpened(settings)
        XCTAssertEqual(policies, [.regular, .accessory, .regular])
    }

    func testMinimizationAndAuxiliaryFocusDoNotLoseMostRecentlyUsedWindow() {
        var restored: NSWindow?
        var policies: [NSApplication.ActivationPolicy] = []
        let presence = ApplicationWindowPresence(applyPolicy: { policies.append($0) }, restoreWindow: { restored = $0 })
        let settings = NSWindow(), onboarding = NSWindow(), hud = NSWindow()
        presence.windowOpened(settings)
        presence.windowOpened(onboarding)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: settings)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: hud)
        NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: settings)
        XCTAssertTrue(presence.reopen())
        XCTAssertTrue(restored === settings)
        XCTAssertEqual(policies, [.regular])
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: settings)
        XCTAssertTrue(presence.reopen())
        XCTAssertTrue(restored === onboarding)
    }

    func testDelegateRestoresTrackedWindowAndKeepsMenuBarProcessAlive() {
        var restoreCount = 0
        let presence = ApplicationWindowPresence(applyPolicy: { _ in }, restoreWindow: { _ in restoreCount += 1 })
        let delegate = MemoEchoApplicationDelegate()
        delegate.windowPresence = presence
        let app = NSApplication.shared
        XCTAssertTrue(delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false))
        presence.windowOpened(NSWindow())
        XCTAssertFalse(delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false))
        XCTAssertFalse(delegate.applicationShouldHandleReopen(app, hasVisibleWindows: true))
        XCTAssertEqual(restoreCount, 2)
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(app))
    }
}
