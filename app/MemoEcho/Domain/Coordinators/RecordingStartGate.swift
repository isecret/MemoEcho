import Foundation

/// 在 SessionCoordinator 捕获焦点、创建会话或操作音频之前执行。
@MainActor
final class RecordingStartGate {
    private var isChecking = false

    func attemptStart(
        isAuthorizing: Bool,
        refresh: () -> VoiceInputReadiness,
        showRecovery: (SetupStep) -> Void,
        startRecording: () -> Void
    ) {
        guard !isChecking, !isAuthorizing else { return }
        isChecking = true
        defer { isChecking = false }

        let readiness = refresh()
        guard readiness.isReady else {
            showRecovery(readiness.nextRequiredStep ?? .hotkey)
            return
        }
        startRecording()
    }
}
