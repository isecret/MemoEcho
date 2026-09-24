import AppKit
import SwiftUI
import XCTest
@testable import MemoEcho

final class PermissionsManagerTests: XCTestCase {
    @MainActor
    func testNewInstallDoesNotQueryAccessibilityBeforeDraggingAppIntoSettings() {
        let system = PermissionOperationsStub()
        let manager = PermissionsManager(operations: system.operations)

        manager.refreshAll()
        manager.applicationDidBecomeActive()
        manager.promptAndOpenAccessibilitySettings()

        XCTAssertEqual(system.accessibilityChecks, 0)
    }

    @MainActor
    func testVoiceInputChecksAccessibilityOnceWithoutEnablingBackgroundQueries() {
        let system = PermissionOperationsStub()
        system.accessibility = .granted
        let manager = PermissionsManager(operations: system.operations)

        manager.checkAccessibilityPermissionForVoiceInput()
        manager.refreshAll()
        manager.applicationDidBecomeActive()

        XCTAssertEqual(system.accessibilityChecks, 1)
        XCTAssertEqual(manager.accessibilityStatus, .granted)
    }

    @MainActor
    func testAccessibilityChecksBeginAfterAppIsDraggedIntoSettings() {
        let system = PermissionOperationsStub()
        let manager = PermissionsManager(operations: system.operations)
        var grants = 0
        manager.onAccessibilityGranted = { grants += 1 }

        manager.promptAndOpenAccessibilitySettings()
        manager.beginAccessibilityStatusChecksAfterDrag()
        XCTAssertEqual(system.accessibilityChecks, 1)
        XCTAssertEqual(manager.accessibilityStatus, .requiresManualEnable)

        system.accessibility = .granted
        manager.refreshAll()
        XCTAssertEqual(manager.accessibilityStatus, .granted)
        XCTAssertEqual(grants, 1)
    }

    @MainActor
    func testUndeterminedMicrophoneRequestsOnceAndRefreshesGrantedResult() async {
        let system = PermissionOperationsStub()
        let manager = PermissionsManager(operations: system.operations)

        await manager.requestMicrophonePermission()
        await manager.requestMicrophonePermission()

        XCTAssertEqual(system.microphoneRequests, 1)
        XCTAssertEqual(manager.microphoneStatus, .granted)
        XCTAssertFalse(manager.isRequestingMicrophonePermission)
        XCTAssertFalse(manager.isHandlingAuthorization)
    }

    @MainActor
    func testMicrophonePromptRestoresOriginAfterBrowserBecomesFrontmost() async {
        let system = PermissionOperationsStub()
        var frontmost = "MemoEcho"
        var restores = 0
        system.onMicrophoneRequest = { frontmost = "Browser" }
        let focus = MicrophoneAuthorizationFocusRestorer(operations: .init(
            isAppActive: { frontmost == "MemoEcho" },
            captureOriginRestore: {
                { restores += 1; frontmost = "MemoEcho" }
            }
        ))
        let manager = PermissionsManager(operations: system.operations)
        manager.onMicrophoneAuthorizationStarted = { source in focus.began(source: source) }
        manager.onMicrophoneAuthorizationFinished = { focus.finished() }

        await manager.requestMicrophonePermission()

        XCTAssertEqual(frontmost, "MemoEcho")
        XCTAssertEqual(restores, 1)
    }

    @MainActor
    func testMicrophonePromptDoesNotStealFocusWhenStartedOutsideApp() async {
        let system = PermissionOperationsStub()
        var frontmost = "Browser"
        var restores = 0
        let focus = MicrophoneAuthorizationFocusRestorer(operations: .init(
            isAppActive: { frontmost == "MemoEcho" },
            captureOriginRestore: { { restores += 1; frontmost = "MemoEcho" } }
        ))
        let manager = PermissionsManager(operations: system.operations)
        manager.onMicrophoneAuthorizationStarted = { source in focus.began(source: source) }
        manager.onMicrophoneAuthorizationFinished = { focus.finished() }

        await manager.requestMicrophonePermission()

        XCTAssertEqual(frontmost, "Browser")
        XCTAssertEqual(restores, 0)
    }

    @MainActor
    func testMicrophonePromptRestoresOriginIfSystemSettingsTakesFocusAfterCallback() async {
        let system = PermissionOperationsStub()
        var frontmost = "MemoEcho"
        var restores = 0
        let focus = MicrophoneAuthorizationFocusRestorer(operations: .init(
            isAppActive: { frontmost == "MemoEcho" },
            captureOriginRestore: {
                { restores += 1; frontmost = "MemoEcho" }
            }
        ))
        let manager = PermissionsManager(operations: system.operations)
        manager.onMicrophoneAuthorizationStarted = { source in focus.began(source: source) }
        manager.onMicrophoneAuthorizationFinished = { focus.finished() }

        await manager.requestMicrophonePermission()
        frontmost = "System Settings"
        try? await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(frontmost, "MemoEcho")
        XCTAssertEqual(restores, 1)
    }

    @MainActor
    func testMicrophonePromptRestoresOriginIfBrowserTakesFocusJustAfterCallback() async {
        let system = PermissionOperationsStub()
        var frontmost = "MemoEcho"
        var restores = 0
        let focus = MicrophoneAuthorizationFocusRestorer(operations: .init(
            isAppActive: { frontmost == "MemoEcho" },
            captureOriginRestore: { { restores += 1; frontmost = "MemoEcho" } }
        ))
        let manager = PermissionsManager(operations: system.operations)
        manager.onMicrophoneAuthorizationStarted = { source in focus.began(source: source) }
        manager.onMicrophoneAuthorizationFinished = { focus.finished() }

        await manager.requestMicrophonePermission()
        frontmost = "Browser"
        try? await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(frontmost, "MemoEcho")
        XCTAssertEqual(restores, 1)
    }

    @MainActor
    func testMicrophonePromptRestoresOriginIfBrowserTakesFocusAfterSettingsRefresh() async {
        let system = PermissionOperationsStub()
        var frontmost = "MemoEcho"
        var restores = 0
        let focus = MicrophoneAuthorizationFocusRestorer(operations: .init(
            isAppActive: { frontmost == "MemoEcho" },
            captureOriginRestore: { { restores += 1; frontmost = "MemoEcho" } }
        ))
        let manager = PermissionsManager(operations: system.operations)
        manager.onMicrophoneAuthorizationStarted = { source in focus.began(source: source) }
        manager.onMicrophoneAuthorizationFinished = { focus.finished() }

        await manager.requestMicrophonePermission(source: .settings)
        // The settings page may refresh its permission row before macOS restores
        // the previously frontmost browser after the native permission alert.
        try? await Task.sleep(for: .milliseconds(600))
        frontmost = "Browser"
        try? await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(frontmost, "MemoEcho")
        XCTAssertEqual(restores, 1)
    }

    @MainActor
    func testSettingsMicrophonePromptDoesNotStealFocusAfterObservationWindow() async {
        let system = PermissionOperationsStub()
        var frontmost = "MemoEcho"
        var restores = 0
        let focus = MicrophoneAuthorizationFocusRestorer(operations: .init(
            isAppActive: { frontmost == "MemoEcho" },
            captureOriginRestore: { { restores += 1; frontmost = "MemoEcho" } }
        ))
        let manager = PermissionsManager(operations: system.operations)
        manager.onMicrophoneAuthorizationStarted = { source in focus.began(source: source) }
        manager.onMicrophoneAuthorizationFinished = { focus.finished() }

        await manager.requestMicrophonePermission(source: .settings)
        try? await Task.sleep(for: .milliseconds(1_200))
        frontmost = "Browser"
        try? await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(frontmost, "Browser")
        XCTAssertEqual(restores, 0)
    }

    @MainActor
    func testMicrophonePromptDoesNotStealFocusAfterLaterBrowserSwitch() async {
        let system = PermissionOperationsStub()
        var frontmost = "MemoEcho"
        var restores = 0
        let focus = MicrophoneAuthorizationFocusRestorer(operations: .init(
            isAppActive: { frontmost == "MemoEcho" },
            captureOriginRestore: { { restores += 1; frontmost = "MemoEcho" } }
        ))
        let manager = PermissionsManager(operations: system.operations)
        manager.onMicrophoneAuthorizationStarted = { source in focus.began(source: source) }
        manager.onMicrophoneAuthorizationFinished = { focus.finished() }

        await manager.requestMicrophonePermission()
        try? await Task.sleep(for: .milliseconds(700))
        frontmost = "Browser"
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(frontmost, "Browser")
        XCTAssertEqual(restores, 0)
    }

    @MainActor
    func testDeniedMicrophoneOpensSettingsWithoutRequestingAnotherSystemPrompt() async {
        let system = PermissionOperationsStub()
        system.requestResult = .denied
        let manager = PermissionsManager(operations: system.operations)

        await manager.requestMicrophonePermission()
        await manager.requestMicrophonePermission()
        manager.openMicrophoneSettings()
        manager.openMicrophoneSettings()

        XCTAssertEqual(manager.microphoneStatus, .denied)
        XCTAssertEqual(system.microphoneRequests, 1)
        XCTAssertEqual(system.microphoneSettingsOpens, 1)
        XCTAssertTrue(manager.isHandlingAuthorization)
    }

    @MainActor
    func testRestrictedMicrophoneNeverRequestsOrOpensSettings() async {
        let system = PermissionOperationsStub()
        system.microphone = .restricted
        let manager = PermissionsManager(operations: system.operations)

        await manager.requestMicrophonePermission()
        manager.openMicrophoneSettings()

        XCTAssertEqual(manager.microphoneStatus, .restricted)
        XCTAssertEqual(system.microphoneRequests, 0)
        XCTAssertEqual(system.microphoneSettingsOpens, 0)
        XCTAssertFalse(manager.isHandlingAuthorization)
        XCTAssertThrowsError(try manager.ensureMicrophoneAuthorized())
    }

    @MainActor
    func testMicrophonePromptBlocksRepeatedAccessibilityGuide() async {
        let system = PermissionOperationsStub()
        system.holdMicrophoneRequest = true
        let manager = PermissionsManager(operations: system.operations)
        let request = Task { await manager.requestMicrophonePermission() }
        await waitUntil { system.requestContinuation != nil }

        await manager.requestMicrophonePermission()
        manager.promptAndOpenAccessibilitySettings()
        XCTAssertEqual(system.microphoneRequests, 1)
        XCTAssertTrue(manager.isRequestingMicrophonePermission)

        system.requestContinuation?.resume()
        system.requestContinuation = nil
        await request.value
        manager.promptAndOpenAccessibilitySettings()
        manager.promptAndOpenAccessibilitySettings()
        XCTAssertEqual(system.accessibilitySettingsOpens, 1)
    }

    @MainActor
    func testAccessibilityFlowBlocksMicrophoneUntilReturningToApp() async {
        let system = PermissionOperationsStub()
        let manager = PermissionsManager(operations: system.operations)
        manager.promptAndOpenAccessibilitySettings()
        await manager.requestMicrophonePermission()
        XCTAssertEqual(system.microphoneRequests, 0)

        manager.applicationDidResignActive()
        manager.applicationDidBecomeActive()
        XCTAssertFalse(manager.isHandlingAuthorization)
        await manager.requestMicrophonePermission()
        XCTAssertEqual(system.microphoneRequests, 1)
    }

    @MainActor
    func testReturnFromSettingsRefreshesRevocationsAndAllowsRetryWhenStillDenied() {
        let system = PermissionOperationsStub()
        system.microphone = .denied
        let manager = PermissionsManager(operations: system.operations, accessibilityStatusQueryEnabled: true)
        manager.openMicrophoneSettings()
        manager.applicationDidResignActive()
        manager.applicationDidBecomeActive()
        manager.openMicrophoneSettings()
        XCTAssertEqual(system.microphoneSettingsOpens, 2)

        manager.applicationDidResignActive()
        system.microphone = .granted
        system.accessibility = .granted
        manager.applicationDidBecomeActive()
        XCTAssertEqual(manager.microphoneStatus, .granted)
        XCTAssertEqual(manager.accessibilityStatus, .granted)
        XCTAssertFalse(manager.isHandlingAuthorization)

        system.microphone = .denied
        system.accessibility = .requiresManualEnable
        manager.refreshAll()
        XCTAssertEqual(manager.microphoneStatus, .denied)
        XCTAssertEqual(manager.accessibilityStatus, .requiresManualEnable)
        XCTAssertThrowsError(try manager.ensureAccessibilityAuthorized())
    }

    @MainActor
    func testGrantedAccessibilityDoesNotOpenAnotherAuthorizationFlow() {
        let system = PermissionOperationsStub()
        system.accessibility = .granted
        let manager = PermissionsManager(operations: system.operations, accessibilityStatusQueryEnabled: true)
        manager.promptAndOpenAccessibilitySettings()
        XCTAssertEqual(system.accessibilitySettingsOpens, 0)
        XCTAssertFalse(manager.isHandlingAuthorization)
    }

    @MainActor
    func testGuideFailureReleasesLockAndAllowsRetry() {
        let system = PermissionOperationsStub()
        let manager = PermissionsManager(operations: system.operations)
        var requests = 0
        manager.onAccessibilityGuideRequested = {
            requests += 1
            return requests > 1
        }

        manager.promptAndOpenAccessibilitySettings()
        XCTAssertFalse(manager.isHandlingAuthorization)
        XCTAssertNotNil(manager.accessibilityGuideError)
        manager.promptAndOpenAccessibilitySettings()
        XCTAssertEqual(requests, 2)
        XCTAssertTrue(manager.isHandlingAuthorization)
        XCTAssertNil(manager.accessibilityGuideError)
        manager.cancelAccessibilityGuide()
        XCTAssertFalse(manager.isHandlingAuthorization)
    }

    @MainActor
    func testGrantCallbackOnlyRunsOnTransition() {
        let system = PermissionOperationsStub()
        let manager = PermissionsManager(operations: system.operations, accessibilityStatusQueryEnabled: true)
        var grants = 0
        manager.onAccessibilityGranted = { grants += 1 }
        system.accessibility = .granted
        manager.refreshAll()
        manager.refreshAll()
        XCTAssertEqual(grants, 1)
    }

    @MainActor
    func testGuideStartsNearSettingsBottomAndClampsToVisibleScreen() {
        let area = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let guide = NSSize(width: 320, height: 142)
        let centered = AccessibilityAuthorizationGuideController.panelOrigin(
            for: NSRect(x: 200, y: 100, width: 800, height: 600),
            visibleFrame: area, size: guide
        )
        XCTAssertEqual(centered, NSPoint(x: 440, y: 124))

        let clamped = AccessibilityAuthorizationGuideController.panelOrigin(
            for: NSRect(x: 0, y: 0, width: 220, height: 700),
            visibleFrame: area, size: guide
        )
        XCTAssertEqual(clamped, NSPoint(x: 0, y: 24))
    }

    @MainActor
    func testAccessibilityGuideIconStartsDraggingApplicationFileOnMouseMove() {
        let appURL = URL(fileURLWithPath: "/tmp/MemoEcho.app")
        let view = ApplicationDragSourceView(appURL: appURL)
        view.frame = NSRect(x: 0, y: 0, width: 60, height: 60)
        var draggedURL: URL?
        view.onBeginDrag = { item, _ in draggedURL = (item.item as? URL) }
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let moved = NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 10, y: 10),
                                       modifierFlags: [], timestamp: 0.1, windowNumber: 0, context: nil,
                                       eventNumber: 2, clickCount: 1, pressure: 1)!

        view.mouseDown(with: down)
        view.mouseDragged(with: moved)

        XCTAssertEqual(draggedURL, appURL)
        XCTAssertFalse(view.mouseDownCanMoveWindow)
    }

    @MainActor
    func testGuideClosesAfterDraggingIntoSystemSettingsEvenIfDropIsNotAccepted() {
        let settingsFrame = NSRect(x: 100, y: 100, width: 600, height: 500)
        XCTAssertTrue(AccessibilityAuthorizationGuideController.shouldDismissAfterDrop(
            at: NSPoint(x: 300, y: 300), operation: [], settingsFrame: settingsFrame
        ))
        XCTAssertFalse(AccessibilityAuthorizationGuideController.shouldDismissAfterDrop(
            at: NSPoint(x: 800, y: 300), operation: .copy, settingsFrame: settingsFrame
        ))
        XCTAssertFalse(AccessibilityAuthorizationGuideController.shouldDismissAfterDrop(
            at: NSPoint(x: 300, y: 300), operation: .copy, settingsFrame: nil
        ))
        XCTAssertTrue(AccessibilityAuthorizationGuideController.shouldDismissAfterDrop(
            at: NSPoint(x: 300, y: 300), operation: .copy, settingsFrame: nil, settingsIsFrontmost: true
        ))
    }

    @MainActor
    func testApplicationDragSourceReportsFinishedDrag() {
        let view = ApplicationDragSourceView(appURL: URL(fileURLWithPath: "/tmp/MemoEcho.app"))
        var reportedPoint: NSPoint?
        var reportedOperation: NSDragOperation?
        view.onDragEnded = { point, operation in
            reportedPoint = point
            reportedOperation = operation
        }

        view.completeDrag(at: NSPoint(x: 120, y: 240), operation: .copy)

        XCTAssertEqual(reportedPoint, NSPoint(x: 120, y: 240))
        XCTAssertEqual(reportedOperation, .copy)
    }

    @MainActor
    func testAccessibilityGuideBackgroundHasDedicatedWindowDragSurface() {
        let panel = NSPanel(contentRect: NSRect(origin: NSPoint(x: 200, y: 200), size: AccessibilityGuideView.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: AccessibilityGuideView(
            appURL: Bundle.main.bundleURL, onClose: {}
        ))
        panel.contentView = host
        panel.orderFrontRegardless()
        defer { panel.close() }
        host.layoutSubtreeIfNeeded()
        for point in [NSPoint(x: 150, y: 75), NSPoint(x: 40, y: 70),
                      NSPoint(x: 180, y: 41), NSPoint(x: 150, y: 10)] {
            let hit = host.hitTest(point)
            XCTAssertEqual(hit.map { String(describing: type(of: $0)) }, "WindowDragSurfaceView",
                           "Window should be draggable at \(point)")
        }
        XCTAssertTrue(host.hitTest(NSPoint(x: 40, y: 40)) is ApplicationDragSourceView,
                      "The application icon should be directly draggable")
    }

    @MainActor
    func testAccessibilityGuideBackgroundForwardsMouseDownToWindowDrag() {
        let panel = WindowDragSpyPanel(contentRect: NSRect(x: 200, y: 200, width: 284, height: 108),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let view = WindowDragSurfaceView()
        panel.contentView = view
        defer { panel.close() }
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!

        view.mouseDown(with: down)

        XCTAssertTrue(view.acceptsFirstMouse(for: down))
        XCTAssertTrue(panel.didPerformDrag)
    }

    @MainActor
    private func waitUntil(condition: @escaping @MainActor () -> Bool) async {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < .seconds(1) {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for stub authorization request")
    }
}

@MainActor
private final class WindowDragSpyPanel: NSPanel {
    var didPerformDrag = false

    override func performDrag(with event: NSEvent) {
        didPerformDrag = true
    }
}

@MainActor
private final class PermissionOperationsStub {
    var microphone: MicrophonePermission = .notDetermined
    var accessibility: AccessibilityPermission = .requiresManualEnable
    var requestResult: MicrophonePermission = .granted
    var holdMicrophoneRequest = false
    var onMicrophoneRequest: (() -> Void)?
    var requestContinuation: CheckedContinuation<Void, Never>?
    var microphoneRequests = 0
    var microphoneSettingsOpens = 0
    var accessibilitySettingsOpens = 0
    var accessibilityChecks = 0

    var operations: PermissionsManager.Operations {
        PermissionsManager.Operations(
            microphoneStatus: { self.microphone },
            accessibilityStatus: {
                self.accessibilityChecks += 1
                return self.accessibility
            },
            requestMicrophone: {
                self.microphoneRequests += 1
                self.onMicrophoneRequest?()
                if self.holdMicrophoneRequest {
                    await withCheckedContinuation { self.requestContinuation = $0 }
                }
                self.microphone = self.requestResult
            },
            openMicrophoneSettings: { self.microphoneSettingsOpens += 1 },
            openAccessibilitySettings: { self.accessibilitySettingsOpens += 1 }
        )
    }
}
