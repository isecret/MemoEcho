import ApplicationServices
import AppKit
import Carbon
import CoreGraphics
import Foundation

/// A destination identity can be captured even when the app cannot expose readable text.
struct TextInjectionFocus: Sendable {
    let pid: pid_t
    let bundleID: String?
    let identity: FocusedElementIdentity
    let snapshot: FocusedElementTextSnapshot?
    enum Scope: Sendable { case field, window }
    var scope: Scope = .field
    var continuity: InjectionTargetContinuity? = nil
    var requiresVerification = false

    func isSameField(as other: Self) -> Bool {
        pid == other.pid && bundleID == other.bundleID && scope == other.scope && identity == other.identity
    }
}

typealias InjectionPasteboardSnapshot = [[NSPasteboard.PasteboardType: Data]]

@MainActor
protocol InjectionPasteboard: AnyObject {
    var changeCount: Int { get }
    func snapshot() throws -> InjectionPasteboardSnapshot
    func write(_ text: String) -> Bool
    func restore(_ snapshot: InjectionPasteboardSnapshot)
}

/// The lease only restores our own write. A newer user/app copy always wins.
@MainActor
final class InjectionPasteboardLease {
    private let pasteboard: any InjectionPasteboard
    private let original: InjectionPasteboardSnapshot
    private var ownedChangeCount: Int?

    init(pasteboard: any InjectionPasteboard) throws {
        self.pasteboard = pasteboard
        let count = pasteboard.changeCount
        original = try pasteboard.snapshot()
        guard count == pasteboard.changeCount else {
            throw MemoEchoError.textInjectionFailure(detail: "剪贴板正在变化，请重试")
        }
        ownedChangeCount = count
    }

    var isOwned: Bool { ownedChangeCount == pasteboard.changeCount }

    func write(_ text: String) -> Bool {
        guard isOwned else { return false }
        let written = pasteboard.write(text)
        ownedChangeCount = pasteboard.changeCount
        return written
    }

    func restore() {
        guard isOwned else { return }
        ownedChangeCount = nil
        pasteboard.restore(original)
    }
}

@MainActor
protocol TextInjectionDriver: AnyObject {
    var authorized: Bool { get }
    var isInjecting: Bool { get set }
    var pasteboard: any InjectionPasteboard { get }
    func activate(pid: pid_t, bundleID: String?) -> Bool
    func focus(pid: pid_t, bundleID: String?) -> TextInjectionFocus?
    func monitorWindow(_ target: TextInjectionFocus) -> InjectionTargetContinuity?
    /// False must mean no event was posted; once posted, never retry through AX.
    func postPaste(into target: TextInjectionFocus) -> Bool
    func insertViaAX(_ text: String, into target: TextInjectionFocus) -> Bool
    func wait(milliseconds: Int) async
}

/// AX verification is optional only for targets captured without readable text.
@MainActor
struct TextInjector {
    private let driver: any TextInjectionDriver

    init(driver: any TextInjectionDriver = NativeTextInjectionDriver.shared) {
        self.driver = driver
    }

    struct InjectionResult: Sendable {
        let path: InjectionPath
        let breakdown: InjectionBreakdown
        var beforeInjection: FocusedElementTextSnapshot? = nil
        var confirmation: Confirmation = .verified
    }

    enum Confirmation: Sendable {
        case verified, dispatched
    }

    enum InjectionPath: String, Sendable { case paste, axFallback }

    struct InjectionBreakdown: Sendable {
        var activateTargetMs = 0
        var focusBeforeMs = 0
        var pasteboardWriteMs = 0
        var pasteboardPropagationMs = 0
        var postPasteShortcutMs = 0
        var pasteVerificationMs = 0
        var axFallbackMs = 0
        var pasteboardRestoreMs = 0
        var totalMs = 0
    }

    func captureTarget(pid: pid_t?, bundleID: String?) -> TextInjectionFocus? {
        guard driver.authorized, let pid else { return nil }
        guard let focus = driver.focus(pid: pid, bundleID: bundleID) else { return nil }
        // Keep only the field identity throughout recording; read text at delivery time.
        var target = TextInjectionFocus(pid: focus.pid, bundleID: focus.bundleID, identity: focus.identity,
                                        snapshot: nil, scope: focus.scope, requiresVerification: focus.snapshot != nil)
        if focus.scope == .window {
            guard let continuity = driver.monitorWindow(target), continuity.isValid else { return nil }
            target.continuity = continuity
        }
        return target
    }

    func inject(text: String, target: TextInjectionFocus?,
                shouldContinue: () -> Bool = { true },
                onOutputAttempt: () -> Void = {},
                onUnverifiedPasteDispatched: () -> Void = {}) async throws -> InjectionResult {
        guard driver.authorized else { throw MemoEchoError.accessibilityPermissionDenied }
        guard !driver.isInjecting else { throw failure("上一次文本写入尚未结束") }
        guard let target, !text.isEmpty else { throw failure("未找到原来的输入框，请手动复制文本") }
        driver.isInjecting = true
        defer { driver.isInjecting = false }
        let started = Date()
        var breakdown = InjectionBreakdown()
        func checkCurrent() throws {
            guard !Task.isCancelled, shouldContinue() else { throw CancellationError() }
        }
        try checkCurrent()
        let activation = Date()
        if target.scope == .window {
            guard target.continuity?.isValid == true else {
                throw failure("原窗口已变化，请手动复制文本")
            }
        } else if !driver.activate(pid: target.pid, bundleID: target.bundleID) {
            throw failure("无法返回原来的应用，请手动复制文本")
        }
        breakdown.activateTargetMs = millisecondsSince(activation)
        try checkCurrent()
        let focusStart = Date()
        guard var before = driver.focus(pid: target.pid, bundleID: target.bundleID),
              before.isSameField(as: target), before.snapshot?.isComposing != true,
              !target.requiresVerification || before.snapshot != nil else {
            throw failure("输入框已变化，请手动复制文本")
        }
        before.continuity = target.continuity
        breakdown.focusBeforeMs = millisecondsSince(focusStart)
        // Do not accept selection-only changes as proof when replacement is a no-op.
        let expected: String? = before.snapshot.flatMap { snapshot in
            guard let range = Range(snapshot.selection, in: snapshot.value) else { return nil }
            return snapshot.value.replacingCharacters(in: range, with: text)
        }
        func continuityIsValid() -> Bool {
            target.scope != .window || target.continuity?.isValid == true
        }
        func unchangedTarget() -> Bool {
            guard continuityIsValid(), let current = driver.focus(pid: target.pid, bundleID: target.bundleID),
                  current.isSameField(as: before), current.snapshot?.isComposing != true else { return false }
            return current.snapshot == before.snapshot
        }

        let lease: InjectionPasteboardLease?
        let backupCount = driver.pasteboard.changeCount
        do {
            lease = try InjectionPasteboardLease(pasteboard: driver.pasteboard)
        } catch {
            try checkCurrent()
            // Snapshot failure has not modified the clipboard or posted any event.
            // Only a stable, readable original field may bypass clipboard transport.
            guard case .textInjectionFailure = error as? MemoEchoError,
                  backupCount == driver.pasteboard.changeCount,
                  before.scope == .field, expected != nil, unchangedTarget() else { throw error }
            lease = nil
        }
        defer { lease?.restore() }
        let writeStart = Date()
        let written = lease?.write(text) ?? false
        breakdown.pasteboardWriteMs = millisecondsSince(writeStart)
        if written {
            let propagation = Date()
            await driver.wait(milliseconds: 30)
            breakdown.pasteboardPropagationMs = millisecondsSince(propagation)
        }
        try checkCurrent()
        guard (lease?.isOwned ?? (backupCount == driver.pasteboard.changeCount)), unchangedTarget() else {
            throw failure("输入位置或剪贴板已变化，已停止写入，请手动复制文本")
        }
        let dispatchStart = Date()
        let posted = written && driver.postPaste(into: before)
        breakdown.postPasteShortcutMs = millisecondsSince(dispatchStart)
        let path: InjectionPath
        if posted {
            onOutputAttempt()
            path = .paste
            // Unreadable targets have no acknowledgement to wait for. Let the HUD
            // dismiss now while the clipboard lease and safety checks remain active.
            if before.snapshot == nil { onUnverifiedPasteDispatched() }
        } else {
            // AX fallback is allowed only BEFORE any paste event could have been delivered.
            let fallbackStart = Date()
            guard before.snapshot != nil, unchangedTarget() else {
                throw failure("无法写入原来的输入框，请手动复制文本")
            }
            // Even a failed AX write may have side effects; recovery must not blindly repeat it.
            onOutputAttempt()
            guard driver.insertViaAX(text, into: before) else {
                throw failure("无法写入原来的输入框，请手动复制文本")
            }
            breakdown.axFallbackMs = millisecondsSince(fallbackStart)
            path = .axFallback
        }

        let verification = Date()
        var invalidated = false
        // Keep the clipboard available while the receiving app consumes its queued paste.
        // Focus loss/cancellation invalidates success permanently; it never triggers a second write.
        for _ in 0..<20 {
            await driver.wait(milliseconds: 50)
            if Task.isCancelled || !shouldContinue() { invalidated = true }
            let current = driver.focus(pid: target.pid, bundleID: target.bundleID)
            if !continuityIsValid() || current?.isSameField(as: before) != true || current?.snapshot?.isComposing == true { invalidated = true }
            if !invalidated, let expected, expected != before.snapshot?.value,
               let snapshot = current?.snapshot, !snapshot.isComposing,
               snapshot.value == expected {
                breakdown.pasteVerificationMs = millisecondsSince(verification)
                let restoration = Date()
                lease?.restore()
                breakdown.pasteboardRestoreMs = millisecondsSince(restoration)
                breakdown.totalMs = millisecondsSince(started)
                return .init(path: path, breakdown: breakdown, beforeInjection: before.snapshot)
            }
        }
        try checkCurrent()
        if !invalidated, before.snapshot == nil, path == .paste {
            breakdown.pasteVerificationMs = millisecondsSince(verification)
            let restoration = Date()
            lease?.restore()
            breakdown.pasteboardRestoreMs = millisecondsSince(restoration)
            breakdown.totalMs = millisecondsSince(started)
            return .init(path: path, breakdown: breakdown, confirmation: .dispatched)
        }
        throw failure("无法确认文本是否写入，请先检查原输入框，避免重复粘贴；文本可从菜单栏复制")
    }

    private func failure(_ detail: String) -> MemoEchoError { .textInjectionFailure(detail: detail) }
    private func millisecondsSince(_ start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }
}

@MainActor
final class NativeInjectionPasteboard: InjectionPasteboard {
    private let board: NSPasteboard
    init(board: NSPasteboard = .general) { self.board = board }
    var changeCount: Int { board.changeCount }

    // These describe clipboard handling or provenance, not recoverable user content.
    // Preserve them when readable, but never use them alone to justify replacement.
    private static let controlTypes: Set<String> = [
        "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
        "org.nspasteboard.ConcealedType", "org.nspasteboard.source",
        "org.p0deje.Maccy"
    ]

    func snapshot() throws -> InjectionPasteboardSnapshot {
        let count = board.changeCount
        let items = board.pasteboardItems
        let declaredTypes = board.types
        var snapshot: InjectionPasteboardSnapshot = []
        // A missing item list is empty only when the board also reports no types.
        var recoverable = items != nil || declaredTypes?.isEmpty == true
        if items?.isEmpty == true, declaredTypes?.isEmpty != true { recoverable = false }
        for item in items ?? [] {
            var data: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                // AppKit may advertise derived formats whose conversion returns nil.
                // Keep every readable representation, including legitimate empty Data.
                if let value = item.data(forType: type) { data[type] = value }
            }
            if !data.keys.contains(where: { !Self.controlTypes.contains($0.rawValue) }) {
                recoverable = false
            }
            snapshot.append(data)
        }
        // Ownership changes take precedence over errors from stale pasteboard items.
        guard count == board.changeCount else {
            throw MemoEchoError.textInjectionFailure(detail: "剪贴板正在变化，请重试")
        }
        guard recoverable else {
            throw MemoEchoError.textInjectionFailure(detail: "无法备份当前剪贴板，请手动复制文本")
        }
        return snapshot
    }

    func write(_ text: String) -> Bool {
        // Publish text and markers together so clipboard historians never see
        // an unmarked intermediate write. This is transport, not a user copy.
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string),
              item.setData(Data(), forType: .init("org.nspasteboard.TransientType")),
              item.setData(Data(), forType: .init("org.nspasteboard.AutoGeneratedType")) else {
            return false
        }
        board.prepareForNewContents(with: .currentHostOnly)
        return board.writeObjects([item])
    }

    func restore(_ snapshot: InjectionPasteboardSnapshot) {
        let items = snapshot.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        board.clearContents()
        if !items.isEmpty { board.writeObjects(items) }
    }
}

@MainActor
private final class NativeTextInjectionDriver: TextInjectionDriver {
    static let shared = NativeTextInjectionDriver()
    var isInjecting = false
    var authorized: Bool { AXIsProcessTrusted() }
    let pasteboard: any InjectionPasteboard = NativeInjectionPasteboard()
    private let resolver = FocusedElementResolver()

    func activate(pid: pid_t, bundleID: String?) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid),
              bundleID == nil || app.bundleIdentifier == bundleID else { return false }
        return resolver.restoreTargetApplication(pid: pid)
    }

    func focus(pid: pid_t, bundleID: String?) -> TextInjectionFocus? {
        guard !IsSecureEventInputEnabled(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let app = NSRunningApplication(processIdentifier: pid),
              bundleID == nil || app.bundleIdentifier == bundleID else { return nil }
        let application = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused)
        if status == .noValue || status == .attributeUnsupported {
            var window: CFTypeRef?
            guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &window) == .success,
                  let window, CFGetTypeID(window) == AXUIElementGetTypeID(), pid != ProcessInfo.processInfo.processIdentifier else { return nil }
            return .init(pid: pid, bundleID: app.bundleIdentifier, identity: .init(element: window as! AXUIElement),
                         snapshot: nil, scope: .window)
        }
        guard status == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        var role: CFTypeRef?
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        guard subrole as? String != kAXSecureTextFieldSubrole else { return nil }
        var writable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &writable)
        var valueWritable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueWritable)
        var enabled: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabled)
        var editable: CFTypeRef?
        AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editable)
        guard enabled as? Bool != false, editable as? Bool != false else { return nil }
        let textRoles = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]
        guard writable.boolValue || valueWritable.boolValue || textRoles.contains(role as? String ?? "") else { return nil }
        let identity = FocusedElementIdentity(element: element)
        let snapshot = FocusedElementTextSnapshotReader().read(targetPID: pid, targetBundleID: bundleID)
        if let snapshot, snapshot.identity != identity { return nil }
        return .init(pid: pid, bundleID: app.bundleIdentifier, identity: identity, snapshot: snapshot)
    }

    func monitorWindow(_ target: TextInjectionFocus) -> InjectionTargetContinuity? {
        InjectionTargetContinuity.monitor(target: target) { [weak self] in
            self?.focus(pid: target.pid, bundleID: target.bundleID)?.isSameField(as: target) == true
        }
    }

    func insertViaAX(_ text: String, into target: TextInjectionFocus) -> Bool {
        guard target.scope == .field, let current = focus(pid: target.pid, bundleID: target.bundleID),
              current.isSameField(as: target), current.snapshot == target.snapshot,
              let resolved = resolver.resolveFocusedElement(targetPID: target.pid, shouldRestoreTargetApplication: false),
              FocusedElementIdentity(element: resolved.element) == target.identity else { return false }
        return AXUIElementSetAttributeValue(resolved.element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    func wait(milliseconds: Int) async {
        // Unstructured task deliberately drains the paste window even if the caller is cancelled.
        await Task { try? await Task.sleep(for: .milliseconds(milliseconds)) }.value
    }

    func postPaste(into target: TextInjectionFocus) -> Bool {
        guard target.scope != .window || target.continuity?.isValid == true else { return false }
        let shortcut = Self.resolvePasteShortcut()
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: false) else { return false }
        down.flags = shortcut.flags
        up.flags = shortcut.flags
        guard let current = focus(pid: target.pid, bundleID: target.bundleID),
              current.isSameField(as: target), current.snapshot == target.snapshot else { return false }
        // Route only to the captured process, even if another app becomes frontmost in this gap.
        down.postToPid(target.pid)
        up.postToPid(target.pid)
        return true
    }

    static func resolvePasteShortcut() -> (keyCode: CGKeyCode, flags: CGEventFlags) {
        let pasteShortcut = currentPasteShortcut()
        let modifiers = pasteShortcut.modifiers.intersection(.deviceIndependentFlagsMask)
        let keyEquivalent = normalizedKeyEquivalent(from: pasteShortcut.keyEquivalent) ?? "v"
        let keyboardLayout = KeyboardLayout.current

        let keyCode: CGKeyCode
        if keyboardLayout.commandSwitchesToQWERTY, modifiers.contains(.command) {
            keyCode = keyboardLayout.qwertyKeyCode(for: keyEquivalent) ?? CGKeyCode(kVK_ANSI_V)
        } else {
            keyCode = keyboardLayout.keyCode(for: keyEquivalent)
                ?? keyboardLayout.qwertyKeyCode(for: keyEquivalent)
                ?? CGKeyCode(kVK_ANSI_V)
        }

        let flags = CGEventFlags(rawValue: UInt64(cgEventFlags(from: modifiers).rawValue) | 0x000008)
        return (keyCode, flags)
    }

    private static func currentPasteShortcut() -> (keyEquivalent: String?, modifiers: NSEvent.ModifierFlags) {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                guard let item = pasteMenuItem else {
                    return (nil, .command)
                }
                return (item.keyEquivalent, item.keyEquivalentModifierMask)
            }
        }

        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                guard let item = pasteMenuItem else {
                    return (nil, .command)
                }
                return (item.keyEquivalent, item.keyEquivalentModifierMask)
            }
        }
    }

    @MainActor
    private static var pasteMenuItem: NSMenuItem? {
        NSApp.mainMenu?.items
            .flatMap { $0.submenu?.items ?? [] }
            .first { $0.action == #selector(NSText.paste) }
    }

    private static func normalizedKeyEquivalent(from keyEquivalent: String?) -> String? {
        guard let value = keyEquivalent?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        if value.count == 1 {
            return value.lowercased()
        }

        return value
    }

    private static func cgEventFlags(from modifiers: NSEvent.ModifierFlags) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        return flags
    }

}

private struct KeyboardLayout {
    static var current: KeyboardLayout { KeyboardLayout() }

    var commandSwitchesToQWERTY: Bool {
        localizedName.hasSuffix("⌘")
    }

    private let inputSource: TISInputSource

    private var localizedName: String {
        guard let value = TISGetInputSourceProperty(inputSource, kTISPropertyLocalizedName) else {
            return ""
        }

        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }

    init() {
        inputSource = TISCopyCurrentKeyboardLayoutInputSource().takeUnretainedValue()
    }

    func keyCode(for keyEquivalent: String) -> CGKeyCode? {
        guard let scalar = keyEquivalent.unicodeScalars.first else { return nil }

        for keyCode in 0...127 {
            guard let produced = translatedCharacters(for: CGKeyCode(keyCode)) else { continue }
            if produced.caseInsensitiveCompare(String(scalar)) == .orderedSame {
                return CGKeyCode(keyCode)
            }
        }

        return qwertyKeyCode(for: keyEquivalent)
    }

    func qwertyKeyCode(for keyEquivalent: String) -> CGKeyCode? {
        guard let scalar = keyEquivalent.lowercased().unicodeScalars.first else { return nil }
        return Self.qwertyKeyCodes[scalar]
    }

    private func translatedCharacters(for keyCode: CGKeyCode) -> String? {
        guard let rawLayoutData = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }

        let layoutData = unsafeBitCast(rawLayoutData, to: CFData.self) as Data
        return layoutData.withUnsafeBytes { rawBuffer in
            guard let keyboardLayout = rawBuffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return nil
            }

            var deadKeyState: UInt32 = 0
            var length: Int = 0
            var buffer = [UniChar](repeating: 0, count: 4)

            let result = UCKeyTranslate(
                keyboardLayout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                buffer.count,
                &length,
                &buffer
            )

            guard result == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: buffer, count: length)
        }
    }

    private static let qwertyKeyCodes: [Unicode.Scalar: CGKeyCode] = [
        "a": CGKeyCode(kVK_ANSI_A),
        "b": CGKeyCode(kVK_ANSI_B),
        "c": CGKeyCode(kVK_ANSI_C),
        "d": CGKeyCode(kVK_ANSI_D),
        "e": CGKeyCode(kVK_ANSI_E),
        "f": CGKeyCode(kVK_ANSI_F),
        "g": CGKeyCode(kVK_ANSI_G),
        "h": CGKeyCode(kVK_ANSI_H),
        "i": CGKeyCode(kVK_ANSI_I),
        "j": CGKeyCode(kVK_ANSI_J),
        "k": CGKeyCode(kVK_ANSI_K),
        "l": CGKeyCode(kVK_ANSI_L),
        "m": CGKeyCode(kVK_ANSI_M),
        "n": CGKeyCode(kVK_ANSI_N),
        "o": CGKeyCode(kVK_ANSI_O),
        "p": CGKeyCode(kVK_ANSI_P),
        "q": CGKeyCode(kVK_ANSI_Q),
        "r": CGKeyCode(kVK_ANSI_R),
        "s": CGKeyCode(kVK_ANSI_S),
        "t": CGKeyCode(kVK_ANSI_T),
        "u": CGKeyCode(kVK_ANSI_U),
        "v": CGKeyCode(kVK_ANSI_V),
        "w": CGKeyCode(kVK_ANSI_W),
        "x": CGKeyCode(kVK_ANSI_X),
        "y": CGKeyCode(kVK_ANSI_Y),
        "z": CGKeyCode(kVK_ANSI_Z),
        "0": CGKeyCode(kVK_ANSI_0),
        "1": CGKeyCode(kVK_ANSI_1),
        "2": CGKeyCode(kVK_ANSI_2),
        "3": CGKeyCode(kVK_ANSI_3),
        "4": CGKeyCode(kVK_ANSI_4),
        "5": CGKeyCode(kVK_ANSI_5),
        "6": CGKeyCode(kVK_ANSI_6),
        "7": CGKeyCode(kVK_ANSI_7),
        "8": CGKeyCode(kVK_ANSI_8),
        "9": CGKeyCode(kVK_ANSI_9)
    ]
}
