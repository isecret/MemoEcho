import AppKit
import SwiftUI

/// HUD 反馈控制器，统一驱动 HUD 窗口、状态转换、声波动画和音效播放
@MainActor
@Observable
final class HUDFeedbackController {
    static let defaultLearnedTermNoticeDismissSeconds = 2.4

    // MARK: - Observable State (HUDContentView 读取)

    private(set) var hudState: HUDState = .hidden { didSet { refreshLayout() } }
    private(set) var recordingSignalMissing = false { didSet { refreshLayout() } }
    private(set) var modeCueLabel: String? { didSet { refreshLayout() } }
    private(set) var barHeights: [CGFloat] = Array(repeating: HUDLayout.resetBarHeight, count: 7)
    private(set) var isHUDPresented = false

    private(set) var presentation = HUDLayout.measure(state: .hidden)
    private(set) var presentationGeneration: UInt64 = 0
    private(set) var recoveryActionPerformed = false
    private(set) var isCopyConfirmation = false

    // MARK: - Callbacks (由 AppCoordinator 注入)

    var onCancelRecording: (() -> Void)?
    var onConfirmRecording: (() -> Void)?
    var onToggleProcessingMode: (() -> Void)?
    var recoveryActionTitle: String? { didSet { refreshLayout() } }
    var onRecoveryAction: (() -> Void)?

    func performRecoveryAction(expectedGeneration: UInt64? = nil) {
        guard case .failure = hudState, recoveryActionTitle != nil,
              !recoveryActionPerformed,
              expectedGeneration == nil || expectedGeneration == presentationGeneration,
              let action = onRecoveryAction else { return }
        recoveryActionPerformed = true
        // Consume before invoking: the callback may synchronously publish the next state.
        onRecoveryAction = nil
        setRecoveryHover(false, generation: presentationGeneration)
        setRecoveryAccessibilityFocus(false, generation: presentationGeneration)
        action()
    }

    func invalidateRecoveryFeedback(expectedGeneration: UInt64) {
        guard presentationGeneration == expectedGeneration, case .failure = hudState else { return }
        clearRecoveryAction()
        dismissHUD()
    }

    func showCopyConfirmation() {
        guard !sessionBusy else { return }
        beginPresentation()
        clearRecoveryAction()
        isCopyConfirmation = true
        hudState = .notice("已复制")
        showHUD()
        scheduleDismiss(after: 1.2)
    }

    func clearRecoveryAction() {
        recoveryActionTitle = nil
        onRecoveryAction = nil
        updateMouseInteraction()
    }
    /// 返回 0-1 归一化电平的闭包，录音期间由 SessionCoordinator 提供
    var audioLevelProvider: (() -> Float)?
    /// 返回当前是否启用交互音效的闭包，由 AppCoordinator 提供
    var isInteractionSoundEnabled: (() -> Bool)?

    // MARK: - Private

    private let soundPlayer: FeedbackSoundPlaying
    private let modeCueDuration: Duration
    private let learnedTermNoticeDismissSeconds: Double
    private var hudWindow: HUDWindow?
    private var hostingView: NSHostingView<HUDContentView>?
    private var dismissTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var sessionBusy = false
    private var isDismissing = false
    private var countdown = HUDDismissCountdown()
    private var recoveryHovered = false
    private var recoveryFocused = false
    private var countdownReady = false

    private var opacityTask: Task<Void, Never>?
    private var modeCueTask: Task<Void, Never>?
    private var levelPollingTask: Task<Void, Never>?
    private var startSoundPlaybackTask: Task<Void, Never>?
    private var escEventTap: CFMachPort?
    private var escRunLoopSource: CFRunLoopSource?
    private var opacityGeneration: UInt64 = 0
    private var waveformEnvelope: CGFloat = 0
    private var waveformEnergy: CGFloat = 0
    private var waveformPhase: CGFloat = 0

    private static let barsCount = 7
    private static let activeWaveformProfile: [CGFloat] = [0.10, 0.42, 0.62, 0.88, 0.62, 0.42, 0.10]
    private static let activeWaveformPeakBias: [CGFloat] = [0, 0, 0.02, 0.14, 0.02, 0, 0]

    init(
        soundPlayer: FeedbackSoundPlaying = FeedbackSoundPlayer(),
        modeCueDuration: Duration = .milliseconds(650),
        learnedTermNoticeDismissSeconds: Double = HUDFeedbackController.defaultLearnedTermNoticeDismissSeconds
    ) {
        self.soundPlayer = soundPlayer
        self.modeCueDuration = modeCueDuration
        self.learnedTermNoticeDismissSeconds = learnedTermNoticeDismissSeconds
    }

    // MARK: - Public Event Handler

    /// 纯修饰键按下后的候选反馈。此时只显示 HUD，不启动录音相关副作用。
    func presentHotkeyCandidate() {
        beginPresentation()
        sessionBusy = true
        clearRecoveryAction()
        cancelPendingStartSound()
        clearModeCue()
        stopLevelPolling()
        stopEscMonitor()
        resetBars()
        hudState = .hotkeyPending

        showHUD(selectScreen: true)
    }

    /// 仅关闭仍处于候选态的 HUD，避免组合键误伤已经开始的录音。
    func dismissHotkeyCandidate() {
        guard hudState == .hotkeyPending else { return }
        beginPresentation()
        sessionBusy = false
        cancelPendingStartSound()
        clearModeCue()
        stopLevelPolling()
        stopEscMonitor()
        resetBars()
        dismissHUD()
    }

    /// 处理来自 SessionCoordinator 的反馈事件
    func handleEvent(_ event: SessionFeedbackEvent) {
        // Dictionary text is private input; do not interpolate event payloads into logs.
        switch event {
        case .dictionaryTermLearned(let term):
            guard !sessionBusy, !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if case .failure = hudState { return }
        case .recordingSignalChanged, .startSoundCue, .modeSwitched: break
        default: break
        }
        switch event {
        case .recordingSignalChanged, .startSoundCue, .modeSwitched: break
        default: beginPresentation()
        }

        switch event {
        case .recordingSignalChanged, .startSoundCue, .modeSwitched: break
        default: recordingSignalMissing = false
        }
        switch event {
        case .recordingSignalChanged(let missing):
            guard hudState == .recording else { return }
            recordingSignalMissing = missing
        case .recordingStarted:
            let selectScreen = hudState != .hotkeyPending
            sessionBusy = true
            clearRecoveryAction()
            cancelPendingStartSound()
            clearModeCue()
            hudState = .recording
            showHUD(selectScreen: selectScreen)
            startLevelPolling()
            startEscMonitor()

        case .startSoundCue(let delayMs):
            playStartSound(after: delayMs)

        case .recordingStopped:
            cancelPendingStartSound()
            clearModeCue()
            if shouldPlayInteractionSound {
                soundPlayer.playStop()
            }
            stopLevelPolling()
            stopEscMonitor()
            resetBars()
            hudState = .processing
            updateMouseInteraction()

        case .modeSwitched(let mode):
            let label = (mode == .translate) ? "TRANSLATE" : "DICTATE"
            guard hudState == .recording else { return }
            modeCueLabel = label
            modeCueTask?.cancel()
            let duration = modeCueDuration
            modeCueTask = Task { [weak self] in
                try? await Task.sleep(for: duration)
                guard let self, !Task.isCancelled else { return }
                guard self.hudState == .recording, self.modeCueLabel == label else { return }
                self.modeCueLabel = nil
                self.modeCueTask = nil
            }

        case .recoveryStarted:
            sessionBusy = true
            clearRecoveryAction()
            cancelPendingStartSound()
            clearModeCue()
            stopLevelPolling()
            stopEscMonitor()
            resetBars()
            hudState = .processing
            showHUD()

        case .outputDispatched:
            sessionBusy = false
            clearRecoveryAction()
            cancelPendingStartSound()
            clearModeCue()
            stopLevelPolling()
            stopEscMonitor()
            resetBars()
            dismissHUD()

        case .processingFinished:
            sessionBusy = false
            clearRecoveryAction()
            cancelPendingStartSound()
            clearModeCue()
            stopLevelPolling()
            stopEscMonitor()
            resetBars()
            dismissHUD()

        case .dictionaryTermLearned(let term):
            clearModeCue()
            stopLevelPolling()
            stopEscMonitor()
            resetBars()
            clearRecoveryAction()
            hudState = .notice(term.trimmingCharacters(in: .whitespacesAndNewlines))
            showHUD()
            scheduleDismiss(after: presentation.lines.count > 1 ? learnedTermNoticeDismissSeconds * 4 / 2.4 : learnedTermNoticeDismissSeconds)

        case .processingFailed(let reason):
            sessionBusy = false
            cancelPendingStartSound()
            clearModeCue()
            stopLevelPolling()
            stopEscMonitor()
            resetBars()
            hudState = .failure(reason)
            showHUD()
            scheduleDismiss(after: presentation.dismissSeconds ?? 2.4)

        case .processingCancelled:
            sessionBusy = false
            clearRecoveryAction()
            cancelPendingStartSound()
            clearModeCue()
            stopLevelPolling()
            stopEscMonitor()
            resetBars()
            dismissHUD()
        }
    }

    private func playStartSound(after delayMs: Int) {
        cancelPendingStartSound()
        guard shouldPlayInteractionSound else { return }

        startSoundPlaybackTask = Task { [weak self] in
            guard let self else { return }
            if delayMs > 0 {
                do { try await Task.sleep(for: .milliseconds(delayMs)) }
                catch { return }
            }
            guard !Task.isCancelled, self.hudState == .recording, self.shouldPlayInteractionSound else { return }
            self.soundPlayer.playStart()
            self.startSoundPlaybackTask = nil
        }
    }

    private func cancelPendingStartSound() {
        startSoundPlaybackTask?.cancel()
        startSoundPlaybackTask = nil
    }

    // MARK: - Audio Level Polling

    private func startLevelPolling() {
        levelPollingTask?.cancel()
        levelPollingTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    guard let self else { return }
                    let level = self.audioLevelProvider?() ?? 0
                    self.updateWaveform(level: level)
                    try await Task.sleep(for: .milliseconds(16))
                }
            } catch is CancellationError {
                // 正常取消退出
            } catch {}
        }
    }

    private func stopLevelPolling() {
        levelPollingTask?.cancel()
        levelPollingTask = nil
    }

    private var shouldPlayInteractionSound: Bool {
        isInteractionSoundEnabled?() ?? true
    }

    // MARK: - ESC Key Monitor

    /// 录音阶段监听 ESC 键以取消录音，并吞掉该按键避免穿透到前台应用
    private func startEscMonitor() {
        stopEscMonitor()

        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard
                type == .keyDown,
                let userInfo
            else {
                return Unmanaged.passRetained(event)
            }

            let controller = Unmanaged<HUDFeedbackController>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            let keycode = event.getIntegerValueField(.keyboardEventKeycode)

            // ESC
            if keycode == 53 {
                Task { @MainActor in
                    guard controller.hudState == .recording else { return }
                    controller.onCancelRecording?()
                }
                return nil
            }

            // Shift+Tab
            if keycode == 48 && event.flags.contains(.maskShift) {
                Task { @MainActor in
                    guard controller.hudState == .recording else { return }
                    controller.onToggleProcessingMode?()
                }
                return nil
            }

            return Unmanaged.passRetained(event)
        }

        let ref = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: ref
        ) else {
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        escEventTap = tap
        escRunLoopSource = source
    }

    private func stopEscMonitor() {
        if let source = escRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            escRunLoopSource = nil
        }

        if let tap = escEventTap {
            CFMachPortInvalidate(tap)
            escEventTap = nil
        }
    }

    /// 根据音频电平计算声波条高度：低幅待机 + 软触发的有声峰值
    private func updateWaveform(level: Float) {
        let clampedLevel = min(max(CGFloat(level), 0), 1)
        let maxH = HUDLayout.waveformMaxHeight
        let minH = HUDLayout.waveformMinHeight
        let presenceTarget = Self.smoothStep(edge0: 0.08, edge1: 0.17, value: clampedLevel)
        let energyTarget = Self.smoothStep(edge0: 0.08, edge1: 0.52, value: clampedLevel)

        let presenceRising: CGFloat = 0.42
        let presenceFalling: CGFloat = 0.16
        let presenceSmoothing = presenceTarget > waveformEnvelope ? presenceRising : presenceFalling
        waveformEnvelope += (presenceTarget - waveformEnvelope) * presenceSmoothing

        let energyRising: CGFloat = 0.24
        let energyFalling: CGFloat = 0.18
        let energySmoothing = energyTarget > waveformEnergy ? energyRising : energyFalling
        waveformEnergy += (energyTarget - waveformEnergy) * energySmoothing

        waveformPhase += 0.16 + waveformEnvelope * 0.12 + waveformEnergy * 0.08

        for i in 0..<Self.barsCount {
            let offset = CGFloat(i) * 0.68
            let pulse = (sin(waveformPhase + offset) + 1) * 0.5
            let sway = (sin(waveformPhase * 0.56 - offset * 0.9) + 1) * 0.5

            let profile = Self.activeWaveformProfile[i]
            let idleShape = 0.08 + profile * 0.03 + pulse * 0.025 + sway * 0.02

            let activeFloor = 0.2 + profile * 0.48
            let activeReach = 0.16 + profile * (0.14 + waveformEnergy * 0.22)
            let motion = 0.76 + pulse * 0.18 + sway * 0.1
            let peakBias = Self.activeWaveformPeakBias[i] * (0.75 + waveformEnergy * 0.25)
            let activeShape = min(1, activeFloor + activeReach * motion + peakBias)

            let normalizedHeight = idleShape + (activeShape - idleShape) * waveformEnvelope
            barHeights[i] = minH + normalizedHeight * (maxH - minH)
        }
    }

    private func resetBars() {
        waveformEnvelope = 0
        waveformEnergy = 0
        waveformPhase = 0
        barHeights = Array(repeating: HUDLayout.resetBarHeight, count: Self.barsCount)
    }

    private static func smoothStep(edge0: CGFloat, edge1: CGFloat, value: CGFloat) -> CGFloat {
        guard edge0 != edge1 else { return value >= edge1 ? 1 : 0 }
        let t = min(max((value - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private func clearModeCue() {
        modeCueTask?.cancel()
        modeCueTask = nil
        modeCueLabel = nil
    }

    // MARK: - Window Management

    private func showHUD(selectScreen: Bool = false) {
        ensureWindow()
        isDismissing = false
        if selectScreen || !isHUDPresented { hudWindow?.positionOnActiveScreen() }
        if !isHUDPresented { hudWindow?.alphaValue = 0 }
        refreshLayout()
        updateMouseInteraction()
        hudWindow?.orderFrontRegardless()
        isHUDPresented = true

        animateHUDAlpha(to: 1, duration: .milliseconds(200), hideWhenFinished: false)
    }

    private func dismissHUD() {
        isDismissing = true
        dismissTask?.cancel()
        clearModeCue()
        stopLevelPolling()
        stopEscMonitor()
        guard isHUDPresented else {
            hudState = .hidden
            return
        }
        animateHUDAlpha(to: 0, duration: .milliseconds(250), hideWhenFinished: true)
    }

    private func animateHUDAlpha(to target: CGFloat, duration: Duration, hideWhenFinished: Bool) {
        opacityTask?.cancel()
        // Only a new visibility animation supersedes this one. Recording and
        // sound events must not freeze an in-flight fade at partial opacity.
        opacityGeneration &+= 1
        let start = hudWindow?.alphaValue ?? target
        let generation = opacityGeneration
        let steps = target == 0 ? 15 : 12
        opacityTask = Task { [weak self] in
            for step in 1...steps {
                do {
                    try await Task.sleep(for: duration / steps)
                } catch {
                    return
                }
                guard let self, self.opacityGeneration == generation else { return }
                self.hudWindow?.alphaValue = start + (target - start) * CGFloat(step) / CGFloat(steps)
            }
            guard let self else { return }
            self.opacityTask = nil
            if hideWhenFinished {
                self.hudWindow?.orderOut(nil)
                self.hudWindow?.setInteractionRegion(nil)
                self.hudState = .hidden
                self.isHUDPresented = false
                self.isDismissing = false
                self.clearRecoveryAction()
            } else {
                self.countdownReady = true
                self.resumeCountdownIfNeeded()
            }
        }
    }

    private func beginPresentation() {
        presentationGeneration &+= 1
        dismissTask?.cancel()
        dismissTask = nil
        countdown = HUDDismissCountdown()
        countdownReady = false
        recoveryHovered = false
        recoveryFocused = false
        recoveryActionPerformed = false
        isCopyConfirmation = false
    }

    private func scheduleDismiss(after seconds: Double) {
        countdown = HUDDismissCountdown(remaining: seconds)
        resumeCountdownIfNeeded()
    }

    func setRecoveryHover(_ hovered: Bool, generation: UInt64) {
        guard generation == presentationGeneration, case .failure = hudState,
              recoveryActionTitle != nil else { return }
        recoveryHovered = hovered
        resumeCountdownIfNeeded()
    }

    func setRecoveryAccessibilityFocus(_ focused: Bool, generation: UInt64) {
        guard generation == presentationGeneration, case .failure = hudState,
              recoveryActionTitle != nil else { return }
        recoveryFocused = focused
        resumeCountdownIfNeeded()
    }

    private func resumeCountdownIfNeeded() {
        guard countdownReady, !isDismissing else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if (recoveryHovered || recoveryFocused) && !recoveryActionPerformed {
            countdown.pause(at: now)
            dismissTask?.cancel()
            dismissTask = nil
            return
        }
        guard dismissTask == nil, let seconds = countdown.resume(at: now) else { return }
        let generation = presentationGeneration
        dismissTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, self.presentationGeneration == generation else { return }
            self.dismissTask = nil
            self.dismissHUD()
        }
    }

    /// Grow the panel before publishing larger content; contract after SwiftUI has laid out.
    private func refreshLayout() {
        let next = HUDLayout.measure(state: hudState, action: recoveryActionTitle,
                                     signalMissing: recordingSignalMissing, modeLabel: modeCueLabel,
                                     isCopyConfirmation: isCopyConfirmation, screenWidth: hudWindow?.availableWidth ?? 1440)
        resizeTask?.cancel()
        if let window = hudWindow {
            window.resize(to: NSSize(width: max(window.frame.width, next.panelSize.width),
                                     height: max(window.frame.height, next.panelSize.height)))
        }
        presentation = next
        resizeTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard let self else { return }
            self.hudWindow?.resize(to: self.presentation.panelSize)
        }
        updateMouseInteraction()
    }

    /// 录音态需要响应鼠标（X/✓ 按钮），其他态不拦截鼠标事件
    private func updateMouseInteraction() {
        let hasRecoveryAction: Bool
        if case .failure = hudState { hasRecoveryAction = recoveryActionTitle != nil }
        else { hasRecoveryAction = false }
        hudWindow?.setInteractionRegion(hudState == .recording || hasRecoveryAction ? presentation.capsuleSize : nil)
    }

    private func ensureWindow() {
        guard hudWindow == nil else { return }

        let contentView = HUDContentView(
            controller: self,
            onCancel: { [weak self] in self?.onCancelRecording?() },
            onConfirm: { [weak self] in self?.onConfirmRecording?() }
        )
        let hosting = NSHostingView(rootView: contentView)
        hosting.frame = NSRect(origin: .zero, size: presentation.panelSize)
        hosting.sizingOptions = []

        hostingView = hosting
        hudWindow = HUDWindow(contentView: hosting)
        hudWindow?.onScreenChanged = { [weak self] in self?.refreshLayout() }
        hudWindow?.onInteractionHover = { [weak self] inside in
            guard let self else { return }
            self.setRecoveryHover(inside, generation: self.presentationGeneration)
        }
    }

}

/// Monotonic countdown with independent hover/focus ownership in the controller.
struct HUDDismissCountdown {
    private(set) var remaining: Double?
    private var deadline: Double?

    init(remaining: Double? = nil) { self.remaining = remaining }

    mutating func pause(at now: Double) {
        if let deadline { remaining = max(0, deadline - now) }
        deadline = nil
    }

    mutating func resume(at now: Double) -> Double? {
        guard let remaining else { return nil }
        if let deadline { return max(0, deadline - now) }
        deadline = now + remaining
        return remaining
    }
}
