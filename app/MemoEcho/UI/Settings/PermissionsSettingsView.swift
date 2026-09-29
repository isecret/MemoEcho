import SwiftUI

/// Shared labels for settings and onboarding; permission requests stay in PermissionsManager.
enum PermissionCopy {
    static let microphoneTitle = "麦克风权限"
    static let accessibilityTitle = "辅助功能权限"
    static let requestTitle = "请求权限"
    static let requestingTitle = "请求中…"
    static let openSettingsTitle = "打开系统设置"
    static let microphoneRestriction = "系统限制了麦克风权限，无法在 MemoEcho 中开启。"

    static func microphoneStatus(_ status: MicrophonePermission) -> String {
        switch status {
        case .notDetermined: "尚未请求"
        case .granted: "已授权"
        case .denied: "已拒绝"
        case .restricted: "受限（由系统策略控制）"
        }
    }

    static func accessibilityStatus(_ status: AccessibilityPermission) -> String {
        switch status {
        case .unchecked: "未检查"
        case .granted: "已授权"
        case .requiresManualEnable: "未授权"
        }
    }

    static func microphoneAction(_ status: MicrophonePermission, isRequesting: Bool = false) -> String? {
        switch status {
        case .notDetermined: isRequesting ? requestingTitle : requestTitle
        case .denied: openSettingsTitle
        case .restricted, .granted: nil
        }
    }

    static func accessibilityAction(_ status: AccessibilityPermission) -> String? {
        switch status {
        case .unchecked: "检查权限"
        case .requiresManualEnable: openSettingsTitle
        case .granted: nil
        }
    }
}

struct PermissionsSettingsView: View {
    let permissionsManager: PermissionsManager

    var body: some View {
        Group {
            SettingsPaneSection {
                SettingsFormRow(title: PermissionCopy.microphoneTitle) {
                    HStack(spacing: 8) {
                        PermissionStatusBadge(granted: permissionsManager.microphoneStatus == .granted)
                        Text(PermissionCopy.microphoneStatus(permissionsManager.microphoneStatus))
                            .foregroundStyle(.secondary)
                        Spacer()
                        microphoneActionButton
                    }
                    .frame(width: SettingsFormLayout.controlWidth, alignment: .leading)
                }
            } footer: {
                Text(microphoneDescription)
            }

            SettingsPaneSection {
                SettingsFormRow(title: PermissionCopy.accessibilityTitle) {
                    HStack(spacing: 8) {
                        PermissionStatusBadge(granted: permissionsManager.accessibilityStatus == .unchecked
                                              ? nil : permissionsManager.accessibilityStatus == .granted)
                        Text(PermissionCopy.accessibilityStatus(permissionsManager.accessibilityStatus))
                            .foregroundStyle(.secondary)
                        Spacer()
                        accessibilityActionButton
                    }
                    .frame(width: SettingsFormLayout.controlWidth, alignment: .leading)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("用于向其他应用写入文字。")
                    if let error = permissionsManager.accessibilityGuideError {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
        }
        .onAppear { refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    private func refreshPermissions() {
        permissionsManager.checkAccessibilityPermissionForUserAction()
        permissionsManager.refreshAll()
    }

    // MARK: - Microphone

    private var microphoneDescription: String {
        switch permissionsManager.microphoneStatus {
        case .notDetermined:
            "用于录音。选择云端语音引擎时，录音会发送到对应服务识别。"
        case .denied:
            "麦克风权限已关闭。请在系统设置中为 MemoEcho 开启麦克风权限。"
        case .restricted:
            PermissionCopy.microphoneRestriction
        case .granted:
            "用于录音。选择云端语音引擎时，录音会发送到对应服务识别。"
        }
    }

    @ViewBuilder
    private var microphoneActionButton: some View {
        if let title = PermissionCopy.microphoneAction(
            permissionsManager.microphoneStatus,
            isRequesting: permissionsManager.isRequestingMicrophonePermission
        ) {
            Button(title) {
                if permissionsManager.microphoneStatus == .notDetermined {
                    Task { await permissionsManager.requestMicrophonePermission(source: .settings) }
                } else {
                    permissionsManager.openMicrophoneSettings()
                }
            }
            .disabled(permissionsManager.isHandlingAuthorization)
            // Refresh native focus geometry when the action title changes width.
            .id(title)
        }
    }

    // MARK: - Accessibility

    @ViewBuilder
    private var accessibilityActionButton: some View {
        if let title = PermissionCopy.accessibilityAction(permissionsManager.accessibilityStatus) {
            Button(title) {
                permissionsManager.promptAndOpenAccessibilitySettings()
            }
            .disabled(permissionsManager.isHandlingAuthorization)
            .id(title)
        }
    }
}

// MARK: - Status Badge

private struct PermissionStatusBadge: View {
    let granted: Bool?

    var body: some View {
        Image(systemName: granted == nil ? "circle.dashed"
                  : granted == true ? "checkmark.circle.fill" : "xmark.circle.fill")
            .foregroundStyle(granted == nil ? Color.secondary : granted == true ? .green : .red)
            .imageScale(.large)
    }
}
