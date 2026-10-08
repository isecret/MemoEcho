import AppKit
import XCTest
@testable import MemoEcho

@MainActor
final class ApplicationWindowPresenceTests: XCTestCase {
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
