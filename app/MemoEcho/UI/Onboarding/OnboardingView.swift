import AppKit
import SwiftUI

/// Visual setup and recovery share the same steps and the same live readiness state.
struct OnboardingView: View {
    let coordinator: OnboardingCoordinator

    @State private var configurationSheet: ConfigurationSheet?
    @FocusState private var trialEditorFocused: Bool

    private enum ConfigurationSheet: String, Identifiable {
        case asr, llm
        var id: String { rawValue }
    }

    private var isLocalASR: Bool {
        coordinator.configStore.asrConfig.selectedPlatform == .localSenseVoice
    }

    private var hotkey: HotkeyCombo { coordinator.configStore.generalConfig.hotkey }

    private var shouldFocusTrialEditor: Bool {
        coordinator.isPresented && coordinator.step == .tryIt
            && coordinator.readiness.isReady && configurationSheet == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            visual
                .frame(maxWidth: .infinity)
                .frame(height: 390)
                .padding(.top, 10)

            copyRegion

            navigation
                .frame(width: 640)
                .padding(.bottom, 40)
        }
        .frame(width: 760, height: 660)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $configurationSheet, onDismiss: coordinator.refresh) { sheet in
            configurationView(sheet)
        }
        .onChange(of: coordinator.modelDownloadManager.isDownloading) { coordinator.refresh() }
        .task(id: shouldFocusTrialEditor) {
            trialEditorFocused = false
            guard shouldFocusTrialEditor else { return }
            // Let the newly inserted editor join the window's responder chain first.
            await Task.yield()
            guard !Task.isCancelled, shouldFocusTrialEditor else { return }
            trialEditorFocused = true
        }
    }

    private var copyRegion: some View {
        ViewThatFits(in: .vertical) {
            copyContent
            // Keep recovery actions reachable without moving the demo or navigation.
            ScrollView {
                copyContent.frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 12)
    }

    private var copyContent: some View {
        VStack(spacing: 18) {
            pageHeading
            if showsFeedback {
                feedbackControls
                    .frame(maxWidth: .infinity, alignment: coordinator.step == .tryIt ? .leading : .center)
            }
        }
        .frame(width: 550)
        .fixedSize(horizontal: false, vertical: true)
    }

    // Do not reserve an invisible feedback row on pages with no status or actions.
    private var showsFeedback: Bool {
        if coordinator.step != .tryIt, coordinator.lastErrorMessage != nil { return true }
        switch coordinator.step {
        case .welcome:
            return false
        case .asr, .llm:
            return true
        case .permissions:
            return coordinator.permissionsManager.microphoneStatus == .restricted
        case .hotkey:
            return !coordinator.canContinue
                || hotkey.specialModifiers.contains { $0.key == .function }
                || HotkeySystemConflict.warning(for: hotkey) != nil
        case .tryIt:
            return !coordinator.readiness.isReady
        }
    }

    private var pageHeading: some View {
        VStack(spacing: 8) {
            Text(pageTitle)
                .font(.system(size: 28, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            if !pageSubtitle.isEmpty {
                Text(pageSubtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var feedbackControls: some View {
        VStack(alignment: coordinator.step == .tryIt ? .leading : .center, spacing: 8) {
            stepControls
            if coordinator.step != .hotkey, coordinator.step != .tryIt,
               let error = coordinator.lastErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .multilineTextAlignment(coordinator.step == .tryIt ? .leading : .center)
    }

    private var pageTitle: String {
        if coordinator.step == .tryIt, !coordinator.readiness.isReady {
            return "还有设置没完成"
        }
        return coordinator.step.title
    }

    private var pageSubtitle: String {
        if coordinator.step == .tryIt, !coordinator.readiness.isReady {
            return "先完成下面的设置，再试着说一句。"
        }
        return coordinator.step.subtitle
    }

    @ViewBuilder
    private var visual: some View {
        switch coordinator.step {
        case .welcome:
            welcomeVisual
        case .asr:
            recognitionVisual
        case .llm:
            modelVisual
        case .permissions:
            permissionVisual
        case .hotkey:
            hotkeyVisual
        case .tryIt:
            tryItVisual
        }
    }

    private var welcomeVisual: some View {
        OnboardingDemoStage(background: .welcome, alignment: .top) {
            OnboardingWelcomeDemo(isActive: coordinator.isPresented)
        }
    }

    private var recognitionVisual: some View {
        HStack(spacing: 20) {
            recognitionCard(
                title: "本地识别",
                subtitle: "SenseVoice · 下载模型后离线识别",
                symbol: "laptopcomputer",
                selected: isLocalASR
            ) {
                coordinator.selectASRPlatform(.localSenseVoice)
            }

            recognitionCard(
                title: "云端识别",
                subtitle: "连接云端语音服务",
                symbol: "cloud",
                selected: !isLocalASR
            ) {
                if isLocalASR {
                    coordinator.selectASRPlatform(.tencentCloudSentence)
                }
            }
        }
        .padding(.horizontal, 60)
    }

    private func recognitionCard(
        title: String, subtitle: String, symbol: String, selected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 18) {
                HStack {
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.35))
                        .font(.system(size: 19))
                }
                Image(systemName: symbol)
                    .font(.system(size: 61, weight: .light))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(height: 70)
                VStack(spacing: 6) {
                    Text(title).font(.system(size: 18, weight: .semibold))
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(22)
            .frame(maxWidth: .infinity)
            .frame(height: 278)
            .background(cardBackground)
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.5), lineWidth: selected ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)，\(subtitle)")
        .accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var modelVisual: some View {
        // Product-approved fixed example; opening this page never requests a model.
        OnboardingDemoStage(background: .model) {
            modelComparison
        }
    }

    private var modelComparison: some View {
        VStack(spacing: 16) {
            textComparisonCard(
                label: "原始转写", text: OnboardingDemoCopy.highlightedOriginalText, symbol: "waveform", emphasized: false
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(OnboardingDemoCopy.originalAccessibilityLabel)
            Image(systemName: "arrow.down")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
            textComparisonCard(
                label: "润色结果", text: OnboardingDemoCopy.highlightedReply, symbol: "sparkles", emphasized: true
            )
        }
        .frame(width: 540)
        .accessibilityElement(children: .combine)
    }

    private func textComparisonCard(label: String, text: AttributedString, symbol: String, emphasized: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(label, systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(emphasized ? Color.accentColor : .secondary)
            Text(text)
                .font(.system(size: 16, weight: emphasized ? .medium : .regular))
                .foregroundStyle(emphasized ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(cardBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(emphasized ? Color.accentColor.opacity(0.4) : Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
        }
    }

    private var permissionVisual: some View {
        HStack(spacing: 20) {
            permissionCard(
                title: PermissionCopy.microphoneTitle, purpose: "录制你的声音", symbol: "mic",
                statusText: PermissionCopy.microphoneStatus(coordinator.permissionsManager.microphoneStatus),
                granted: coordinator.permissionsManager.microphoneStatus == .granted
            )
            permissionCard(
                title: PermissionCopy.accessibilityTitle, purpose: "把文字填入当前应用", symbol: "accessibility",
                statusText: PermissionCopy.accessibilityStatus(coordinator.permissionsManager.accessibilityStatus),
                granted: coordinator.permissionsManager.accessibilityStatus == .granted
            )
        }
        .padding(.horizontal, 60)
    }

    private func permissionCard(title: String, purpose: String, symbol: String, statusText: String, granted: Bool) -> some View {
        VStack(spacing: 17) {
            Image(systemName: symbol)
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(granted ? Color.accentColor : Color.secondary)
                .frame(height: 78)
            VStack(spacing: 7) {
                Text(title).font(.system(size: 18, weight: .semibold))
                Text(purpose).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Label(statusText, systemImage: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(granted ? Color.green : Color.secondary)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 270)
        .background(cardBackground)
        .accessibilityElement(children: .combine)
    }

    private var hotkeyVisual: some View {
        OnboardingDemoStage(background: .hotkey) {
            HotkeyRecorderView(
                hotkey: hotkey,
                onCommit: coordinator.applyHotkey,
                onRecordingStateChanged: coordinator.setHotkeyCaptureSuspended,
                usesProminentKeycaps: true
            )
        }
    }

    private var tryItVisual: some View {
        OnboardingDemoStage(background: .trial) {
            trialPanel
        }
    }

    private var trialPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(get: { coordinator.trialText }, set: { coordinator.trialText = $0 }))
                    .font(.system(size: 17))
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .padding(16)
                    .focused($trialEditorFocused)
                    .disabled(!coordinator.readiness.isReady)
                    .accessibilityLabel("语音试用文本框")
                    .accessibilityHint("按下快捷键 \(HotkeyPresentation(combo: hotkey).accessibilityDescription)，开始说话，再按一次结束。文字会填在这里。")
                if coordinator.trialText.isEmpty {
                    Text("按下快捷键 \(HotkeyPresentation(combo: hotkey).compactDescription)，开始说话…")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 21)
                        .padding(.vertical, 17)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 140)
            .background(Color(nsColor: .textBackgroundColor))
            Divider()
            Text("试着说：先做个原型吧，看看用起来怎么样。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(width: 550)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(trialEditorFocused ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }

    @ViewBuilder
    private var stepControls: some View {
        switch coordinator.step {
        case .welcome:
            EmptyView()
        case .asr:
            if isLocalASR, coordinator.modelDownloadManager.isDownloading {
                OnboardingDownloadProgress(progress: coordinator.modelDownloadManager.progress)
            } else if coordinator.readiness.asr.isReady {
                OnboardingConfigurationSummary(
                    changeLabel: "更改云端配置…",
                    onChange: isLocalASR ? nil : { configurationSheet = .asr }
                )
            } else {
                HStack(spacing: 12) {
                    readinessLabel(coordinator.readiness.asr)
                    if !isLocalASR, coordinator.cloudASRValidationService.status == .failed {
                        Button("重新验证", action: coordinator.retryCurrentValidation)
                            .buttonStyle(.link).fixedSize()
                    }
                }
            }
        case .llm:
            if coordinator.readiness.llm.isReady {
                OnboardingConfigurationSummary(
                    changeLabel: "更改模型配置…",
                    onChange: { configurationSheet = .llm }
                )
            } else {
                HStack(spacing: 12) {
                    readinessLabel(coordinator.readiness.llm)
                    if coordinator.llmValidationService.status == .failed {
                        Button("重新验证", action: coordinator.retryCurrentValidation)
                            .buttonStyle(.link).fixedSize()
                    }
                }
            }
        case .permissions:
            if coordinator.permissionsManager.microphoneStatus == .restricted {
                Text(PermissionCopy.microphoneRestriction)
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .hotkey:
            VStack(spacing: 8) {
                if let error = coordinator.lastErrorMessage {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                } else if !coordinator.canContinue {
                    readinessLabel(coordinator.readiness.hotkey)
                } else if hotkey.specialModifiers.contains(where: { $0.key == .function }) {
                    HStack(spacing: 6) {
                        Text("将系统“按下 🌐 键时”设为“无操作”。")
                        Button("键盘设置…", action: openKeyboardSettings).buttonStyle(.link)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                } else if let conflict = HotkeySystemConflict.warning(for: hotkey) {
                    Text(conflict).font(.caption).foregroundStyle(.secondary)
                }
            }
        case .tryIt:
            if !coordinator.readiness.isReady {
                VStack(alignment: .leading, spacing: 6) {
                    recoveryButton("语音识别", status: coordinator.readiness.asr, step: .asr)
                    recoveryButton("AI 模型", status: coordinator.readiness.llm, step: .llm)
                    recoveryButton(PermissionCopy.microphoneTitle, status: coordinator.readiness.microphone, step: .permissions)
                    recoveryButton(PermissionCopy.accessibilityTitle, status: coordinator.readiness.accessibility, step: .permissions)
                    recoveryButton("快捷键", status: coordinator.readiness.hotkey, step: .hotkey)
                }
            }
        }
    }

    @ViewBuilder
    private func readinessLabel(_ status: ReadinessStatus) -> some View {
        switch status {
        case .ready:
            Label("已就绪", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.system(size: 12))
        case .pending(let reason):
            Text(reason).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
        case .blocked(let reason):
            Text(reason).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    @ViewBuilder
    private func recoveryButton(_ title: String, status: ReadinessStatus, step: SetupStep) -> some View {
        if !isReady(status) {
            Button {
                coordinator.openRecoverySettings(for: step)
            } label: {
                HStack(spacing: 6) {
                    Text(title)
                    readinessLabel(status)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
            }
            .buttonStyle(.link)
            .font(.system(size: 12))
        }
    }

    private var navigation: some View {
        HStack(spacing: 14) {
            if let number = coordinator.step.number {
                Text("\(number) / 5")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("第 \(number) 步，共 5 步")
            }
            Spacer()
            if coordinator.canGoBack {
                Button("上一步", action: coordinator.goBack)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(coordinator.permissionsManager.isHandlingAuthorization)
            }
            Button(primaryTitle, action: performPrimaryAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(primaryDisabled)
        }
        .frame(height: 38)
    }

    private var primaryTitle: String {
        if coordinator.step == .tryIt, !coordinator.readiness.isReady { return "打开设置" }
        guard !coordinator.canContinue else { return coordinator.primaryActionTitle }
        switch coordinator.step {
        case .asr:
            if isLocalASR, coordinator.modelDownloadManager.isDownloading { return "正在下载…" }
            if isLocalASR {
                return coordinator.modelDownloadManager.lastError == nil ? "下载识别模型" : "重新下载"
            }
            return coordinator.cloudASRValidationService.status == .checking ? "正在验证…" : "配置云端服务…"
        case .llm:
            return coordinator.llmValidationService.status == .checking ? "正在验证…" : "配置 AI 模型…"
        case .permissions:
            let permissions = coordinator.permissionsManager
            if permissions.microphoneStatus != .granted {
                return PermissionCopy.microphoneAction(
                    permissions.microphoneStatus, isRequesting: permissions.isRequestingMicrophonePermission
                ) ?? coordinator.primaryActionTitle
            }
            return PermissionCopy.accessibilityAction(permissions.accessibilityStatus) ?? coordinator.primaryActionTitle
        case .tryIt:
            return coordinator.trialPhase.isActive ? coordinator.primaryActionTitle : "继续设置"
        default:
            return coordinator.primaryActionTitle
        }
    }

    private var primaryDisabled: Bool {
        if coordinator.permissionsManager.isHandlingAuthorization { return true }
        if coordinator.trialPhase.isActive { return true }
        switch coordinator.step {
        case .asr:
            return (isLocalASR && coordinator.modelDownloadManager.isDownloading)
                || (!isLocalASR && coordinator.cloudASRValidationService.status == .checking)
        case .llm:
            return coordinator.llmValidationService.status == .checking
        case .permissions:
            return coordinator.permissionsManager.microphoneStatus == .restricted
        case .hotkey:
            return !coordinator.canContinue
        default:
            return false
        }
    }

    private func performPrimaryAction() {
        if coordinator.step == .tryIt, !coordinator.readiness.isReady {
            coordinator.openRecoverySettings(for: coordinator.readiness.nextRequiredStep ?? .hotkey)
            return
        }
        if coordinator.canContinue {
            coordinator.goForward()
            return
        }
        switch coordinator.step {
        case .asr:
            if isLocalASR {
                coordinator.startModelDownload()
            } else {
                configurationSheet = .asr
            }
        case .llm:
            configurationSheet = .llm
        case .permissions:
            coordinator.requestNextPermission()
        case .tryIt:
            break
        default:
            coordinator.goForward()
        }
    }

    private func configurationView(_ sheet: ConfigurationSheet) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(sheet == .asr ? "配置语音识别" : "连接 AI 模型")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(spacing: 16) {
                    switch sheet {
                    case .asr:
                        ASRSettingsView(
                            configStore: coordinator.configStore,
                            downloadManager: coordinator.modelDownloadManager,
                            validationService: coordinator.cloudASRValidationService
                        )
                    case .llm:
                        LLMSettingsView(
                            configStore: coordinator.configStore,
                            modelListService: coordinator.llmModelListService,
                            validationService: coordinator.llmValidationService
                        )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
            }
            Divider()
            HStack {
                Spacer()
                Button("完成") { configurationSheet = nil }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 576, height: sheet == .asr ? 460 : 400)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .shadow(color: .black.opacity(0.035), radius: 12, y: 5)
    }

    private func isReady(_ status: ReadinessStatus) -> Bool {
        if case .ready = status { return true }
        return false
    }

    private func openKeyboardSettings() {
        for address in [
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.keyboard",
        ] {
            if let url = URL(string: address), NSWorkspace.shared.open(url) { return }
        }
    }
}

struct OnboardingDownloadProgress: View {
    let progress: Double

    var body: some View {
        VStack(spacing: 6) {
            ProgressView(value: progress)
            Text("正在下载 \(Int(progress * 100))%，完成后继续")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 220)
        .accessibilityElement(children: .combine)
    }
}

/// A compact ready-status row shared by ASR and model setup, without configuration details.
struct OnboardingConfigurationSummary: View {
    var changeLabel = "更改配置…"
    var onChange: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Label("已就绪", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .fixedSize()
            if let onChange {
                Button("更改…", action: onChange)
                    .buttonStyle(.link)
                    .fixedSize()
                    .accessibilityLabel(changeLabel)
            }
        }
        .font(.system(size: 12))
    }
}

enum OnboardingDemoBackground: String, CaseIterable {
    case welcome = "OnboardingDemoBackground"
    case model = "OnboardingModelBackground"
    case hotkey = "OnboardingHotkeyBackground"
    case trial = "OnboardingTrialBackground"
}

/// Only the static backdrop ignores input; the recorder and trial editor remain interactive.
struct OnboardingDemoStage<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    private let background: OnboardingDemoBackground
    private let alignment: Alignment
    private let content: Content

    init(background: OnboardingDemoBackground, alignment: Alignment = .center, @ViewBuilder content: () -> Content) {
        self.background = background
        self.alignment = alignment
        self.content = content()
    }

    var body: some View {
        content
            .frame(width: 640, height: 366, alignment: alignment)
            .background {
                Image(background.rawValue)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 640, height: 366)
                    .overlay(Color.black.opacity(colorScheme == .dark ? 0.72 : 0))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
