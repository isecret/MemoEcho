import Foundation

enum SetupStep: String, Codable, CaseIterable, Sendable {
    case welcome, asr, llm, permissions, hotkey, tryIt

    var number: Int? {
        switch self {
        case .welcome: nil
        case .asr: 1
        case .llm: 2
        case .permissions: 3
        case .hotkey: 4
        case .tryIt: 5
        }
    }

    var title: String {
        switch self {
        case .welcome: "欢迎使用 MemoEcho"
        case .asr: "选择语音识别方式"
        case .llm: "连接 AI 模型"
        case .permissions: "允许录音和输入文字"
        case .hotkey: "设置快捷键"
        case .tryIt: "设置完成"
        }
    }

    var subtitle: String {
        switch self {
        case .welcome: "多说话，少打字。"
        case .asr: "在本机识别，或使用云端服务。"
        case .llm: "删掉口头禅，保留你改口后的想法。"
        case .permissions: "开启麦克风和辅助功能权限。"
        case .hotkey: "按一下开始录音，再按一下结束。"
        case .tryIt: "可以开始用了，也可以先在这里试一句。"
        }
    }
}

/// 展示进度不代表语音输入实际可用；运行前仍需重新检查 readiness。
struct OnboardingProgress: Codable, Equatable {
    var lastVisitedStep: SetupStep = .welcome
    var hasFinishedPresentation = false
    var hasConfirmedHotkey = false
    var hasAttemptedAccessibilityDrag = false

    init(
        lastVisitedStep: SetupStep = .welcome,
        hasFinishedPresentation: Bool = false,
        hasConfirmedHotkey: Bool = false,
        hasAttemptedAccessibilityDrag: Bool = false
    ) {
        self.lastVisitedStep = lastVisitedStep
        self.hasFinishedPresentation = hasFinishedPresentation
        self.hasConfirmedHotkey = hasConfirmedHotkey
        self.hasAttemptedAccessibilityDrag = hasAttemptedAccessibilityDrag
    }

}

enum ReadinessStatus: Equatable {
    case ready
    case pending(String)
    case blocked(String)

    var isReady: Bool { self == .ready }

    var message: String? {
        switch self {
        case .ready: nil
        case .pending(let message), .blocked(let message): message
        }
    }
}

struct VoiceInputReadiness: Equatable {
    var hotkey: ReadinessStatus
    var microphone: ReadinessStatus
    var accessibility: ReadinessStatus
    var asr: ReadinessStatus
    var llm: ReadinessStatus

    var isReady: Bool {
        hotkey.isReady && microphone.isReady && accessibility.isReady && asr.isReady && llm.isReady
    }

    var nextRequiredStep: SetupStep? {
        if !asr.isReady { return .asr }
        if !llm.isReady { return .llm }
        if !microphone.isReady || !accessibility.isReady { return .permissions }
        if !hotkey.isReady { return .hotkey }
        return nil
    }

    static func make(
        hotkeyResult: HotkeyRegistrationResult,
        hasConfirmedHotkey: Bool,
        microphone: MicrophonePermission,
        accessibility: AccessibilityPermission,
        asrConfig: ASRConfig,
        localModelsAvailable: Bool,
        cloudStatus: CloudASRValidationDisplayStatus,
        llmStatus: LLMModelStatus
    ) -> Self {
        let hotkey: ReadinessStatus
        switch hotkeyResult {
        case .success:
            hotkey = hasConfirmedHotkey ? .ready : .blocked("请确认要使用的快捷键")
        case .failure(let reason):
            hotkey = .blocked(reason)
        }

        let microphoneReadiness: ReadinessStatus
        switch microphone {
        case .granted: microphoneReadiness = .ready
        case .notDetermined: microphoneReadiness = .blocked("请允许使用麦克风")
        case .denied: microphoneReadiness = .blocked("请在系统设置中开启麦克风权限")
        case .restricted: microphoneReadiness = .blocked("麦克风访问受系统限制，无法在此开启")
        }

        let asr: ReadinessStatus
        if asrConfig.selectedPlatform == .localSenseVoice {
            if asrConfig.local.modelStatus == .downloading {
                asr = .pending("语音模型正在下载")
            } else if localModelsAvailable {
                asr = .ready
            } else {
                switch asrConfig.local.modelStatus {
                case .downloading: asr = .pending("语音模型正在下载")
                case .failed: asr = .blocked("语音模型下载失败，请重试")
                case .ready, .notDownloaded: asr = .blocked("请下载本地语音模型")
                }
            }
        } else if !CloudASRValidationInput(platform: asrConfig.selectedPlatform, asrConfig: asrConfig).isComplete {
            asr = .blocked("请填写云端识别配置")
        } else {
            switch cloudStatus {
            case .ready: asr = .ready
            case .checking: asr = .pending("正在验证云端识别配置")
            case .incomplete: asr = .blocked("请验证云端识别配置")
            case .failed: asr = .blocked("云端识别验证失败，请检查配置后重试")
            }
        }

        let llm: ReadinessStatus
        switch llmStatus {
        case .ready: llm = .ready
        case .checking: llm = .pending("正在验证 AI 模型")
        case .incomplete: llm = .blocked("请填写 AI 模型配置并验证连接")
        case .failed: llm = .blocked("AI 模型验证失败，请检查配置后重试")
        }

        return Self(
            hotkey: hotkey,
            microphone: microphoneReadiness,
            accessibility: accessibility == .granted ? .ready : .blocked("请开启辅助功能权限"),
            asr: asr,
            llm: llm
        )
    }
}
