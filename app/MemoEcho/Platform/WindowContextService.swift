import ApplicationServices
import Foundation

struct WindowContextCaptureResult: Sendable, Equatable {
    var snapshot: WindowContextSnapshot?
    var event: WindowContextCaptureEvent
}

enum WindowContextCaptureEvent: String, Sendable, Equatable {
    case captured = "window_context_captured"
    case redacted = "window_context_redacted"
    case unavailable = "window_context_unavailable"
    case captureFailed = "window_context_capture_failed"
    case timeout = "window_context_capture_timeout"
}

struct WindowContextBuildResult: Sendable, Equatable {
    let snapshot: WindowContextSnapshot?
    let redacted: Bool
}

struct WindowContextCandidate: Sendable, Equatable {
    var appName: String?
    var bundleID: String?
    var windowTitle: String?
    var elementRole: String?
    var elementSubrole: String?
    var placeholder: String?
    var selectedText: String?
    var surroundingTextBefore: String?
    var surroundingTextAfter: String?
    var nearbyLabels: [String] = []
    var browserURL: String? = nil
    var visibleText: String? = nil
    var isEditable: Bool? = nil
    var supportsMarkdown: Bool? = nil
    var selection: NSRange? = nil
    var textCaptureBlocked = false
    var fieldStatus: [String: ContextFieldStatus] = [:]
    var identity: FocusedElementIdentity? = nil
    var windowIdentity: FocusedElementIdentity? = nil
}

enum WindowContextCapturePhase: Sendable { case basic, extended }

/// Two bounded attempts; slow or unavailable enrichment preserves the basic context.
struct WindowContextService: Sendable {
    typealias CandidateProvider = @Sendable (pid_t?, String?, FocusedElementIdentity?, WindowContextCapturePhase) async throws -> WindowContextCandidate?
    static let captureTimeout: Duration = .milliseconds(500)
    private let candidateProvider: CandidateProvider

    init(candidateProvider: @escaping CandidateProvider = NativeWindowContextReader.capture) {
        self.candidateProvider = candidateProvider
    }

    func captureContextResult(targetPID: pid_t?, targetBundleID: String?,
                              targetIdentity: FocusedElementIdentity? = nil,
                              onBasic: @Sendable (WindowContextCaptureResult) async -> Void = { _ in }) async -> WindowContextCaptureResult {
        guard !Task.isCancelled else { return .init(snapshot: nil, event: .unavailable) }
        let start = ContinuousClock.now
        let basic = await boundedCapture(pid: targetPID, bundleID: targetBundleID, identity: targetIdentity,
                                         phase: .basic, timeout: .milliseconds(200))
        guard !Task.isCancelled else { return .init(snapshot: nil, event: .unavailable) }
        guard case .candidate(let candidate?) = basic else { return result(for: basic) }
        let base = result(for: basic)
        await onBasic(base)
        guard !Task.isCancelled else { return .init(snapshot: nil, event: .unavailable) }
        let expanded = await boundedCapture(pid: targetPID, bundleID: targetBundleID,
                                            identity: candidate.identity ?? targetIdentity,
                                            phase: .extended, timeout: Self.captureTimeout)
        guard !Task.isCancelled else { return .init(snapshot: nil, event: .unavailable) }
        var result: WindowContextCaptureResult
        if case .candidate(let full?) = expanded,
           full.identity == candidate.identity, full.windowIdentity == candidate.windowIdentity,
           full.bundleID == candidate.bundleID {
            result = self.result(for: expanded)
        } else {
            result = base
            result.event = expanded == .timeout ? .timeout : .unavailable
            result.snapshot?.fieldStatus["enrichment"] = expanded == .timeout ? .timeout : .unavailable
        }
        let elapsed = start.duration(to: .now).components
        result.snapshot?.captureMilliseconds = Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
        return result
    }

    private func result(for attempt: ContextCaptureAttempt) -> WindowContextCaptureResult {
        switch attempt {
        case .candidate(let candidate):
            guard let candidate else { return .init(snapshot: nil, event: .unavailable) }
            let built = Self.buildSnapshot(from: candidate)
            return .init(snapshot: built.snapshot, event: built.redacted ? .redacted : .captured)
        case .timeout: return .init(snapshot: nil, event: .timeout)
        case .failed: return .init(snapshot: nil, event: .captureFailed)
        }
    }

    private func boundedCapture(pid: pid_t?, bundleID: String?, identity: FocusedElementIdentity?,
                                phase: WindowContextCapturePhase,
                                timeout: Duration) async -> ContextCaptureAttempt {
        let gate = ContextCaptureGate()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.install(continuation)
                let worker = Task {
                    do { gate.finish(.candidate(try await candidateProvider(pid, bundleID, identity, phase))) }
                    catch { gate.finish(.failed) }
                }
                let timer = Task {
                    do { try await Task.sleep(for: timeout); gate.finish(.timeout) } catch {}
                }
                gate.attach([worker, timer])
            }
        } onCancel: { gate.finish(.failed) }
    }

    static func sanitized(_ snapshot: WindowContextSnapshot?) -> WindowContextSnapshot? {
        guard let snapshot else { return nil }
        let candidate = WindowContextCandidate(appName: snapshot.appName, bundleID: snapshot.bundleID,
            windowTitle: snapshot.windowTitle, elementRole: snapshot.elementRole, elementSubrole: snapshot.elementSubrole,
            placeholder: snapshot.placeholder, selectedText: snapshot.selectedText,
            surroundingTextBefore: snapshot.surroundingTextBefore, surroundingTextAfter: snapshot.surroundingTextAfter,
            nearbyLabels: snapshot.nearbyLabels, browserURL: snapshot.browserURL, visibleText: snapshot.visibleText,
            isEditable: snapshot.isEditable, supportsMarkdown: snapshot.supportsMarkdown, selection: snapshot.selection,
            textCaptureBlocked: snapshot.textCaptureBlocked, fieldStatus: snapshot.fieldStatus)
        var sanitized = buildSnapshot(from: candidate).snapshot
        sanitized?.captureMilliseconds = snapshot.captureMilliseconds
        return sanitized
    }

    static func buildSnapshot(from candidate: WindowContextCandidate) -> WindowContextBuildResult {
        let appName = normalized(candidate.appName, limit: 120)
        let bundleID = normalized(candidate.bundleID, limit: 180)
        let windowTitle = normalized(candidate.windowTitle, limit: 160)
        let elementRole = normalized(candidate.elementRole, limit: 80)
        let elementSubrole = normalized(candidate.elementSubrole, limit: 80)
        let placeholder = normalized(candidate.placeholder, limit: 120)
        let selectedText = normalized(candidate.selectedText, limit: 1000)
        let surroundingTextBefore = normalized(candidate.surroundingTextBefore.map { String($0.suffix(1000)) }, limit: 1000)
        let surroundingTextAfter = normalized(candidate.surroundingTextAfter, limit: 1000)
        let browserURL = sanitizedURL(candidate.browserURL)
        let visibleText = normalized(candidate.visibleText, limit: 10000)
        let nearbyLabels = normalizedLabels(candidate.nearbyLabels)

        let surfaceKind = classifySurfaceKind(
            appName: appName,
            windowTitle: windowTitle,
            role: elementRole,
            subrole: elementSubrole,
            placeholder: placeholder,
            nearbyLabels: nearbyLabels,
            surroundingTextBefore: surroundingTextBefore,
            surroundingTextAfter: surroundingTextAfter
        )

        let normalizedCandidate = WindowContextCandidate(
            appName: appName,
            bundleID: bundleID,
            windowTitle: windowTitle,
            elementRole: elementRole,
            elementSubrole: elementSubrole,
            placeholder: placeholder,
            selectedText: selectedText,
            surroundingTextBefore: surroundingTextBefore,
            surroundingTextAfter: surroundingTextAfter,
            nearbyLabels: nearbyLabels
        )

        let sensitive = candidate.textCaptureBlocked || isSensitiveContext(candidate: normalizedCandidate)
        let snapshot = WindowContextSnapshot(
            appName: appName,
            bundleID: bundleID,
            windowTitle: sensitive ? nil : windowTitle,
            surfaceKind: surfaceKind,
            elementRole: elementRole,
            elementSubrole: elementSubrole,
            placeholder: sensitive ? nil : placeholder,
            selectedText: sensitive ? nil : selectedText,
            surroundingTextBefore: sensitive ? nil : surroundingTextBefore,
            surroundingTextAfter: sensitive ? nil : surroundingTextAfter,
            nearbyLabels: sensitive ? [] : nearbyLabels,
            browserURL: sensitive ? nil : browserURL,
            visibleText: sensitive ? nil : visibleText,
            isEditable: candidate.isEditable, supportsMarkdown: candidate.supportsMarkdown,
            selection: sensitive ? nil : candidate.selection, textCaptureBlocked: sensitive,
            fieldStatus: quality(candidate, blocked: sensitive)
        )

        let hasPayload = snapshot.appName != nil
            || snapshot.bundleID != nil
            || snapshot.windowTitle != nil
            || snapshot.elementRole != nil
            || snapshot.elementSubrole != nil
            || snapshot.placeholder != nil
            || snapshot.selectedText != nil
            || snapshot.surroundingTextBefore != nil
            || snapshot.surroundingTextAfter != nil
            || !snapshot.nearbyLabels.isEmpty
            || snapshot.visibleText != nil
            || snapshot.browserURL != nil

        guard hasPayload else {
            return WindowContextBuildResult(snapshot: nil, redacted: sensitive)
        }

        return WindowContextBuildResult(snapshot: snapshot, redacted: sensitive)
    }

    static func surrounding(_ text: String, selection: NSRange, limit: Int) -> (selected: String?, before: String?, after: String?) {
        let source = text as NSString
        guard limit >= 0, selection.location >= 0, selection.length >= 0, selection.location <= source.length,
              selection.length <= source.length - selection.location else { return (nil, nil, nil) }
        let end = selection.location + selection.length
        func splitsSurrogate(_ offset: Int) -> Bool {
            guard offset > 0 && offset < source.length else { return false }
            return (0xD800...0xDBFF).contains(source.character(at: offset - 1))
                && (0xDC00...0xDFFF).contains(source.character(at: offset))
        }
        guard !splitsSurrogate(selection.location), !splitsSurrogate(end) else { return (nil, nil, nil) }
        return (String(source.substring(with: selection).prefix(limit)),
                String(source.substring(to: selection.location).suffix(limit)),
                String(source.substring(from: end).prefix(limit)))
    }

    static func sanitizedURL(_ raw: String?) -> String? {
        guard let raw, raw.count <= 4096, var url = URLComponents(string: raw),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        url.user = nil; url.password = nil; url.query = nil; url.fragment = nil
        return url.string.map { String($0.prefix(2048)) }
    }

    private static func quality(_ candidate: WindowContextCandidate, blocked: Bool) -> [String: ContextFieldStatus] {
        var fields = candidate.fieldStatus
        let values: [(String, String?, Int)] = [("selected", candidate.selectedText, 1000),
            ("before", candidate.surroundingTextBefore, 1000), ("after", candidate.surroundingTextAfter, 1000),
            ("visible", candidate.visibleText, 10000), ("url", candidate.browserURL, 2048)]
        for (key, value, limit) in values {
            if blocked { fields[key] = .redacted }
            else if let value { fields[key] = value.count > limit ? .truncated : (fields[key] ?? .available) }
            else { fields[key] = fields[key] ?? .unavailable }
        }
        fields["app"] = candidate.appName == nil && candidate.bundleID == nil ? .unavailable : .available
        fields["window"] = blocked ? .redacted : (candidate.windowTitle == nil ? .unavailable : .available)
        fields["input"] = candidate.elementRole == nil ? .unavailable : .available
        fields["selection"] = blocked ? .redacted : (candidate.selection == nil ? .unavailable : .available)
        fields["markdown"] = candidate.supportsMarkdown == nil ? .unavailable : .available
        fields["editable"] = candidate.isEditable == nil ? .unavailable : .available
        return fields
    }

    private static func normalized(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(limit))
    }

    private static func normalizedLabels(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var labels: [String] = []

        for value in values {
            guard let normalized = normalized(value, limit: 120) else { continue }
            if seen.insert(normalized).inserted {
                labels.append(normalized)
            }
            if labels.count == 5 {
                break
            }
        }

        return labels
    }

    private static func classifySurfaceKind(
        appName: String?,
        windowTitle: String?,
        role: String?,
        subrole: String?,
        placeholder: String?,
        nearbyLabels: [String],
        surroundingTextBefore: String?,
        surroundingTextAfter: String?
    ) -> InputSurfaceKind {
        let loweredMetadata = (
            [appName, windowTitle, role, subrole, placeholder] + nearbyLabels.map(Optional.some)
        )
        .compactMap { $0?.lowercased() }
        .joined(separator: "\n")

        if loweredMetadata.contains("axsearchfield")
            || containsAny(
                loweredMetadata,
                keywords: ["search", "find", "搜索", "查找", "搜一搜"]
            ) {
            return .searchField
        }

        if containsAny(
            loweredMetadata,
            keywords: [
                "message", "reply", "comment", "chat", "composer",
                "消息", "回复", "评论", "发送", "说点什么"
            ]
        ) {
            return .chatComposer
        }

        let hasMultilineSignal = [surroundingTextBefore, surroundingTextAfter]
            .compactMap { $0 }
            .contains { $0.contains("\n") }
            || containsAny(
                loweredMetadata,
                keywords: [
                    "textarea", "editor", "document", "markdown", "notion",
                    "notes", "pages", "word", "文档", "笔记", "编辑器"
                ]
            )

        if hasMultilineSignal {
            return .documentEditor
        }

        if containsAny(
            loweredMetadata,
            keywords: ["axtextfield", "axtextarea", "field", "form", "输入", "表单"]
        ) {
            return .singleLineForm
        }

        return .unknown
    }

    static func isSensitiveContext(candidate: WindowContextCandidate) -> Bool {
        let loweredBundleID = candidate.bundleID?.lowercased() ?? ""
        let loweredRole = candidate.elementRole?.lowercased() ?? ""
        let loweredSubrole = candidate.elementSubrole?.lowercased() ?? ""
        let metadata = (
            [
                candidate.appName,
                candidate.bundleID,
                candidate.windowTitle,
                candidate.placeholder
            ] + candidate.nearbyLabels.map(Optional.some)
        )
        .compactMap { $0?.lowercased() }
        .joined(separator: "\n")

        if sensitiveBundleIDs.contains(loweredBundleID) {
            return true
        }

        if loweredRole.contains("secure")
            || loweredRole.contains("password")
            || loweredSubrole.contains("secure")
            || loweredSubrole.contains("password") {
            return true
        }

        return containsAny(
            metadata,
            keywords: [
                "password", "passcode", "security code", "verification code",
                "one-time code", "otp", "2fa", "2-step", "1password",
                "bitwarden", "lastpass", "keepass", "terminal", "shell",
                "密码", "口令", "验证码", "校验码", "安全码", "动态码", "终端", "api key", "access token", "secret key", "密钥", "令牌"
            ]
        )
    }

    private static func containsAny(_ text: String, keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }

    private static let sensitiveBundleIDs: Set<String> = [
        "com.apple.securityagent",
        "com.apple.loginwindow",
        "com.apple.screensharing.agent",
        "com.apple.terminal",
        "com.googlecode.iterm2",
        "dev.warp.warp-stable",
        "dev.warp.warppreview",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword8",
        "com.bitwarden.desktop",
        "com.lastpass.lpmac",
        "org.keepassxc.keepassxc",
        "com.dashlane.dashlanephonefinal"
    ]
}

private enum ContextCaptureAttempt: Sendable, Equatable {
    case candidate(WindowContextCandidate?), failed, timeout
}

/// Cancellation/timeout can finish without waiting for an uncooperative AX request.
private final class ContextCaptureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: ContextCaptureAttempt?
    private var continuation: CheckedContinuation<ContextCaptureAttempt, Never>?
    private var tasks: [Task<Void, Never>] = []
    func install(_ continuation: CheckedContinuation<ContextCaptureAttempt, Never>) {
        lock.lock()
        if let outcome { lock.unlock(); continuation.resume(returning: outcome) }
        else { self.continuation = continuation; lock.unlock() }
    }
    func attach(_ tasks: [Task<Void, Never>]) {
        lock.lock()
        if outcome != nil { lock.unlock(); tasks.forEach { $0.cancel() } }
        else { self.tasks = tasks; lock.unlock() }
    }
    func finish(_ outcome: ContextCaptureAttempt) {
        lock.lock()
        guard self.outcome == nil else { lock.unlock(); return }
        self.outcome = outcome
        let continuation = self.continuation
        self.continuation = nil
        let tasks = self.tasks
        self.tasks = []
        lock.unlock()
        continuation?.resume(returning: outcome)
        tasks.forEach { $0.cancel() }
    }
}
