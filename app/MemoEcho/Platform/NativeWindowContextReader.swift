import AppKit
import ApplicationServices

/// AX calls live on a serial worker, never on the UI executor. Each call has a small budget.
enum NativeWindowContextReader {
    private static let queue = DispatchQueue(label: "me.wangmao.memoecho.context", qos: .utility)

    static func capture(pid: pid_t?, bundleID: String?, identity: FocusedElementIdentity?,
                        phase: WindowContextCapturePhase) async throws -> WindowContextCandidate? {
        guard let pid, !Task.isCancelled, AXIsProcessTrusted() else { return nil }
        let metadata = await MainActor.run { () -> (String?, String?)? in
            guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier == pid,
                  bundleID == nil || app.bundleIdentifier == bundleID else { return nil }
            return (app.localizedName, app.bundleIdentifier)
        }
        guard let metadata, !Task.isCancelled else { return nil }
        let deadline = Date().addingTimeInterval(phase == .basic ? 0.18 : 0.45)
        let candidate = await withCheckedContinuation { continuation in
            queue.async {
                let reader = Reader(deadline: deadline)
                continuation.resume(returning: reader.capture(pid: pid, name: metadata.0, bundleID: metadata.1,
                                                              identity: identity, phase: phase))
            }
        }
        guard !Task.isCancelled else { return nil }
        let stillCurrent = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }
        return stillCurrent ? candidate : nil
    }

    private struct Reader {
        let deadline: Date
        var expired: Bool { Date() >= deadline }

        func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            guard !expired else { return nil }
            AXUIElementSetMessagingTimeout(element, Float(min(0.05, max(0.001, deadline.timeIntervalSinceNow))))
            var result: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
            return result
        }
        func string(_ element: AXUIElement, _ attribute: String) -> String? {
            if let value = value(element, attribute) as? String { return value }
            return nil
        }
        func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
            guard let result = value(element, attribute), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
            return (result as! AXUIElement)
        }
        func range(_ element: AXUIElement, attribute: String = kAXSelectedTextRangeAttribute) -> NSRange? {
            guard let result = value(element, attribute), CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
            var range = CFRange()
            guard AXValueGetValue(result as! AXValue, .cfRange, &range), range.location >= 0,
                  range.length >= 0, range.location <= Int.max - range.length else { return nil }
            return NSRange(location: range.location, length: range.length)
        }
        func frame(_ element: AXUIElement) -> CGRect? {
            guard let position = value(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
                  let size = value(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero
            var dimensions = CGSize.zero
            guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
                  AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
            return CGRect(origin: point, size: dimensions)
        }
        func writable(_ element: AXUIElement) -> Bool? {
            guard !expired else { return nil }
            var selected = DarwinBoolean(false)
            var whole = DarwinBoolean(false)
            let first = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &selected)
            let second = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &whole)
            if first != .success && second != .success { return nil }
            return selected.boolValue || whole.boolValue
        }

        func capture(pid: pid_t, name: String?, bundleID: String?, identity: FocusedElementIdentity?,
                     phase: WindowContextCapturePhase) -> WindowContextCandidate? {
            let app = AXUIElementCreateApplication(pid)
            guard let focus = element(app, kAXFocusedUIElementAttribute),
                  identity == nil || FocusedElementIdentity(element: focus) == identity,
                  let window = element(focus, kAXWindowAttribute) ?? element(app, kAXFocusedWindowAttribute) else {
                guard phase == .basic else { return nil }
                return WindowContextCandidate(appName: name, bundleID: bundleID, fieldStatus: ["input": .unavailable])
            }
            var candidate = WindowContextCandidate(appName: name, bundleID: bundleID,
                windowTitle: string(window, kAXTitleAttribute), elementRole: string(focus, kAXRoleAttribute),
                elementSubrole: string(focus, kAXSubroleAttribute), placeholder: string(focus, kAXPlaceholderValueAttribute))
            candidate.identity = .init(element: focus)
            candidate.windowIdentity = .init(element: window)
            candidate.isEditable = writable(focus)
            candidate.textCaptureBlocked = WindowContextService.isSensitiveContext(candidate: candidate)
            if phase == .extended && !candidate.textCaptureBlocked {
                // Browser URL comes only from the focused window/ancestor WebArea, not other tabs.
                candidate.browserURL = browserURL(focus: focus, window: window)
                candidate.selection = range(focus)
                if let selection = candidate.selection {
                    // Read the field once; AX ranges count UTF-16 units, not Swift Characters.
                    if let text = string(focus, kAXValueAttribute), text.utf16.count <= 100_000 {
                        let parts = WindowContextService.surrounding(text, selection: selection, limit: 1000)
                        if parts.selected == nil && parts.before == nil && parts.after == nil { candidate.selection = nil }
                        candidate.selectedText = parts.selected
                        candidate.surroundingTextBefore = parts.before
                        candidate.surroundingTextAfter = parts.after
                    }
                }
                candidate.nearbyLabels = [string(focus, kAXTitleAttribute), string(focus, kAXDescriptionAttribute)]
                    .compactMap { $0 }
                candidate.supportsMarkdown = ["md.obsidian", "abnerworks.Typora"].contains(bundleID ?? "") ? true : nil
                let visible = visibleText(window)
                candidate.visibleText = visible.text
                candidate.fieldStatus["visible"] = visible.status
            }
            if expired { candidate.fieldStatus["enrichment"] = .timeout }
            // A finished read is accepted only while the original field and window still match.
            guard let finalFocus = element(app, kAXFocusedUIElementAttribute), CFEqual(finalFocus, focus),
                  let finalWindow = element(finalFocus, kAXWindowAttribute) ?? element(app, kAXFocusedWindowAttribute),
                  CFEqual(finalWindow, window) else { return nil }
            return candidate
        }

        func rangedText(_ element: AXUIElement, range: NSRange, limit: Int) -> String? {
            guard !expired, limit > 0 else { return nil }
            var range = CFRange(location: range.location, length: min(range.length, limit))
            guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
            var result: CFTypeRef?
            AXUIElementSetMessagingTimeout(element, Float(min(0.05, max(0.001, deadline.timeIntervalSinceNow))))
            guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                             parameter, &result) == .success else { return nil }
            return result as? String
        }

        func browserURL(focus: AXUIElement, window: AXUIElement) -> String? {
            var current: AXUIElement? = focus
            for _ in 0..<12 {
                guard let node = current, !expired else { break }
                for attribute in [kAXDocumentAttribute, "AXURL"] {
                    let raw = value(node, attribute)
                    let text = (raw as? URL)?.absoluteString ?? raw as? String
                    if let safe = WindowContextService.sanitizedURL(text) { return safe }
                }
                if CFEqual(node, window) { break }
                current = element(node, kAXParentAttribute)
            }
            return WindowContextService.sanitizedURL(string(window, kAXDocumentAttribute))
        }

        func visibleText(_ window: AXUIElement) -> (text: String?, status: ContextFieldStatus) {
            guard let windowFrame = frame(window) else { return (nil, .unavailable) }
            var pending: [(AXUIElement, Int)] = [(window, 0)]
            var visited = Set<CFHashCode>()
            var seenText = Set<String>()
            var pieces: [String] = []
            var length = 0
            var index = 0
            while index < pending.count && index < 180 && deadline.timeIntervalSinceNow > 0.13 {
                let (node, depth) = pending[index]; index += 1
                guard visited.insert(CFHash(node)).inserted else { continue }
                if value(node, "AXHidden") as? Bool == true { continue }
                let role = string(node, kAXRoleAttribute)
                let subrole = string(node, kAXSubroleAttribute)
                let title = string(node, kAXTitleAttribute)
                let placeholder = string(node, kAXPlaceholderValueAttribute)
                let probe = WindowContextCandidate(windowTitle: title, elementRole: role, elementSubrole: subrole, placeholder: placeholder)
                if WindowContextService.isSensitiveContext(candidate: probe) { continue }
                let rect = frame(node)
                if let rect, !rect.isEmpty, !rect.intersects(windowFrame) { continue }
                var text: String?
                if let rect, !rect.isEmpty, rect.intersects(windowFrame) {
                    if role == kAXStaticTextRole && windowFrame.contains(rect) {
                        text = string(node, kAXValueAttribute) ?? title
                    } else if [kAXTextFieldRole, kAXTextAreaRole].contains(role ?? ""),
                              let visibleRange = range(node, attribute: kAXVisibleCharacterRangeAttribute) {
                        text = rangedText(node, range: visibleRange, limit: max(0, 10000 - length))
                    }
                }
                if let text, !text.isEmpty, seenText.insert(text).inserted {
                    let piece = String(text.prefix(max(0, 10000 - length)))
                    pieces.append(piece); length += piece.count + 1
                    if length >= 10000 { return (pieces.joined(separator: "\n"), .truncated) }
                }
                if depth < 10 {
                    let children = (value(node, kAXVisibleChildrenAttribute) ?? value(node, kAXChildrenAttribute)) as? [AXUIElement] ?? []
                    pending.append(contentsOf: children.prefix(max(0, 180 - pending.count)).map { ($0, depth + 1) })
                }
            }
            let status: ContextFieldStatus = deadline.timeIntervalSinceNow <= 0.13 ? .timeout : (index >= 180 ? .truncated : (pieces.isEmpty ? .unavailable : .available))
            return (pieces.isEmpty ? nil : pieces.joined(separator: "\n"), status)
        }
    }
}
