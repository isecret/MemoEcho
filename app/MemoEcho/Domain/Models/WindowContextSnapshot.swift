import Foundation

/// 当前聚焦输入环境的会话级快照，仅在内存中短暂保存
struct WindowContextSnapshot: Equatable, Sendable {
    let appName: String?
    let bundleID: String?
    let windowTitle: String?
    let surfaceKind: InputSurfaceKind
    let elementRole: String?
    let elementSubrole: String?
    let placeholder: String?
    let selectedText: String?
    let surroundingTextBefore: String?
    let surroundingTextAfter: String?
    let nearbyLabels: [String]
    var browserURL: String? = nil
    var visibleText: String? = nil
    var isEditable: Bool? = nil
    var supportsMarkdown: Bool? = nil
    var selection: NSRange? = nil
    var textCaptureBlocked = false
    var fieldStatus: [String: ContextFieldStatus] = [:]
    var captureMilliseconds = 0
}

enum ContextFieldStatus: String, Sendable, Equatable {
    case available, unavailable, redacted, truncated, timeout
}
