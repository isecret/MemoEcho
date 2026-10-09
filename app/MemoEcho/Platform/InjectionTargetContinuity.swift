import AppKit
import ApplicationServices

/// A window target becomes permanently invalid after a detected focus change.
/// It never attempts to activate or restore the destination.
@MainActor
final class InjectionTargetContinuity {
    private var valid = true
    private var check: (() -> Bool)?
    private let observation = WindowObservation()

    /// Read cached invalidation for menu presentation without performing AX queries.
    var isInvalidated: Bool { !valid }

    var isValid: Bool {
        if valid, let check, !check() { invalidate() }
        return valid
    }

    func invalidate() { valid = false }

    static func monitor(target: TextInjectionFocus, check: @escaping () -> Bool) -> InjectionTargetContinuity? {
        guard target.scope == .window, check() else { return nil }
        let monitor = InjectionTargetContinuity()
        monitor.check = check
        monitor.observation.target = monitor
        var observer: AXObserver?
        guard AXObserverCreate(target.pid, { _, _, _, context in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<WindowObservation>.fromOpaque(context).takeUnretainedValue().target?.invalidate()
            }
        }, &observer) == .success, let observer else { return nil }
        let application = AXUIElementCreateApplication(target.pid)
        // If window changes cannot be observed, do not promise a window-bound paste.
        guard AXObserverAddNotification(observer, application, kAXFocusedWindowChangedNotification as CFString,
                                        Unmanaged.passUnretained(monitor.observation).toOpaque()) == .success else { return nil }
        monitor.observation.axObserver = observer
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        monitor.observation.activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak monitor] notification in
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { if pid != target.pid { monitor?.invalidate() } }
        }
        monitor.observation.timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak monitor] _ in
            MainActor.assumeIsolated { _ = monitor?.isValid }
        }
        if let timer = monitor.observation.timer { RunLoop.main.add(timer, forMode: .common) }
        guard monitor.isValid else { return nil }
        return monitor
    }

    deinit { observation.cancel() }
}

/// Resource access is confined to the main queue. The Sendable owner can cross
/// deinit's executor boundary solely to enqueue cleanup there. Keep it alive
/// until the AX source is removed so its callback context never dangles.
private final class WindowObservation: @unchecked Sendable {
    weak var target: InjectionTargetContinuity?
    var activationObserver: NSObjectProtocol?
    var axObserver: AXObserver?
    var timer: Timer?

    func cancel() {
        DispatchQueue.main.async { [self] in
            timer?.invalidate()
            if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
            if let axObserver { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .commonModes) }
            timer = nil
            activationObserver = nil
            axObserver = nil
        }
    }
}
