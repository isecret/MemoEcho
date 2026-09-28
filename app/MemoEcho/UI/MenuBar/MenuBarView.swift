import SwiftUI

struct MenuBarView: View {
    let appCoordinator: AppCoordinator
    @Environment(\.openWindow) private var openWindow
    @State private var learningUndoError: String?

    private var state: SessionState {
        appCoordinator.sessionCoordinator.state
    }

    private var lastInjectionFailureText: String? {
        appCoordinator.sessionCoordinator.lastInjectionFailureText
    }

    var body: some View {
        if let error = appCoordinator.sessionCoordinator.currentError {
            Label(error.userMessage, systemImage: "exclamationmark.triangle.fill")
                .imageScale(.small)
                .foregroundStyle(.secondary)

            Divider()
        }

        if let warning = appCoordinator.sessionCoordinator.recordingWarning {
            Label(warning, systemImage: "mic.slash")
            Divider()
        }
        if let failureText = lastInjectionFailureText {
            let preview = failureText.count > 20
                ? String(failureText.prefix(20)) + "…"
                : failureText
            Button(preview) {
                appCoordinator.copyLastFailureTextToClipboard()
            }

            Divider()
        }

        if let recovery = appCoordinator.sessionCoordinator.recovery {
            if recovery.canRetry {
                Button(appCoordinator.sessionCoordinator.recoveryActionTitle ?? recovery.stage.retryTitle) { appCoordinator.retryFailedSession() }
                    .disabled(!appCoordinator.sessionCoordinator.canRetryRecovery)
            }
            if recovery.outputAttempted {
                Text("请先检查原输入框，避免重复粘贴")
            }
            if !recovery.outputUnverified {
                Button("检查设置") { appCoordinator.openFailedSessionSettings() }
                    .disabled(state.isProcessing)
            }
            Button("丢弃上次结果") { appCoordinator.sessionCoordinator.discardRecovery() }
                .disabled(state.isProcessing && !appCoordinator.sessionCoordinator.isRecovering)
            Text("仅临时保留 10 分钟，退出后清除")
                .font(.caption)
            Divider()
        }

        if state.isCancellable {
            Button("取消当前任务") {
                appCoordinator.sessionCoordinator.cancel()
            }
            Divider()
        }

        if let entry = appCoordinator.dictionaryStore.latestLearnedEntry {
            Button("撤销学习「\(entry.term)」") {
                do {
                    try appCoordinator.dictionaryStore.removeEntry(id: entry.id)
                    learningUndoError = nil
                } catch { learningUndoError = "撤销失败，请在词典设置中重试" }
            }
            Divider()
        }
        if let learningUndoError { Text(learningUndoError) }

        microphonePicker

        Divider()

        if appCoordinator.configStore.canOpenSettings {
            Button("设置") {
                appCoordinator.openSettingsWindow()
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        Button("关于 MemoEcho") {
            openWindow(id: "about")
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        Button("退出") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    private var microphonePicker: some View {
        Group {
            if appCoordinator.audioDeviceManager.hasAvailableInputDevice {
                Picker("麦克风", selection: Binding(
                    get: {
                        appCoordinator.audioDeviceManager.menuSelectionID
                    },
                    set: { id in
                        appCoordinator.audioDeviceManager.selectMenuItem(id: id)
                    }
                )) {
                    Text("自动选择（推荐）")
                        .tag(AudioInputConfig.automaticSelectionID)
                    Text(appCoordinator.audioDeviceManager.systemDefaultMenuItemTitle)
                        .tag(AudioDeviceManager.systemDefaultSelectionID)

                    ForEach(appCoordinator.audioDeviceManager.devices) { device in
                        Text(device.name)
                            .tag(device.id)
                    }
                }
            } else {
                Menu("麦克风") {
                    Button(AudioDeviceManager.noInputDeviceDisplayName) {}
                        .disabled(true)
                }
            }
        }
        .disabled(state.isProcessing)
        .onAppear {
            appCoordinator.audioDeviceManager.refreshDevices()
        }
    }
}
