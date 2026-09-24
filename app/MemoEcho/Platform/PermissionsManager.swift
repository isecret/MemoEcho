import AVFoundation
import ApplicationServices
import AppKit
import Foundation

// MARK: - Permission Status

enum MicrophonePermission: String, Sendable {
    case notDetermined
    case granted
    case denied
    case restricted
}

enum AccessibilityPermission: String, Sendable {
    case granted
    case requiresManualEnable
}

enum MicrophoneAuthorizationSource: Sendable {
    case standard
    case settings
}

// MARK: - Permission Errors

enum PermissionError: LocalizedError, Equatable, Sendable {
    case microphonePermissionDenied
    case accessibilityPermissionDenied

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            "麦克风权限未开启，无法录音"
        case .accessibilityPermissionDenied:
            "辅助功能权限未开启，无法开始录音"
        }
    }
}

// MARK: - PermissionsManager

/// 管理麦克风与辅助功能权限的检测、申请与引导
@MainActor
@Observable
final class PermissionsManager {

    struct Operations {
        var microphoneStatus: () -> MicrophonePermission
        var accessibilityStatus: () -> AccessibilityPermission
        var requestMicrophone: @MainActor () async -> Void
        var openMicrophoneSettings: () -> Void
        var openAccessibilitySettings: () -> Void

        static var system: Self {
            Self(
                microphoneStatus: {
                    switch AVCaptureDevice.authorizationStatus(for: .audio) {
                    case .notDetermined: .notDetermined
                    case .authorized: .granted
                    case .denied: .denied
                    case .restricted: .restricted
                    @unknown default: .restricted
                    }
                },
                accessibilityStatus: { AXIsProcessTrusted() ? .granted : .requiresManualEnable },
                requestMicrophone: {
                    await withCheckedContinuation { continuation in
                        AVCaptureDevice.requestAccess(for: .audio) { _ in continuation.resume() }
                    }
                },
                openMicrophoneSettings: {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(url)
                    }
                },
                openAccessibilitySettings: {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            )
        }
    }

    private enum Authorization { case microphone, microphoneSettings, accessibility }
    private let operations: Operations
    private var accessibilityStatusQueryEnabled: Bool
    private var authorization: Authorization?
    private var leftAppForAuthorization = false
    var onMicrophoneAuthorizationStarted: ((MicrophoneAuthorizationSource) -> Void)?
    var onMicrophoneAuthorizationFinished: (() -> Void)?
    var onAccessibilityGuideRequested: (() -> Bool)?
    var onAccessibilityGranted: (() -> Void)?
    private(set) var accessibilityGuideError: String?

    private(set) var microphoneStatus: MicrophonePermission = .notDetermined
    private(set) var accessibilityStatus: AccessibilityPermission = .requiresManualEnable
    private(set) var isRequestingMicrophonePermission = false
    var isHandlingAuthorization: Bool { authorization != nil }

    init(operations: Operations = .system, accessibilityStatusQueryEnabled: Bool = false) {
        self.operations = operations
        self.accessibilityStatusQueryEnabled = accessibilityStatusQueryEnabled
        refreshAll()
    }

    // MARK: - Refresh

    func refreshAll() {
        checkMicrophonePermission()
        checkAccessibilityPermission()
        if authorization == .microphoneSettings, microphoneStatus == .granted {
            authorization = nil
        } else if authorization == .accessibility, accessibilityStatus == .granted {
            authorization = nil
        }
    }

    func applicationDidResignActive() {
        if isHandlingAuthorization { leftAppForAuthorization = true }
    }

    func applicationDidBecomeActive() {
        if leftAppForAuthorization, !isRequestingMicrophonePermission {
            authorization = nil
            leftAppForAuthorization = false
        }
        refreshAll()
    }

    // MARK: - Microphone

    func checkMicrophonePermission() {
        microphoneStatus = operations.microphoneStatus()
    }

    /// 请求麦克风权限（仅 .notDetermined 时有效）
    func requestMicrophonePermission(source: MicrophoneAuthorizationSource = .standard) async {
        checkMicrophonePermission()
        guard microphoneStatus == .notDetermined, !isHandlingAuthorization else { return }

        authorization = .microphone
        isRequestingMicrophonePermission = true
        onMicrophoneAuthorizationStarted?(source)
        await operations.requestMicrophone()
        isRequestingMicrophonePermission = false
        authorization = nil
        leftAppForAuthorization = false
        checkMicrophonePermission()
        onMicrophoneAuthorizationFinished?()
    }

    // MARK: - Enforcement APIs (供 E4/E7/E8 使用)

    /// 确保麦克风权限已授予，否则抛出错误
    func ensureMicrophoneAuthorized() throws {
        checkMicrophonePermission()
        guard microphoneStatus == .granted else {
            throw PermissionError.microphonePermissionDenied
        }
    }

    // MARK: - Accessibility

    func checkAccessibilityPermission() {
        // A trust query can add a new app to System Settings before the user drags it there.
        guard accessibilityStatusQueryEnabled else { return }
        updateAccessibilityStatus()
    }

    /// A deliberate hotkey press may check an existing installation without enabling launch-time polling.
    func checkAccessibilityPermissionForVoiceInput() {
        updateAccessibilityStatus()
    }

    private func updateAccessibilityStatus() {
        let wasGranted = accessibilityStatus == .granted
        accessibilityStatus = operations.accessibilityStatus()
        if !wasGranted, accessibilityStatus == .granted {
            onAccessibilityGranted?()
        }
    }

    /// A drag attempt permits status checks; it does not imply authorization.
    func beginAccessibilityStatusChecksAfterDrag() {
        accessibilityStatusQueryEnabled = true
        checkAccessibilityPermission()
    }

    /// 打开系统设置，并由应用协调器展示可拖拽的授权引导。
    func promptAndOpenAccessibilitySettings() {
        refreshAll()
        guard accessibilityStatus != .granted, !isHandlingAuthorization else { return }
        authorization = .accessibility
        accessibilityGuideError = nil
        if let onAccessibilityGuideRequested {
            if !onAccessibilityGuideRequested() {
                authorization = nil
                accessibilityGuideError = "无法打开辅助功能设置，请在系统设置中手动开启 MemoEcho。"
            }
        } else {
            operations.openAccessibilitySettings()
        }
        checkAccessibilityPermission()
    }

    func cancelAccessibilityGuide() {
        if authorization == .accessibility { authorization = nil }
        leftAppForAuthorization = false
    }

    /// 打开系统设置 → 隐私与安全 → 麦克风
    func openMicrophoneSettings() {
        refreshAll()
        guard microphoneStatus == .denied, !isHandlingAuthorization else { return }
        authorization = .microphoneSettings
        operations.openMicrophoneSettings()
    }

    /// 确保辅助功能权限已授予，否则抛出错误
    func ensureAccessibilityAuthorized() throws {
        checkAccessibilityPermission()
        guard accessibilityStatus == .granted else {
            throw PermissionError.accessibilityPermissionDenied
        }
    }
}

/// Restore only the window that initiated a transient microphone prompt.
/// The persistent System Settings flow deliberately does not use this policy.
@MainActor
final class MicrophoneAuthorizationFocusRestorer {
    struct Operations {
        var isAppActive: @MainActor () -> Bool
        var captureOriginRestore: @MainActor () -> (@MainActor () -> Void)?

        static var system: Self {
            Self(
                isAppActive: { NSApp.isActive },
                captureOriginRestore: {
                    guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return nil }
                    return { [weak window] in
                        guard let window, window.isVisible else { return }
                        NSApp.activate()
                        window.makeKeyAndOrderFront(nil)
                    }
                }
            )
        }
    }

    private let operations: Operations
    private var startedInApp = false
    private var source: MicrophoneAuthorizationSource = .standard
    private var restoreOrigin: (@MainActor () -> Void)?
    private var delayedRestoreTask: Task<Void, Never>?

    init(operations: Operations = .system) {
        self.operations = operations
    }

    func began(source: MicrophoneAuthorizationSource = .standard) {
        delayedRestoreTask?.cancel()
        delayedRestoreTask = nil
        self.source = source
        startedInApp = operations.isAppActive()
        restoreOrigin = startedInApp ? operations.captureOriginRestore() : nil
    }

    func finished() {
        defer {
            startedInApp = false
            source = .standard
            restoreOrigin = nil
        }
        guard startedInApp, let restoreOrigin else { return }
        if !operations.isAppActive() { restoreOrigin() }
        let requestSource = source
        delayedRestoreTask = Task { [weak self] in
            // The settings permission row can refresh before macOS finishes restoring
            // its prior frontmost app. Keep that return window bounded so a later
            // deliberate app switch is not pulled back.
            let checkDelays = requestSource == .settings
                ? [50] + Array(repeating: 100, count: 10)
                : [50] + Array(repeating: 100, count: 5)
            for delay in checkDelays {
                try? await Task.sleep(for: .milliseconds(delay))
                guard let self, !Task.isCancelled else { return }
                if !self.operations.isAppActive() {
                    restoreOrigin()
                    return
                }
            }
        }
    }
}
