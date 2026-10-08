import AppKit

/// Tracks only user-facing settings/setup windows, never HUDs or permission panels.
@MainActor
final class ApplicationWindowPresence: NSObject {
    private var windows: [NSWindow] = []
    private let applyPolicy: (NSApplication.ActivationPolicy) -> Void
    private let restoreWindow: (NSWindow) -> Void

    init(
        applyPolicy: @escaping (NSApplication.ActivationPolicy) -> Void = { NSApp.setActivationPolicy($0) },
        restoreWindow: @escaping (NSWindow) -> Void = {
            if $0.isMiniaturized { $0.deminiaturize(nil) }
            $0.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    ) {
        self.applyPolicy = applyPolicy
        self.restoreWindow = restoreWindow
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
                                               name: NSWindow.willCloseNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeKey(_:)),
                                               name: NSWindow.didBecomeKeyNotification, object: nil)
    }

    /// Called before presentation; closed controllers may reuse their original window.
    func windowOpened(_ window: NSWindow) {
        let wasEmpty = windows.isEmpty
        windows.removeAll { $0 === window }
        windows.append(window)
        if wasEmpty { applyPolicy(.regular) }
    }

    @discardableResult
    func reopen() -> Bool {
        guard let window = windows.last else { return false }
        restoreWindow(window)
        return true
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              windows.contains(where: { $0 === window }) else { return }
        windows.removeAll { $0 === window }
        if windows.isEmpty { applyPolicy(.accessory) }
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              windows.contains(where: { $0 === window }) else { return }
        windows.removeAll { $0 === window }
        windows.append(window)
    }
}

@MainActor
final class MemoEchoApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var windowPresence: ApplicationWindowPresence?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Explicitly restore minimized tracked windows; do not create an unrelated window.
        !(windowPresence?.reopen() ?? false)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
