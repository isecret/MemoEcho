import SwiftUI

struct MenuBarView: View {
    let appCoordinator: AppCoordinator
    @Environment(\.openWindow) private var openWindow

    private var state: SessionState {
        appCoordinator.sessionCoordinator.state
    }

    var body: some View {
        if state.isCancellable {
            Button("取消当前任务") { appCoordinator.sessionCoordinator.cancel() }
            Divider()
        } else if !state.isProcessing, let recovery = appCoordinator.recoveryPresentation {
            Menu("恢复上次输入") {
                Text(recovery.reason)
                Divider()
                if recovery.settingsTab != nil, appCoordinator.configStore.canOpenSettings {
                    Button("检查设置…") { appCoordinator.openFailedSessionSettings(expectedID: recovery.id) }
                }
                if let title = recovery.retryTitle {
                    Button(title) { appCoordinator.retryFailedSession(expectedID: recovery.id) }
                }
                if recovery.canCopy {
                    Button("复制结果") { appCoordinator.copyLastFailureTextToClipboard(expectedID: recovery.id) }
                }
                if recovery.outputAttempted { Text("请先检查原输入框，避免重复粘贴") }
                Button("查看原因…") { appCoordinator.showRecoveryReason(id: recovery.id) }
                Divider()
                Button("丢弃本次结果") { appCoordinator.discardFailedSession(id: recovery.id) }
                Text("临时保留，退出后清除")
            }
            Divider()
        } else if let tab = appCoordinator.menuSettingsBlocker {
            Button("检查设置…") {
                guard appCoordinator.menuSettingsBlocker == tab else { return }
                appCoordinator.openSettingsWindow(tab: tab)
            }
            Divider()
        }

        microphonePicker

        Divider()

        if appCoordinator.configStore.canOpenSettings {
            Button("设置…") {
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
