/// 仅提交当前编辑器真正修改过的草稿，防止关闭旧窗口时覆盖另一入口的新配置。
struct SettingsDraftTracker {
    private var savedFingerprint: String?
    private(set) var hasPendingChanges = false

    mutating func loaded(_ fingerprint: String) {
        savedFingerprint = fingerprint
        hasPendingChanges = false
    }

    @discardableResult
    mutating func changed(to fingerprint: String) -> Bool {
        hasPendingChanges = savedFingerprint != nil && fingerprint != savedFingerprint
        return hasPendingChanges
    }
}
