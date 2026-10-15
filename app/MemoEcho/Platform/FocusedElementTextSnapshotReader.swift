import ApplicationServices
import AppKit
import Foundation

/// Retains the AX reference for identity comparisons only; background readers resolve their own AX object.
struct FocusedElementIdentity: @unchecked Sendable, Equatable {
    private let element: AXUIElement?
    private let token: String?

    init(element: AXUIElement) { self.element = element; token = nil }
    init(token: String) { element = nil; self.token = token }

    static func == (lhs: Self, rhs: Self) -> Bool {
        if let left = lhs.element, let right = rhs.element { return CFEqual(left, right) }
        return lhs.element == nil && rhs.element == nil && lhs.token == rhs.token
    }
}

struct FocusedElementTextSnapshot: Sendable, Equatable {
    let pid: pid_t
    let bundleID: String?
    let identity: FocusedElementIdentity
    let value: String
    let selection: NSRange
    let isComposing: Bool

    func belongsToSameField(as other: Self) -> Bool {
        pid == other.pid && bundleID == other.bundleID && identity == other.identity
    }
}

struct FocusedElementTextSnapshotReader: Sendable {
    enum ReadFailure: String {
        case permissionDenied, missingTarget, appNotFrontmost, unresolvedField
        case secureField, notWritable, valueUnavailable, valueTooLarge
        case selectionUnavailable, selectionOutOfBounds, bundleChanged
    }
    private let resolver = FocusedElementResolver()

    /// The lightweight delivery check must work even when AXValue is unavailable or expensive.
    static func isComposing(_ element: AXUIElement) -> Bool {
        let marked = Self().range(element, "AXMarkedTextRange")
        return marked.map { $0.location != NSNotFound && $0.length > 0 } ?? false
    }

    /// Called only by the bounded background worker. Never activate apps or read another field.
    func readBeforeInjection(target: TextInjectionFocus,
                             shouldStop: @escaping @Sendable () -> Bool) -> FocusedElementTextSnapshot? {
        guard target.scope == .field, !shouldStop(), AXIsProcessTrusted() else { return nil }
        let reader = BeforeInjectionReader(shouldStop: shouldStop)
        let application = AXUIElementCreateApplication(target.pid)
        guard let element = reader.element(application, kAXFocusedUIElementAttribute),
              FocusedElementIdentity(element: element) == target.identity,
              reader.string(element, kAXSubroleAttribute) != kAXSecureTextFieldSubrole,
              reader.writable(element, kAXSelectedTextAttribute) || reader.writable(element, kAXValueAttribute),
              let selection = reader.range(element, kAXSelectedTextRangeAttribute),
              !reader.isComposing(element),
              let value = reader.string(element, kAXValueAttribute), value.utf16.count <= 100_000,
              Range(selection, in: value) != nil,
              reader.range(element, kAXSelectedTextRangeAttribute) == selection,
              !reader.isComposing(element),
              let finalFocus = reader.element(application, kAXFocusedUIElementAttribute),
              FocusedElementIdentity(element: finalFocus) == target.identity,
              !shouldStop() else { return nil }
        return .init(pid: target.pid, bundleID: target.bundleID, identity: target.identity,
                     value: value, selection: selection, isComposing: false)
    }

    @MainActor
    func read(targetPID: pid_t?, targetBundleID: String?,
              onFailure: ((ReadFailure) -> Void)? = nil) -> FocusedElementTextSnapshot? {
        func fail(_ reason: ReadFailure) -> FocusedElementTextSnapshot? { onFailure?(reason); return nil }
        guard AXIsProcessTrusted() else { return fail(.permissionDenied) }
        guard let targetPID else { return fail(.missingTarget) }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else { return fail(.appNotFrontmost) }
        guard let resolved = resolver.resolveFocusedElement(targetPID: targetPID, shouldRestoreTargetApplication: false)
        else { return fail(.unresolvedField) }
        let element = resolved.element
        // Secure fields never enter the learning pipeline.
        guard string(element, kAXSubroleAttribute) != kAXSecureTextFieldSubrole else { return fail(.secureField) }
        guard isWritable(element, kAXSelectedTextAttribute) || isWritable(element, kAXValueAttribute) else { return fail(.notWritable) }
        guard let value = string(element, kAXValueAttribute) else { return fail(.valueUnavailable) }
        guard value.utf16.count <= 100_000 else { return fail(.valueTooLarge) }
        guard let selection = range(element, kAXSelectedTextRangeAttribute) else { return fail(.selectionUnavailable) }
        guard Range(selection, in: value) != nil else { return fail(.selectionOutOfBounds) }
        let bundleID = resolved.bundleID ?? targetBundleID
        guard targetBundleID == nil || bundleID == targetBundleID else { return fail(.bundleChanged) }
        // Some AX implementations expose marked text; absence is not proof of commitment.
        let marked = range(element, "AXMarkedTextRange")
        return .init(pid: targetPID, bundleID: bundleID, identity: .init(element: element),
                     value: value, selection: selection,
                     isComposing: marked.map { $0.location != NSNotFound && $0.length > 0 } ?? false)
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func isWritable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var writable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &writable) == .success && writable.boolValue
    }

    private func range(_ element: AXUIElement, _ attribute: String) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
}

private struct BeforeInjectionReader {
    let shouldStop: @Sendable () -> Bool

    func prepare(_ element: AXUIElement) -> Bool {
        guard !shouldStop() else { return false }
        // Object-level timeout only; never change the process-wide AX timeout.
        AXUIElementSetMessagingTimeout(element, 0.05)
        return true
    }

    func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        guard prepare(element) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              !shouldStop() else { return nil }
        return value
    }

    func string(_ element: AXUIElement, _ attribute: String) -> String? { value(element, attribute) as? String }

    func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return value as! AXUIElement
    }

    func writable(_ element: AXUIElement, _ attribute: String) -> Bool {
        guard prepare(element) else { return false }
        var writable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &writable) == .success
            && writable.boolValue && !shouldStop()
    }

    func range(_ element: AXUIElement, _ attribute: String) -> NSRange? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0,
              range.location <= Int.max - range.length else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    func isComposing(_ element: AXUIElement) -> Bool {
        range(element, "AXMarkedTextRange").map { $0.location != NSNotFound && $0.length > 0 } ?? false
    }
}

/// A nonwaiting handoff. Taking a result closes the request before the paste event is posted.
final class InjectionLearningSnapshotCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let deadline: ContinuousClock.Instant
    private var closed = false
    private var completed = false
    private var snapshot: FocusedElementTextSnapshot?

    init(timeout: TimeInterval = 0.15) {
        deadline = .now.advanced(by: .seconds(timeout))
    }

    var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed || completed || .now >= deadline
    }

    func complete(_ snapshot: FocusedElementTextSnapshot?) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, !completed, .now < deadline else { return }
        completed = true
        self.snapshot = snapshot
    }

    func takeReadySnapshot() -> FocusedElementTextSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return nil }
        closed = true
        defer { snapshot = nil }
        return completed && .now < deadline ? snapshot : nil
    }

    func cancel() {
        lock.lock()
        closed = true
        snapshot = nil
        lock.unlock()
    }
}

/// A blocked AX call holds the sole worker slot until it returns, even after the request closes.
/// Subsequent injections skip learning rather than accumulate background calls or wait for them.
final class InjectionLearningSnapshotWorker: @unchecked Sendable {
    static let shared = InjectionLearningSnapshotWorker()
    private let queue = DispatchQueue(label: "me.wangmao.memoecho.injection-learning", qos: .utility)
    private let lock = NSLock()
    private var busy = false

    func begin(timeout: TimeInterval = 0.15,
               read: @escaping @Sendable (@escaping @Sendable () -> Bool) -> FocusedElementTextSnapshot?
    ) -> InjectionLearningSnapshotCapture? {
        lock.lock()
        guard !busy else { lock.unlock(); return nil }
        busy = true
        lock.unlock()
        let capture = InjectionLearningSnapshotCapture(timeout: timeout)
        queue.async { [self] in
            defer {
                lock.lock()
                busy = false
                lock.unlock()
            }
            guard !capture.shouldStop else { return }
            let snapshot = read { capture.shouldStop }
            capture.complete(snapshot)
        }
        return capture
    }
}
