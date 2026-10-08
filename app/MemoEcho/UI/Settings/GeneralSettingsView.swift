import AppKit
import SwiftUI

struct GeneralSettingsView: View {
    private enum Layout {
        static let translationPickerWidth: CGFloat = 160
    }

    let configStore: ConfigStore
    let updateService: AppUpdateService
    var onHotkeyCommit: ((HotkeyCombo) -> String?)?
    var onHotkeyRecordingChanged: ((Bool) -> Void)?
    var canEditHotkey = true

    @State private var hotkey: HotkeyCombo = .default
    @State private var interactionSoundEnabled = true
    @State private var translationTargetLanguage: TranslationTargetLanguage = .english
    @State private var launchAtLogin = false
    @State private var isLoaded = false
    @State private var recordingPhase: HotkeyRecordingPhase = .idle
    @State private var hotkeyError: String?
    @State private var contextSaveError: String?
    @State private var launchAtLoginError: String?

    var body: some View {
        Group {
            SettingsFormGroup(title: "录音操作") {
                SettingsPaneSection {
                    SettingsFormRow(title: "录音快捷键") {
                        VStack(alignment: .leading, spacing: 8) {
                            HotkeyRecorderView(
                                hotkey: hotkey, onCommit: commitHotkey,
                                onPhaseChanged: { recordingPhase = $0 },
                                onRecordingStateChanged: { isRecording in
                                    if isRecording { hotkeyError = nil }
                                    onHotkeyRecordingChanged?(isRecording)
                                },
                                isEnabled: canEditHotkey
                            )
                        }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(recordingPhase == .idle ? "在任意应用中使用此快捷键录音。" : "按一次快捷键即可，Esc 取消。")
                        if let hotkeyError { Text(hotkeyError).foregroundStyle(.red) }
                    }
                }

                SettingsPaneSection {
                    SettingsFormRow(title: "按键方式") {
                        HotkeyTriggerModePicker(hotkey: hotkey, onCommit: commitHotkey,
                                                isEnabled: canEditHotkey && recordingPhase == .idle,
                                                alignment: .leading)
                            .help(systemShortcutHint)
                    }
                } footer: {
                    Text(hotkey.triggerMode.instruction)
                }

                SettingsPaneSection {
                    SettingsFormRow(title: "交互音效") {
                        Toggle("启用", isOn: $interactionSoundEnabled)
                            .labelsHidden()
                    }
                } footer: {
                    Text("开始和结束录音时播放提示音。")
                }
            }

            SettingsFormGroup(title: "文字处理") {
                SettingsPaneSection {
                    SettingsFormRow(title: "参考窗口上下文") {
                        Toggle("参考窗口上下文", isOn: Binding(
                            get: { configStore.windowContextEnabled },
                            set: { enabled in
                                do {
                                    try configStore.saveWindowContextEnabled(enabled)
                                    contextSaveError = nil
                                } catch {
                                    contextSaveError = "保存失败，请重试"
                                }
                            }
                        ))
                        .labelsHidden()
                        .accessibilityLabel("参考窗口上下文")
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("将当前窗口内容发给 AI，帮助理解你说的话。")
                        if let contextSaveError {
                            Text(contextSaveError).foregroundStyle(.red)
                        }
                    }
                }

                SettingsPaneSection {
                    SettingsFormRow(title: "翻译目标语言") {
                        HStack(spacing: 0) {
                            Picker("", selection: $translationTargetLanguage) {
                                ForEach(TranslationTargetLanguage.allCases, id: \.self) { lang in
                                    Text(lang.displayName).tag(lang)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: Layout.translationPickerWidth, alignment: .leading)

                            Spacer(minLength: 0)
                        }
                    }
                } footer: {
                    Text("录音时按 Shift+Tab 可切换到翻译模式，译文将使用这里选择的语言。")
                }
            }

            SettingsFormGroup(title: "启动与更新") {
                SettingsPaneSection {
                    SettingsFormRow(title: "开机自启动") {
                        Toggle("在登录时启动", isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
                            .labelsHidden()
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("登录 macOS 后自动启动。")
                        if let launchAtLoginError {
                            Text(launchAtLoginError).foregroundStyle(.red)
                        }
                    }
                }

                if updateService.isAvailable {
                    SettingsPaneSection {
                        SettingsFormRow(title: "自动检查更新") {
                            HStack(spacing: 14) {
                                Toggle(
                                    "",
                                    isOn: Binding(
                                        get: { updateService.automaticallyChecksForUpdates },
                                        set: { updateService.setAutomaticallyChecksForUpdates($0) }
                                    )
                                )
                                .toggleStyle(.checkbox)
                                .labelsHidden()

                                Button("检查更新") {
                                    updateService.checkForUpdates()
                                }
                                .disabled(!updateService.canCheckForUpdates)
                            }
                        }
                    } footer: {
                        Text("当前版本：v\(appVersion)")
                    }
                }
            }


        }
        .onAppear {
            loadDraft()
            isLoaded = true
        }
        .onChange(of: configStore.generalConfig.hotkey) { hotkey = configStore.generalConfig.hotkey }
        .onChange(of: interactionSoundEnabled) { immediateSaveInteractionSound() }
        .onChange(of: translationTargetLanguage) { immediateSaveGeneralConfig() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin = LaunchAtLoginManager.isEnabled
            if launchAtLogin { launchAtLoginError = nil }
        }
    }

    private var systemShortcutHint: String {
        var hints = [hotkey.triggerMode.instruction]
        if let warning = HotkeySystemConflict.warning(for: hotkey) { hints.append(warning) }
        if hotkey.specialModifiers.contains(where: { $0.key == .function }) {
            hints.append(HotkeySystemConflict.functionKeyInstruction(for: hotkey))
        }
        return hints.joined(separator: "\n")
    }

    @discardableResult
    private func commitHotkey(_ combo: HotkeyCombo) -> Bool {
        if let errorMessage = HotkeyAssignmentPolicy.error(for: combo) ?? onHotkeyCommit?(combo) {
            hotkeyError = errorMessage
            return false
        }
        hotkey = combo
        hotkeyError = nil
        return true
    }

    private func loadDraft() {
        hotkey = configStore.generalConfig.hotkey
        interactionSoundEnabled = configStore.generalConfig.interactionSoundEnabled
        translationTargetLanguage = configStore.generalConfig.translationTargetLanguage
        launchAtLogin = LaunchAtLoginManager.isEnabled
    }

    private func immediateSaveInteractionSound() {
        guard isLoaded else { return }
        immediateSaveGeneralConfig()
    }

    private func immediateSaveGeneralConfig() {
        guard isLoaded else { return }
        let config = GeneralConfig(
            hotkey: configStore.generalConfig.hotkey,
            interactionSoundEnabled: interactionSoundEnabled,
            translationTargetLanguage: translationTargetLanguage,
            windowContextEnabled: configStore.windowContextEnabled
        )
        try? configStore.saveGeneralConfig(config)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLoginManager.setEnabled(enabled)
            launchAtLogin = LaunchAtLoginManager.isEnabled
            launchAtLoginError = enabled && !launchAtLogin ? "请在系统设置中确认登录项。" : nil
        } catch {
            launchAtLogin = LaunchAtLoginManager.isEnabled
            launchAtLoginError = "登录项设置失败，请重试。"
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
}
