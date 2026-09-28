import SwiftUI

struct MicrophoneLevelView: View {
    let appCoordinator: AppCoordinator

    private var meter: MicrophoneLevelController { appCoordinator.microphoneLevelController }
    private var devices: AudioDeviceManager { appCoordinator.audioDeviceManager }
    private var busy: Bool { appCoordinator.sessionCoordinator.state.isProcessing }
    private var shouldMonitor: Bool {
        appCoordinator.isSettingsWindowVisible && appCoordinator.selectedSettingsTab == .asr && !busy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsFormLayout.rowVerticalSpacing) {
            SettingsFormRow(title: "麦克风") {
                Picker("麦克风", selection: Binding(get: { devices.menuSelectionID }, set: {
                    devices.selectMenuItem(id: $0)
                })) {
                    Text("自动选择（推荐）").tag(AudioInputConfig.automaticSelectionID)
                    Text(devices.systemDefaultMenuItemTitle).tag(AudioDeviceManager.systemDefaultSelectionID)
                    ForEach(devices.devices) { device in Text(device.name).tag(device.id) }
                }
                .labelsHidden()
                .disabled(busy)
            }
            SettingsFormRow(title: "输入电平") {
                MicrophoneLevelIndicator(level: Double(meter.level))
                    .frame(height: 18)
                    .opacity(busy ? 0.5 : 1)
            }
            if let message = meter.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: SettingsFormLayout.footerWidth, alignment: .leading)
                    .padding(.leading, SettingsFormLayout.labelWidth + SettingsFormLayout.rowSpacing)
            }
        }
        .onAppear {
            devices.refreshDevices()
            updateMonitoring()
        }
        .onDisappear { meter.stop() }
        .onChange(of: shouldMonitor) { _, _ in updateMonitoring() }
        .onChange(of: devices.menuSelectionID) { _, _ in
            meter.stop()
            updateMonitoring()
        }
        .onChange(of: appCoordinator.permissionsManager.microphoneStatus) { _, _ in updateMonitoring() }
    }

    private func updateMonitoring() {
        if shouldMonitor {
            meter.start(device: devices.captureDeviceForRecording()) {
                try appCoordinator.permissionsManager.ensureMicrophoneAuthorized()
            }
        } else {
            meter.stop()
        }
    }
}

private struct MicrophoneLevelIndicator: View {
    let level: Double
    private let segmentCount = 15

    private var normalizedLevel: Double {
        level.isFinite ? min(max(level, 0), 1) : 0
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<segmentCount, id: \.self) { index in
                Capsule()
                    .fill(.primary.opacity(index < Int((normalizedLevel * Double(segmentCount)).rounded()) ? 0.85 : 0.10))
                    .overlay {
                        Capsule().strokeBorder(.primary.opacity(0.06), lineWidth: 0.5)
                    }
                    .frame(width: 7, height: 15)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("麦克风输入电平")
        .accessibilityValue("\(Int(normalizedLevel * 100))%")
    }
}
