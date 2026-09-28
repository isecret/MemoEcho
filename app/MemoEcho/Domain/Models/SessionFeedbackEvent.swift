import Foundation

/// 会话反馈事件，由 SessionCoordinator 发出，驱动 HUD 和音效
enum SessionFeedbackEvent: Sendable {
    case recordingSignalChanged(missing: Bool)
    case recordingStarted
    /// 采集已经启动，按实际输入/输出设备执行 Typeless 的提示音延迟。
    case startSoundCue(delayMs: Int)
    case recordingStopped
    case modeSwitched(TextProcessingMode)
    case recoveryStarted
    case outputDispatched
    case processingFinished
    case dictionaryTermLearned(String)
    case processingCancelled
    case processingFailed(HUDFailureReason)
}
