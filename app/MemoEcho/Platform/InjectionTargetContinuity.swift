import AppKit
import ApplicationServices

/// A window target becomes permanently invalid after a detected focus change.
/// It never attempts to activate or restore the destination.
@MainActor
final class InjectionTargetContinuity {
    private var valid = true
    private var check: (() -> Bool)?
    private var activationObserver: NSObjectProtocol?
    private var axObserver: AXObserver?
    private var timer: Timer?

    var isValid: Bool {
        if valid, let check, !check() { invalidate() }
        return valid
    }

    func invalidate() { valid = false }

    static func monitor(target: TextInjectionFocus, check: @escaping () -> Bool) -> InjectionTargetContinuity? {
        guard target.scope == .window, check() else { return nil }
        let monitor = InjectionTargetContinuity()
        monitor.check = check
        var observer: AXObserver?
        guard AXObserverCreate(target.pid, { _, _, _, context in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<InjectionTargetContinuity>.fromOpaque(context).takeUnretainedValue().invalidate()
            }
        }, &observer) == .success, let observer else { return nil }
        let application = AXUIElementCreateApplication(target.pid)
        // If window changes cannot be observed, do not promise a window-bound paste.
        guard AXObserverAddNotification(observer, application, kAXFocusedWindowChangedNotification as CFString,
                                        Unmanaged.passUnretained(monitor).toOpaque()) == .success else { return nil }
        monitor.axObserver = observer
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        monitor.activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak monitor] notification in
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { if pid != target.pid { monitor?.invalidate() } }
        }
        monitor.timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak monitor] _ in
            MainActor.assumeIsolated { _ = monitor?.isValid }
        }
        if let timer = monitor.timer { RunLoop.main.add(timer, forMode: .common) }
        guard monitor.isValid else { return nil }
        return monitor
    }

    isolated deinit {
        timer?.invalidate()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let axObserver { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .commonModes) }
    }
}
