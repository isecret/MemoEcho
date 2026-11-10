import AppKit

@MainActor
protocol HUDKeyboardMonitoring: AnyObject {
    func start(onKeyDown: @escaping @MainActor (CGKeyCode, CGEventFlags) -> Bool)
    func stop()
}

/// The tap runs on the main run loop so key handling and session cancellation stay ordered.
@MainActor
final class HUDKeyboardMonitor: HUDKeyboardMonitoring {
    private var activeTap: TapLifetime?
    private var onKeyDown: (@MainActor (CGKeyCode, CGEventFlags) -> Bool)?

    func start(onKeyDown: @escaping @MainActor (CGKeyCode, CGEventFlags) -> Bool) {
        self.onKeyDown = onKeyDown
        guard activeTap == nil else { return }
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let consumed = MainActor.assumeIsolated {
                let monitor = Unmanaged<HUDKeyboardMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = monitor.activeTap?.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                } else if type == .keyDown,
                          monitor.onKeyDown?(CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)), event.flags) == true {
                    return true
                }
                return false
            }
            return consumed ? nil : Unmanaged.passUnretained(event)
        }
        let ref = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: callback, userInfo: ref) else { return }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        activeTap = TapLifetime(tap: tap, source: source)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        onKeyDown = nil
        activeTap = nil
    }
}

/// Invalidation also covers owner teardown, so the tap never outlives its unretained callback target.
private final class TapLifetime {
    let tap: CFMachPort
    let source: CFRunLoopSource
    init(tap: CFMachPort, source: CFRunLoopSource) { self.tap = tap; self.source = source }
    deinit {
        CFMachPortInvalidate(tap)
        CFRunLoopSourceInvalidate(source)
    }
}
