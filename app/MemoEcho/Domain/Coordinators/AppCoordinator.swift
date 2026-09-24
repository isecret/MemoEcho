import AppKit
import Foundation
import SwiftUI

/// 应用生命周期协调器，负责菜单栏入口、设置页与快捷键管理
@MainActor
@Observable
final class AppCoordinator {
    enum HotkeyAction: Equatable {
        case startRecording
        case finishRecording
    }

    enum SpecialHotkeyEffect: Equatable {
        case none
        case showPendingHUD
        case dismissPendingHUD
        case perform(HotkeyAction)
    }

    @MainActor
    struct SpecialHotkeyInteraction {
        private(set) var pendingAction: HotkeyAction?

        mutating func handle(
            _ gestureAction: SpecialHotkeyGestureAction,
            sessionState: SessionState
        ) -> SpecialHotkeyEffect {
            switch gestureAction {
            case .none:
                return .none

            case .began:
                let action = AppCoordinator.hotkeyAction(for: sessionState)
                pendingAction = action
                return action == .startRecording ? .showPendingHUD : .none

            case .confirmed:
                guard let action = pendingAction else { return .none }
                pendingAction = nil
                return .perform(action)

            case .cancelled:
                let action = pendingAction
                pendingAction = nil
                return action == .startRecording ? .dismissPendingHUD : .none
            }
        }
    }

    let configStore: ConfigStore
    let permissionsManager: PermissionsManager
    let accessibilityGuideController: AccessibilityAuthorizationGuideController
    let audioDeviceManager: AudioDeviceManager
    let sessionCoordinator: SessionCoordinator
    let hotkeyManager: HotkeyManager
    let hudFeedbackController: HUDFeedbackController
    let dictionaryStore: PersonalDictionaryStore
    let llmModelListService: LLMModelListService
    let modelDownloadManager: ModelDownloadManager
    let llmValidationService: LLMValidationService
    let cloudASRValidationService: CloudASRValidationService
    let readinessService: VoiceInputReadinessService
    let onboardingCoordinator: OnboardingCoordinator
    let updateService: AppUpdateService

    var selectedSettingsTab: SettingsTab = .general {
        didSet {
            scheduleSettingsWindowResize(to: selectedSettingsTab, animated: true)
        }
    }

    private var settingsWindowController: NSWindowController?
    private var settingsToolbarCoordinator: SettingsToolbarCoordinator?
    private var settingsContentSizes: [SettingsTab: NSSize] = [:]
    private var pendingSettingsResize: DispatchWorkItem?
    private var specialHotkeyInteraction = SpecialHotkeyInteraction()
    private let microphoneFocusRestorer = MicrophoneAuthorizationFocusRestorer()
    private let recordingStartGate = RecordingStartGate()
    private var onboardingWindowController: NSWindowController?
    private var onboardingWindowDelegate: OnboardingWindowDelegate?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var recordingValidationIdentity: (llm: String, asr: String)?

    init() {
        let store = ConfigStore()
        let perms = PermissionsManager()
        let audioDevices = AudioDeviceManager(configStore: store)
        let dict = PersonalDictionaryStore()
        configStore = store
        permissionsManager = perms
        accessibilityGuideController = AccessibilityAuthorizationGuideController(
            permissionsManager: perms,
            onAppDroppedIntoSettings: {
                var progress = store.onboardingProgress
                if !progress.hasAttemptedAccessibilityDrag {
                    progress.hasAttemptedAccessibilityDrag = true
                    try? store.saveOnboardingProgress(progress)
                }
                perms.beginAccessibilityStatusChecksAfterDrag()
            }
        )
        audioDeviceManager = audioDevices
        dictionaryStore = dict
        sessionCoordinator = SessionCoordinator(
            permissionsManager: perms,
            configStore: store,
            audioDeviceManager: audioDevices,
            dictionaryStore: dict
        )
        hotkeyManager = HotkeyManager()
        llmModelListService = LLMModelListService()
        modelDownloadManager = ModelDownloadManager(configStore: store)
        llmValidationService = LLMValidationService(onThinkingUnsupported: { [weak store] in
            try? store?.markThinkingDisabledForCurrentLLM()
        })
        cloudASRValidationService = CloudASRValidationService(configStore: store)
        readinessService = VoiceInputReadinessService(
            configStore: store, permissionsManager: perms,
            llmValidationService: llmValidationService,
            cloudASRValidationService: cloudASRValidationService
        )
        onboardingCoordinator = OnboardingCoordinator(
            configStore: store, permissionsManager: perms,
            modelDownloadManager: modelDownloadManager, llmModelListService: llmModelListService,
            llmValidationService: llmValidationService,
            cloudASRValidationService: cloudASRValidationService,
            readinessService: readinessService
        )
        updateService = AppUpdateService()

        let hud = HUDFeedbackController()
        hudFeedbackController = hud
        sessionCoordinator.onFeedbackEvent = { [weak self] event in
            self?.hudFeedbackController.handleEvent(event)
            if case .processingFailed = event { self?.invalidateFailedConfiguration() }
            if let self, self.sessionCoordinator.isOnboardingTrial {
                self.onboardingCoordinator.handleTrialFeedback(event, error: self.sessionCoordinator.currentError)
            }
        }
        hud.isInteractionSoundEnabled = { [weak store] in
            store?.generalConfig.interactionSoundEnabled ?? true
        }
        hud.audioLevelProvider = { [weak sessionCoordinator] in
            sessionCoordinator?.currentAudioLevel() ?? 0
        }
        hud.onCancelRecording = { [weak sessionCoordinator] in
            sessionCoordinator?.cancel()
        }
        hud.onConfirmRecording = { [weak sessionCoordinator] in
            sessionCoordinator?.finishRecording()
        }
        hud.onToggleProcessingMode = { [weak sessionCoordinator] in
            sessionCoordinator?.toggleProcessingMode()
        }
        onboardingCoordinator.onApplyHotkey = { [weak self] combo in
            self?.applyHotkey(combo) ?? .failure("快捷键服务尚未就绪")
        }
        onboardingCoordinator.onHotkeyCaptureSuspended = { [weak self] in self?.setHotkeyCaptureSuspended($0) }
        onboardingCoordinator.onFinish = { [weak self] in self?.onboardingWindowController?.close() }
        onboardingCoordinator.onOpenRecoverySettings = { [weak self] step in
            self?.onboardingWindowController?.close()
            self?.openRecoverySettings(for: step)
        }
        onboardingCoordinator.onCancelTrial = { [weak self] in
            guard let self, self.sessionCoordinator.isOnboardingTrial else { return }
            self.sessionCoordinator.cancel()
        }
        perms.onMicrophoneAuthorizationStarted = { [weak self] source in
            self?.microphoneFocusRestorer.began(source: source)
        }
        perms.onMicrophoneAuthorizationFinished = { [weak self] in self?.microphoneFocusRestorer.finished() }
        perms.onAccessibilityGuideRequested = { [weak self] in
            guard let self else { return false }
            return self.accessibilityGuideController.present(originWindow: NSApp.keyWindow ?? NSApp.mainWindow)
        }
        perms.onAccessibilityGranted = { [weak self] in
            guard let self else { return }
            self.setupHotkey()
            if self.onboardingCoordinator.isPresented { self.onboardingCoordinator.refresh() }
        }
        lifecycleObservers = [
            NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.permissionsManager.applicationDidResignActive() }
            },
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.permissionsManager.applicationDidBecomeActive()
                    if self.onboardingCoordinator.isPresented { self.onboardingCoordinator.refresh() }
                }
            }
        ]
    }

    /// 应用启动后注册快捷键并检查首次配置
    func handleAppLaunch() {
        setupHotkey()
        updateService.start()
        updateInteractionSoundKeepAlive()
        if configStore.asrConfig.local.modelStatus == .downloading {
            try? configStore.updateLocalModelStatus(.failed, error: "下载已中断，请重试")
        }
        readinessService.refresh()

        // Ensure system login item state matches config
        if configStore.generalConfig.launchAtLogin {
            try? LaunchAtLoginManager.setEnabled(true)
        }

        guard configStore.requiresInitialSetup else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            openOnboardingWindow()
        }
    }

    func openOnboardingWindow(at step: SetupStep? = nil) {
        guard configStore.requiresInitialSetup else { return }
        guard sessionCoordinator.state.allowsRecordingStart else { return }
        hudFeedbackController.dismissHotkeyCandidate()
        onboardingCoordinator.prepareForPresentation(at: step)
        if onboardingWindowController == nil {
            let window = Self.makeOnboardingWindow(coordinator: onboardingCoordinator)
            window.center()
            let delegate = OnboardingWindowDelegate { [weak self] in self?.onboardingCoordinator.dismissed() }
            onboardingWindowDelegate = delegate
            window.delegate = delegate
            onboardingWindowController = NSWindowController(window: window)
        }
        onboardingWindowController?.showWindow(nil)
        onboardingWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Keep the native window chrome separate from setup state and presentation side effects.
    static func makeOnboardingWindow(coordinator: OnboardingCoordinator) -> NSWindow {
        let hosting = NSHostingController(rootView: OnboardingView(coordinator: coordinator))
        let window = NSWindow(contentViewController: hosting)
        window.title = "设置 MemoEcho"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.titleVisibility = .hidden
        window.toolbarStyle = .unifiedCompact
        window.toolbar = OnboardingTitleToolbar(title: window.title)
        window.titlebarSeparatorStyle = .none
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 760, height: 660))
        window.isReleasedWhenClosed = false
        return window
    }

    private func invalidateFailedConfiguration() {
        guard let error = sessionCoordinator.currentError else { return }
        switch error {
        case .llmConfigurationIncomplete, .invalidLLMConfiguration, .llmNetworkFailure,
             .llmEmptyResponse, .llmInvalidResponse:
            guard recordingValidationIdentity?.llm == currentValidationIdentity.llm else { return }
            llmValidationService.invalidateCurrentValidation()
        case .cloudASRConfigurationIncomplete, .cloudASRAuthenticationFailure, .cloudASRNetworkFailure, .cloudASRInvalidResponse:
            guard recordingValidationIdentity?.asr == currentValidationIdentity.asr else { return }
            cloudASRValidationService.invalidateCurrentValidation()
        default: break
        }
    }

    /// 旧会话请求失败不能使设置页刚保存的新配置失效；内部 thinking 回退不改变连接身份。
    private var currentValidationIdentity: (llm: String, asr: String) {
        let llm = LLMValidationInput(baseURL: configStore.llmConfig.baseURL, apiKey: configStore.openAIAPIKey,
                                     model: configStore.llmConfig.model, thinkingDisabled: false)
        let asr = CloudASRValidationInput(platform: configStore.asrConfig.selectedPlatform, asrConfig: configStore.asrConfig)
        return (llm.fingerprint, asr.fingerprint)
    }

    func setInteractionSoundKeepAliveEnabled(_ enabled: Bool) {
        hudFeedbackController.setInteractionSoundKeepAliveEnabled(enabled)
    }

    func setHotkeyCaptureSuspended(_ suspended: Bool) {
        hotkeyManager.setSuspended(suspended)
    }

    private func updateInteractionSoundKeepAlive() {
        setInteractionSoundKeepAliveEnabled(configStore.generalConfig.interactionSoundEnabled)
    }

    /// 通过 AppKit 托管单例设置窗口，避免依赖 SwiftUI 默认 selector
    func openSettingsWindow(tab: SettingsTab? = nil) {
        guard configStore.canOpenSettings else { return }
        if let tab { selectedSettingsTab = tab }
        if settingsWindowController == nil {
            let hostingController = NSHostingController(rootView: SettingsView(appCoordinator: self))
            let window = NSWindow(contentViewController: hostingController)
            window.title = selectedSettingsTab.title
            window.setContentSize(settingsContentSize(for: selectedSettingsTab))
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.titleVisibility = .visible
            window.toolbarStyle = .preference
            window.toolbar = makeSettingsToolbar()
            window.isReleasedWhenClosed = false
            window.center()
            window.initialFirstResponder = window.contentView
            settingsWindowController = NSWindowController(window: window)
        }

        settingsWindowController?.window?.toolbar?.selectedItemIdentifier = .settingsTab(selectedSettingsTab)

        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        if let window = settingsWindowController?.window {
            DispatchQueue.main.async {
                window.makeFirstResponder(window.contentView)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openRecoverySettings(for step: SetupStep) {
        let tab: SettingsTab = switch step {
        case .asr: .asr
        case .llm: .ai
        case .permissions: .permissions
        case .welcome, .hotkey, .tryIt: .general
        }
        openSettingsWindow(tab: tab)
    }

    func updateSettingsContentSize(_ size: CGSize, for tab: SettingsTab) {
        guard size.width > 0, size.height > 0 else { return }

        let contentSize = NSSize(
            width: ceil(size.width),
            height: ceil(size.height) + 1
        )
        let previousSize = settingsContentSizes[tab]
        guard previousSize == nil
            || abs((previousSize?.width ?? 0) - contentSize.width) > 0.5
            || abs((previousSize?.height ?? 0) - contentSize.height) > 0.5
        else {
            return
        }

        settingsContentSizes[tab] = contentSize
        guard tab == selectedSettingsTab else { return }
        scheduleSettingsWindowResize(to: tab, animated: settingsWindowController?.window?.isVisible == true)
    }

    /// 将最近一次注入失败文本复制到系统剪贴板
    func copyLastFailureTextToClipboard() {
        guard let text = sessionCoordinator.lastInjectionFailureText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - 快捷键

    /// 注册全局快捷键并绑定按下切换回调
    func setupHotkey() {
        readinessService.hotkeyRegistrationResult = hotkeyManager.replace(with: configStore.generalConfig.hotkey)
        bindHotkeyCallbacks()
    }

    /// 尝试启用新快捷键；失败时保留原配置和原监听。
    @discardableResult
    func applyHotkey(_ hotkey: HotkeyCombo) -> HotkeyRegistrationResult {
        let result = Self.applyHotkey(hotkey, manager: hotkeyManager, configStore: configStore)
        readinessService.hotkeyRegistrationResult = hotkeyManager.registeredHotkey == configStore.generalConfig.hotkey
            ? .success : .failure("快捷键未能注册，请重新设置。")
        bindHotkeyCallbacks()
        return result
    }

    /// 注册和保存是一笔事务，落盘失败时恢复此前的实际监听。
    static func applyHotkey(_ hotkey: HotkeyCombo, manager: HotkeyManager, configStore: ConfigStore) -> HotkeyRegistrationResult {
        let previousHotkey = configStore.generalConfig.hotkey
        let result = manager.replace(with: hotkey)
        guard case .success = result else { return result }

        let config = GeneralConfig(
            hotkey: hotkey,
            interactionSoundEnabled: configStore.generalConfig.interactionSoundEnabled,
            translationTargetLanguage: configStore.generalConfig.translationTargetLanguage,
            launchAtLogin: configStore.generalConfig.launchAtLogin
        )
        do {
            try configStore.saveGeneralConfig(config, confirmingHotkey: true)
        } catch {
            let rollback = manager.replace(with: previousHotkey)
            return .failure(rollback == .success
                ? "保存快捷键失败，已恢复原快捷键。"
                : "保存快捷键失败，原快捷键也未能恢复，请重新设置。")
        }
        return .success
    }

    private func bindHotkeyCallbacks() {
        hotkeyManager.onKeyDown = { [weak self] in
            self?.handleHotkeyEvent()
        }
        hotkeyManager.onKeyUp = nil
        hotkeyManager.onSpecialGestureAction = { [weak self] action in
            self?.handleSpecialHotkeyGestureAction(action)
        }
    }

    static func hotkeyAction(for sessionState: SessionState) -> HotkeyAction? {
        switch sessionState {
        case let state where state.allowsRecordingStart:
            .startRecording
        case .recording:
            .finishRecording
        default:
            nil
        }
    }

    static func shouldStartOnboardingTrial(
        isSetupComplete: Bool,
        isOnboardingPresented: Bool,
        isOnboardingWindowKey: Bool,
        step: SetupStep
    ) -> Bool {
        isSetupComplete && isOnboardingPresented && isOnboardingWindowKey && step == .tryIt
    }

    private func handleHotkeyEvent() {
        guard let action = Self.hotkeyAction(for: sessionCoordinator.state) else {
            return
        }

        performHotkeyAction(action)
    }

    private func handleSpecialHotkeyGestureAction(_ gestureAction: SpecialHotkeyGestureAction) {
        let effect = specialHotkeyInteraction.handle(
            gestureAction,
            sessionState: sessionCoordinator.state
        )

        switch effect {
        case .none:
            break
        case .showPendingHUD:
            let isTrialInputActive = onboardingWindowController?.window?.isKeyWindow == true && onboardingCoordinator.canStartTrial
            if (configStore.hasCompletedInitialSetup || isTrialInputActive)
                && !permissionsManager.isHandlingAuthorization {
                hudFeedbackController.presentHotkeyCandidate()
            }
        case .dismissPendingHUD:
            hudFeedbackController.dismissHotkeyCandidate()
        case .perform(let action):
            performHotkeyAction(action)
        }
    }

    private func performHotkeyAction(_ action: HotkeyAction) {
        switch action {
        case .startRecording:
            hudFeedbackController.dismissHotkeyCandidate()
            guard !permissionsManager.isHandlingAuthorization else { return }
            if configStore.requiresInitialSetup {
                openOnboardingWindow()
                return
            }
            if !configStore.hasCompletedInitialSetup {
                openSettingsWindow(tab: .general)
                return
            }
            if Self.shouldStartOnboardingTrial(
                isSetupComplete: configStore.hasCompletedInitialSetup,
                isOnboardingPresented: onboardingCoordinator.isPresented,
                isOnboardingWindowKey: onboardingWindowController?.window?.isKeyWindow == true,
                step: onboardingCoordinator.step
            ) {
                checkAccessibilityForUserInitiatedVoiceInputIfNeeded()
                guard let trialID = onboardingCoordinator.beginTrial() else { return }
                recordingValidationIdentity = currentValidationIdentity
                sessionCoordinator.startRecording(output: .onboardingTrial { [weak onboardingCoordinator] text in
                    onboardingCoordinator?.receiveTrialText(text, for: trialID) ?? false
                })
                return
            }
            recordingStartGate.attemptStart(
                isAuthorizing: permissionsManager.isHandlingAuthorization,
                refresh: {
                    checkAccessibilityForUserInitiatedVoiceInputIfNeeded()
                    readinessService.refresh()
                    return readinessService.snapshot
                },
                showRecovery: { openRecoverySettings(for: $0) },
                startRecording: {
                    recordingValidationIdentity = currentValidationIdentity
                    sessionCoordinator.startRecording()
                }
            )
        case .finishRecording:
            sessionCoordinator.finishRecording()
        }
    }

    private func checkAccessibilityForUserInitiatedVoiceInputIfNeeded() {
        guard configStore.onboardingProgress.hasAttemptedAccessibilityDrag || configStore.hasCompletedInitialSetup else {
            return
        }
        permissionsManager.checkAccessibilityPermissionForVoiceInput()
    }

    private func makeSettingsToolbar() -> NSToolbar {
        let coordinator = SettingsToolbarCoordinator { [weak self] tab in
            self?.selectedSettingsTab = tab
        }
        settingsToolbarCoordinator = coordinator

        let toolbar = NSToolbar(identifier: "MemoEchoSettingsToolbar")
        toolbar.delegate = coordinator
        toolbar.displayMode = .iconAndLabel
        toolbar.sizeMode = .regular
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.selectedItemIdentifier = .settingsTab(.general)
        return toolbar
    }

    private func scheduleSettingsWindowResize(to tab: SettingsTab, animated: Bool) {
        pendingSettingsResize?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.resizeSettingsWindow(to: tab, animated: animated)
        }
        pendingSettingsResize = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func resizeSettingsWindow(to tab: SettingsTab, animated: Bool) {
        guard let window = settingsWindowController?.window else { return }

        let currentFrame = window.frame
        window.title = tab.title

        let contentRect = NSRect(origin: .zero, size: settingsContentSize(for: tab))
        let frameSize = window.frameRect(forContentRect: contentRect).size
        let newFrame = NSRect(
            x: currentFrame.minX,
            y: currentFrame.maxY - frameSize.height,
            width: frameSize.width,
            height: frameSize.height
        )

        window.setFrame(newFrame, display: true, animate: animated)
    }

    private func settingsContentSize(for tab: SettingsTab) -> NSSize {
        settingsContentSizes[tab] ?? tab.defaultContentSize
    }
}

@MainActor
private final class OnboardingWindowDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}

/// A native centered toolbar item avoids OS-dependent leading window-title placement.
private final class OnboardingTitleToolbar: NSToolbar, NSToolbarDelegate {
    private let titleText: String
    private let titleIdentifier = NSToolbarItem.Identifier("MemoEchoOnboardingTitle")

    init(title: String) {
        titleText = title
        super.init(identifier: "MemoEchoOnboardingToolbar")
        delegate = self
        displayMode = .iconOnly
        allowsUserCustomization = false
        centeredItemIdentifiers = [titleIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, titleIdentifier]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, titleIdentifier, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == titleIdentifier else { return nil }
        let title = NSTextField(labelWithString: titleText)
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        title.alignment = .center
        title.sizeToFit()
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = titleText
        item.view = title
        item.isBordered = false
        return item
    }
}

private final class SettingsToolbarCoordinator: NSObject, NSToolbarDelegate {
    private let onSelect: (SettingsTab) -> Void

    init(onSelect: @escaping (SettingsTab) -> Void) {
        self.onSelect = onSelect
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map { .settingsTab($0) }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let tab = itemIdentifier.settingsTab else { return nil }

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = tab.title
        item.paletteLabel = tab.title
        item.toolTip = tab.title
        item.image = NSImage(systemSymbolName: tab.systemImage, accessibilityDescription: tab.title)
        item.target = self
        item.action = #selector(selectToolbarItem(_:))
        return item
    }

    @MainActor
    @objc
    private func selectToolbarItem(_ sender: NSToolbarItem) {
        guard let tab = sender.itemIdentifier.settingsTab else { return }
        sender.toolbar?.selectedItemIdentifier = sender.itemIdentifier
        onSelect(tab)
    }
}

private extension NSToolbarItem.Identifier {
    static func settingsTab(_ tab: SettingsTab) -> NSToolbarItem.Identifier {
        NSToolbarItem.Identifier("MemoEchoSettingsToolbar.\(tab.rawValue)")
    }

    var settingsTab: SettingsTab? {
        let prefix = "MemoEchoSettingsToolbar."
        guard rawValue.hasPrefix(prefix) else { return nil }
        return SettingsTab(rawValue: String(rawValue.dropFirst(prefix.count)))
    }
}
