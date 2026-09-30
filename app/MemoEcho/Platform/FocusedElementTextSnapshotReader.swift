import ApplicationServices
import AppKit
import Foundation

/// Retains the AX reference for identity comparisons only; AX access stays on MainActor.
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
