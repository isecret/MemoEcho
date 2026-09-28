import AVFoundation
import CoreAudio
import Foundation
import IOKit

@MainActor
@Observable
final class AudioDeviceManager {
    private(set) var devices: [AudioInputDevice] = []

    private let configStore: ConfigStore
    private var notificationObservers: [NSObjectProtocol] = []
    private var hardwareDevices: [HardwareAudioDevice] = []
    private var hardwareObserver: AudioHardwareObserver?

    init(configStore: ConfigStore) {
        self.configStore = configStore
        refreshDevices()
        observeDeviceChanges()
        hardwareObserver = AudioHardwareObserver { [weak self] in self?.refreshDevices() }
    }

    var selectedDeviceID: String? {
        configStore.audioInputConfig.selectedDeviceID
    }

    var selectedDeviceIsAvailable: Bool {
        if configStore.audioInputConfig.usesAutomaticSelection { return true }
        guard let selectedDeviceID else { return true }
        return devices.contains { $0.id == selectedDeviceID }
    }

    var activeDeviceIDForRecording: String? {
        if configStore.audioInputConfig.usesAutomaticSelection { return nil }
        guard let selectedDeviceID, selectedDeviceIsAvailable else { return nil }
        return selectedDeviceID
    }

    var menuSelectionID: String {
        if let selectedDeviceID, selectedDeviceIsAvailable {
            return selectedDeviceID
        }
        return Self.systemDefaultSelectionID
    }

    var systemDefaultDeviceDisplayName: String {
        guard let defaultDevice = AVCaptureDevice.default(for: .audio) else {
            return Self.systemDefaultDeviceDisplayName(
                defaultDeviceID: nil,
                defaultDeviceName: nil,
                availableDevices: devices
            )
        }

        return Self.systemDefaultDeviceDisplayName(
            defaultDeviceID: defaultDevice.uniqueID,
            defaultDeviceName: defaultDevice.localizedName,
            availableDevices: devices
        )
    }

    var systemDefaultMenuItemTitle: String {
        Self.systemDefaultMenuItemTitle(displayName: systemDefaultDeviceDisplayName)
    }

    var hasAvailableInputDevice: Bool {
        systemDefaultDeviceDisplayName != Self.noInputDeviceDisplayName
    }

    nonisolated static let systemDefaultSelectionID = "__memoecho_system_default__"
    nonisolated static let noInputDeviceDisplayName = "未找到可用麦克风"

    func refreshDevices() {
        hardwareDevices = HardwareAudioDevice.all()
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )

        devices = discoverySession.devices
            .filter { !Self.isSystemDefaultAggregateDevice($0) }
            .map { device in
                let hardware = hardwareDevices.first { $0.uid == device.uniqueID }
                return AudioInputDevice(id: device.uniqueID, name: device.localizedName,
                                        transport: hardware?.transport ?? .unknown,
                                        isUsable: hardware?.isUsableInput ?? true)
            }
            .sorted { lhs, rhs in
                lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }

        if !configStore.audioInputConfig.usesAutomaticSelection,
           let selectedDeviceID, !devices.contains(where: { $0.id == selectedDeviceID }) {
            selectSystemDefault()
        }
    }

    func selectMenuItem(id: String) {
        refreshDevices()

        if id == AudioInputConfig.automaticSelectionID {
            try? configStore.saveAudioInputConfig(.automatic)
            return
        }

        if id == Self.systemDefaultSelectionID {
            selectSystemDefault()
            return
        }

        guard let device = devices.first(where: { $0.id == id }) else {
            selectSystemDefault()
            return
        }

        selectDevice(device)
    }

    func selectSystemDefault() {
        try? configStore.saveAudioInputConfig(.systemDefault)
    }

    func selectDevice(_ device: AudioInputDevice) {
        let config = AudioInputConfig(
            selectedDeviceID: device.id
        )
        try? configStore.saveAudioInputConfig(config)
    }

    func captureDeviceForRecording() -> AVCaptureDevice? {
        refreshDevices()
        let defaultDevice = AVCaptureDevice.default(for: .audio)
        let defaultHardware = hardwareDevices.first { $0.id == HardwareAudioDevice.defaultInputID() }
        let output = HardwareAudioDevice.defaultOutputID()
        let outputTransport = hardwareDevices.first { $0.id == output }?.transport ?? .unknown
        let resolvedID = Self.resolveInputID(
            config: configStore.audioInputConfig, devices: devices,
            defaultInputID: defaultHardware?.uid ?? defaultDevice?.uniqueID, outputTransport: outputTransport,
            lidClosed: HardwareAudioDevice.isLidClosed()
        )
        if let resolvedID, let device = AVCaptureDevice(uniqueID: resolvedID) {
            return device
        }
        return defaultDevice
    }

    nonisolated static func resolveInputID(
        config: AudioInputConfig, devices: [AudioInputDevice], defaultInputID: String?,
        outputTransport: AudioDeviceTransport, lidClosed: Bool
    ) -> String? {
        if !config.usesAutomaticSelection {
            if let id = config.selectedDeviceID, devices.contains(where: { $0.id == id }) { return id }
            return defaultInputID
        }
        let defaultInput = devices.first { $0.id == defaultInputID }
        if outputTransport == .bluetooth, defaultInput?.transport == .bluetooth, !lidClosed,
           let builtIn = devices.first(where: { $0.transport == .builtIn && $0.isUsable }) {
            return builtIn.id
        }
        return defaultInputID
    }

    func startSoundDelayMilliseconds(for input: AVCaptureDevice?) -> Int {
        // Read again after capture starts, since opening Bluetooth input can change the route.
        let hardware = HardwareAudioDevice.all()
        let inputID = hardware.first { $0.uid == input?.uniqueID }?.id
            ?? (Self.isSystemDefaultAggregateDeviceID(input?.uniqueID, localizedName: input?.localizedName) ? HardwareAudioDevice.defaultInputID() : nil)
        let outputID = HardwareAudioDevice.defaultOutputID()
        let output = hardware.first { $0.id == outputID }
        return Self.startSoundDelayMilliseconds(inputID: inputID, outputID: outputID, outputName: output?.name)
    }

    nonisolated static func startSoundDelayMilliseconds(inputID: UInt32?, outputID: UInt32?, outputName: String?) -> Int {
        if let inputID, inputID != 0, inputID == outputID { return 1_200 }
        if outputName?.localizedCaseInsensitiveContains("airpods") == true { return 300 }
        return 0
    }

    private func observeDeviceChanges() {
        let connected = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDevices()
            }
        }

        let disconnected = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDevices()
            }
        }

        notificationObservers = [connected, disconnected]
    }

    nonisolated static func systemDefaultDeviceDisplayName(
        defaultDeviceID: String?,
        defaultDeviceName: String?,
        availableDevices: [AudioInputDevice]
    ) -> String {
        let trimmedName = defaultDeviceName?.trimmingCharacters(in: .whitespacesAndNewlines)

        if isSystemDefaultAggregateDeviceID(defaultDeviceID, localizedName: trimmedName) {
            return availableDevices.first?.name ?? noInputDeviceDisplayName
        }

        if let trimmedName, !trimmedName.isEmpty {
            return trimmedName
        }

        return availableDevices.first?.name ?? noInputDeviceDisplayName
    }

    nonisolated static func systemDefaultMenuItemTitle(displayName: String) -> String {
        if displayName == noInputDeviceDisplayName {
            return displayName
        }

        return "系统默认(\(displayName))"
    }

    nonisolated static func isSystemDefaultAggregateDeviceID(
        _ uniqueID: String?,
        localizedName: String?
    ) -> Bool {
        let prefixes = [
            "CADefaultDeviceAggregate-",
            "ICADefaultDeviceAggregate-",
        ]

        return prefixes.contains { prefix in
            uniqueID?.hasPrefix(prefix) == true
                || localizedName?.hasPrefix(prefix) == true
        }
    }

    private static func isSystemDefaultAggregateDevice(_ device: AVCaptureDevice) -> Bool {
        isSystemDefaultAggregateDeviceID(device.uniqueID, localizedName: device.localizedName)
    }
}

private struct HardwareAudioDevice {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transport: AudioDeviceTransport
    let isUsableInput: Bool

    static func all() -> [Self] {
        ids(object: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDevices).compactMap { id in
            guard let uid = string(object: id, selector: kAudioDevicePropertyDeviceUID) else { return nil }
            let raw: UInt32 = scalar(object: id, selector: kAudioDevicePropertyTransportType, initial: UInt32(0)) ?? 0
            let transport: AudioDeviceTransport
            switch raw {
            case kAudioDeviceTransportTypeBuiltIn: transport = .builtIn
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: transport = .bluetooth
            case 0, kAudioDeviceTransportTypeUnknown: transport = .unknown
            default: transport = .external
            }
            let alive = scalar(object: id, selector: kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0)) == 1
            let muted = scalar(object: id, selector: kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput, initial: UInt32(0))
            let volume = scalar(object: id, selector: kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeInput, initial: Float(0))
            let hasInput = !ids(object: id, selector: kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput).isEmpty
            return Self(id: id, uid: uid, name: string(object: id, selector: kAudioObjectPropertyName) ?? "",
                        transport: transport, isUsableInput: hasInput && alive && muted != 1 && (volume == nil || volume! > 0))
        }
    }

    static func defaultOutputID() -> AudioObjectID? {
        let id = scalar(object: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0))
        return id == 0 ? nil : id
    }

    static func defaultInputID() -> AudioObjectID? {
        let id = scalar(object: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultInputDevice, initial: AudioObjectID(0))
        return id == 0 ? nil : id
    }

    static func isLidClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool ?? false
    }

    private static func scalar<T>(object: AudioObjectID, selector: AudioObjectPropertySelector,
                                  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &value) { bytes in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, bytes.baseAddress!)
        }
        return status == noErr ? value : nil
    }

    private static func string(object: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: value))
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func ids(object: AudioObjectID, selector: AudioObjectPropertySelector,
                            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = values.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, bytes.baseAddress!)
        }
        return status == noErr ? Array(values.prefix(Int(size) / MemoryLayout<AudioObjectID>.size)) : []
    }
}

private final class AudioHardwareObserver {
    private let listener: AudioObjectPropertyListenerBlock
    private let selectors: [AudioObjectPropertySelector] = [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices]

    init(onChange: @escaping @MainActor @Sendable () -> Void) {
        listener = { _, _ in Task { @MainActor in onChange() } }
        for selector in selectors {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
    }

    deinit {
        for selector in selectors {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
    }
}
