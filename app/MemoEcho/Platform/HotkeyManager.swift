import AppKit
import Carbon.HIToolbox
import Foundation

enum SpecialHotkeyGestureState: Equatable {
    case idle
    case armed
    case cancelled
}

enum SpecialHotkeyGestureEvent: Equatable {
    case modifierFlagsChanged(Set<HotkeyPhysicalModifier>)
    case keyDown(UInt16)
    case systemDefined
}

enum SpecialHotkeyGestureAction: Equatable, Sendable {
    case none
    case began
    case confirmed
    case cancelled
}

struct SpecialHotkeyTransition: Equatable {
    let state: SpecialHotkeyGestureState
    let action: SpecialHotkeyGestureAction

    var shouldTrigger: Bool {
        action == .confirmed
    }

    init(state: SpecialHotkeyGestureState, action: SpecialHotkeyGestureAction) {
        self.state = state
        self.action = action
    }

    init(state: SpecialHotkeyGestureState, shouldTrigger: Bool) {
        self.init(state: state, action: shouldTrigger ? .confirmed : .none)
    }
}

enum HotkeyInputEvent {
    case keyDown(UInt16, modifiers: Set<HotkeyPhysicalModifier>, isRepeat: Bool)
    case keyUp(UInt16)
    case modifiersChanged(Set<HotkeyPhysicalModifier>)
    case systemDefined
}

enum HotkeyRegistrationResult: Equatable {
    case success
    case failure(String)

    var errorMessage: String? {
        switch self {
        case .success:
            nil
        case .failure(let message):
            message
        }
    }
}

/// 全局快捷键管理器，使用 Carbon Event API 注册和监听全局热键按下/松开
final class HotkeyManager: @unchecked Sendable {

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var isKeyDown = false
    private var isBlockedUntilRelease = false
    private var recognizer = HotkeyGestureRecognizer(mode: .singlePress)
    var onGestureAction: (@MainActor @Sendable (HotkeyGestureAction) -> Void)?
    var isTriggerAllowed: (@MainActor @Sendable () -> Bool)?
    var allowsTranslationShortcut: (@MainActor @Sendable () -> Bool)?
    private var specialHotkeyGestureState: SpecialHotkeyGestureState = .idle
    private(set) var registeredHotkey: HotkeyCombo?
    private var isSuspended = false
    var testInstallHandler: ((HotkeyCombo) -> HotkeyRegistrationResult)?

    /// 快捷键按下回调
    var onKeyDown: (@MainActor @Sendable () -> Void)?
    /// 快捷键松开回调
    var onKeyUp: (@MainActor @Sendable () -> Void)?
    /// 纯修饰键手势阶段回调：按下候选、干净释放确认或组合键取消
    var onSpecialGestureAction: (@MainActor @Sendable (SpecialHotkeyGestureAction) -> Void)?

    private static let hotkeySignature: FourCharCode = 0x5459504C // "TYPL"
    private static let hotkeyID: UInt32 = 1

    deinit {
        unregister()
    }

    /// 注册全局快捷键。失败时当前没有任何已注册快捷键。
    @discardableResult
    func register(hotkey: HotkeyCombo) -> HotkeyRegistrationResult {
        unregister()
        let result = install(hotkey)
        if case .success = result {
            registeredHotkey = hotkey
            recognizer = HotkeyGestureRecognizer(mode: hotkey.triggerMode)
            if testInstallHandler == nil { blockCurrentlyPressedKey(hotkey) }
        }
        return result
    }

    /// 尝试切换到新快捷键；失败时恢复原来的监听。
    @discardableResult
    func replace(with newHotkey: HotkeyCombo) -> HotkeyRegistrationResult {
        let previous = registeredHotkey
        let result = register(hotkey: newHotkey)
        if case .failure = result, let previous {
            _ = register(hotkey: previous)
        }
        return result
    }

    private func install(_ hotkey: HotkeyCombo) -> HotkeyRegistrationResult {
        if let testInstallHandler {
            return testInstallHandler(hotkey)
        }

        if hotkey.isPureModifier {
            return installSpecialHotkey(hotkey)
        }

        if hotkey.hasPhysicalStandardModifiers {
            return installPhysicalStandardHotkey(hotkey)
        }

        return installCarbonHotkey(hotkey)
    }

    private func installCarbonHotkey(_ hotkey: HotkeyCombo) -> HotkeyRegistrationResult {
        let carbonMods = Self.carbonModifiers(from: hotkey.modifiers)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        var eventTypes = [
            EventTypeSpec(
                eventClass: UInt32(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: UInt32(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            ),
        ]

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotkeyCallback,
            2,
            &eventTypes,
            selfPtr,
            &eventHandlerRef
        )
        guard handlerStatus == noErr else {
            eventHandlerRef = nil
            return .failure("无法注册该快捷键，可能已被系统占用。")
        }

        let hotKeyID = EventHotKeyID(
            signature: Self.hotkeySignature,
            id: Self.hotkeyID
        )
        let registerStatus = RegisterEventHotKey(
            UInt32(hotkey.keyCode ?? 0),
            carbonMods,
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(0),
            &hotKeyRef
        )
        guard registerStatus == noErr, hotKeyRef != nil else {
            if let ref = eventHandlerRef {
                RemoveEventHandler(ref)
                eventHandlerRef = nil
            }
            hotKeyRef = nil
            return .failure("无法注册该快捷键，可能已被系统占用。")
        }

        if hotkey.triggerMode != .singlePress {
            let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged, .systemDefined]
            globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
                self?.handleModeEvent(event)
            }
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                self?.handleModeEvent(event)
                return event
            }
            guard globalKeyMonitor != nil, localKeyMonitor != nil else {
                unregister()
                return .failure("无法监听该快捷键，请检查辅助功能权限。")
            }
        }
        return .success
    }

    private func installSpecialHotkey(_ hotkey: HotkeyCombo) -> HotkeyRegistrationResult {
        let keyActivityMask: NSEvent.EventTypeMask = [.keyDown, .systemDefined]
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: keyActivityMask) { [weak self] event in
            self?.handleSpecialEvent(event, hotkey: hotkey)
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: keyActivityMask) { [weak self] event in
            self?.handleSpecialEvent(event, hotkey: hotkey)
            return event
        }
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleSpecialEvent(event, hotkey: hotkey)
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleSpecialEvent(event, hotkey: hotkey)
            return event
        }
        guard globalKeyMonitor != nil, localKeyMonitor != nil,
              globalFlagsMonitor != nil, localFlagsMonitor != nil else {
            unregister()
            return .failure("无法监听该修饰键组合。")
        }
        return .success
    }

    private func installPhysicalStandardHotkey(_ hotkey: HotkeyCombo) -> HotkeyRegistrationResult {
        let keyMask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .systemDefined]
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: keyMask) { [weak self] event in
            self?.handlePhysicalStandardEvent(event, hotkey: hotkey)
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: keyMask) { [weak self] event in
            self?.handlePhysicalStandardEvent(event, hotkey: hotkey)
            return event
        }
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handlePhysicalStandardEvent(event, hotkey: hotkey)
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handlePhysicalStandardEvent(event, hotkey: hotkey)
            return event
        }
        guard globalKeyMonitor != nil, localKeyMonitor != nil,
              globalFlagsMonitor != nil, localFlagsMonitor != nil else {
            unregister()
            return .failure("无法监听该快捷键组合，请检查辅助功能权限。")
        }
        return .success
    }

    /// 注销当前注册的快捷键
    func unregister() {
        resetGesture()
        registeredHotkey = nil
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
            eventHandlerRef = nil
        }
        if let monitor = globalFlagsMonitor {
            NSEvent.removeMonitor(monitor)
            globalFlagsMonitor = nil
        }
        if let monitor = localFlagsMonitor {
            NSEvent.removeMonitor(monitor)
            localFlagsMonitor = nil
        }
        if let monitor = globalKeyMonitor {
            NSEvent.removeMonitor(monitor)
            globalKeyMonitor = nil
        }
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
        isKeyDown = false
        isBlockedUntilRelease = false
    }

    func setSuspended(_ suspended: Bool) {
        isSuspended = suspended
        if suspended { resetGesture() }
        else if let hotkey = registeredHotkey, testInstallHandler == nil { blockCurrentlyPressedKey(hotkey) }
    }

    /// 生命周期与会话切换不等于用户松键；未结束的按住只能取消。
    func resetGesture() {
        let wasHeld = isKeyDown || specialHotkeyGestureState == .armed
        isBlockedUntilRelease = isBlockedUntilRelease || wasHeld
        isKeyDown = false
        cancelPendingSpecialGesture()
        publish(recognizer.reset())
    }

    private func blockCurrentlyPressedKey(_ hotkey: HotkeyCombo) {
        if hotkey.isPureModifier {
            let pressed = HotkeyPhysicalModifier.pressedSet(from: NSEvent.modifierFlags)
            isBlockedUntilRelease = isBlockedUntilRelease || containsTargetModifier(pressed, hotkey: hotkey)
        } else if let keyCode = hotkey.keyCode {
            isBlockedUntilRelease = isBlockedUntilRelease || CGEventSource.keyState(.combinedSessionState, key: keyCode)
        }
    }

    private var canTrigger: Bool {
        MainActor.assumeIsolated { isTriggerAllowed?() ?? true }
    }

    func handlePress(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !isSuspended, !isBlockedUntilRelease, !isKeyDown, canTrigger else { return }
        isKeyDown = true
        if registeredHotkey?.triggerMode != .singlePress {
            publish(recognizer.press(at: time))
        } else if let callback = onKeyDown {
            MainActor.assumeIsolated { callback() }
        }
    }

    func handleRelease(at time: TimeInterval = ProcessInfo.processInfo.systemUptime, primaryIsDown: Bool = false) {
        if registeredHotkey?.triggerMode == .doublePress, primaryIsDown {
            interruptGesture()
            return
        }
        isBlockedUntilRelease = false
        guard !isSuspended, isKeyDown else { isKeyDown = false; return }
        isKeyDown = false
        if registeredHotkey?.triggerMode != .singlePress {
            publish(recognizer.release(at: time))
        } else if let callback = onKeyUp {
            MainActor.assumeIsolated { callback() }
        }
    }

    private func publish(_ action: HotkeyGestureAction?) {
        guard let action else { return }
        // Carbon application handlers and NSEvent monitors deliver on the main thread.
        // Hold begin/release must finish in event order, before another key can be handled.
        MainActor.assumeIsolated { onGestureAction?(action) }
    }

    private func interruptGesture(blockUntilRelease: Bool = false) {
        isBlockedUntilRelease = isBlockedUntilRelease || isKeyDown || blockUntilRelease
        isKeyDown = false
        publish(recognizer.reset())
    }

    private func handleModeEvent(_ event: NSEvent) {
        let pressed = HotkeyPhysicalModifier.pressedSet(from: event.modifierFlags)
        let input: HotkeyInputEvent
        switch event.type {
        case .keyDown: input = .keyDown(event.keyCode, modifiers: pressed, isRepeat: event.isARepeat)
        case .keyUp: input = .keyUp(event.keyCode)
        case .flagsChanged: input = .modifiersChanged(pressed)
        case .systemDefined: input = .systemDefined
        default: return
        }
        consumeEvent(input, at: event.timestamp)
    }

    /// Carbon remains authoritative for generic ordinary-key presses/releases.
    /// Its supplementary monitor only invalidates gestures or observes early modifier release.
    func consumeEvent(_ event: HotkeyInputEvent, at time: TimeInterval) {
        guard let hotkey = registeredHotkey, hotkey.triggerMode != .singlePress else { return }
        switch event {
        case .modifiersChanged(let pressed):
            if hotkey.isPureModifier {
                let targetsReleased = hotkey.triggerMode == .hold
                    ? !containsTargetModifier(pressed, hotkey: hotkey) : pressed.isEmpty
                if isBlockedUntilRelease {
                    if targetsReleased { isBlockedUntilRelease = false }
                    return
                }
                guard !isSuspended else { return }
                if isKeyDown {
                    if targetsReleased { handleRelease(at: time) }
                    else if !hotkey.pressedModifiersAreSubsetOfRecordedSpecialModifiers(pressed)
                        && !isTranslationModifierCandidate(pressed, hotkey: hotkey) { interruptGesture() }
                } else if hotkey.matchesSpecialPressedModifiers(pressed) {
                    handlePress(at: time)
                } else if !hotkey.pressedModifiersAreSubsetOfRecordedSpecialModifiers(pressed) {
                    interruptGesture(blockUntilRelease: !pressed.isEmpty)
                }
            } else {
                guard !isSuspended else { return }
                if isKeyDown && !requiredModifiersPresent(pressed, hotkey: hotkey) {
                    if hotkey.triggerMode == .hold { handleRelease(at: time); isBlockedUntilRelease = true }
                    else { interruptGesture() }
                } else if !modifiersAreAllowed(pressed, hotkey: hotkey)
                            && !isTranslationModifierCandidate(pressed, hotkey: hotkey) {
                    interruptGesture()
                }
            }
        case .keyDown(let code, let pressed, let isRepeat):
            guard !isSuspended else { return }
            if HotkeyPhysicalModifier.modifierKeyCodes.contains(code) { return }
            if !hotkey.isPureModifier, code == hotkey.keyCode,
               modifiersMatch(pressed, hotkey: hotkey) {
                if hotkey.hasPhysicalStandardModifiers && !isRepeat { handlePress(at: time) }
            } else if !isTranslationKey(code, pressed: pressed, hotkey: hotkey) {
                interruptGesture(blockUntilRelease: hotkey.isPureModifier
                    ? containsTargetModifier(pressed, hotkey: hotkey) : code == hotkey.keyCode)
            }
        case .keyUp(let code):
            if !hotkey.isPureModifier, code == hotkey.keyCode {
                if hotkey.hasPhysicalStandardModifiers { handleRelease(at: time) }
                else { isBlockedUntilRelease = false }
            }
        case .systemDefined:
            guard !isSuspended else { return }
            interruptGesture()
        }
    }

    private func containsTargetModifier(_ pressed: Set<HotkeyPhysicalModifier>, hotkey: HotkeyCombo) -> Bool {
        pressed.contains { physical in
            hotkey.specialModifiers.contains { $0.key == physical.spec.key && ($0.side == .either || $0.side == physical.spec.side) }
        }
    }

    private func requiredModifiersPresent(_ pressed: Set<HotkeyPhysicalModifier>, hotkey: HotkeyCombo) -> Bool {
        if hotkey.hasPhysicalStandardModifiers {
            return hotkey.specialModifiers.allSatisfy { spec in
                pressed.contains { $0.spec.key == spec.key && (spec.side == .either || $0.spec.side == spec.side) }
            }
        }
        let required = NSEvent.ModifierFlags(rawValue: hotkey.modifiers).intersection([.command, .control, .option, .shift, .function])
        return pressed.genericFlags.isSuperset(of: required)
    }

    private func modifiersAreAllowed(_ pressed: Set<HotkeyPhysicalModifier>, hotkey: HotkeyCombo) -> Bool {
        if hotkey.hasPhysicalStandardModifiers {
            return pressed.allSatisfy { physical in
                hotkey.specialModifiers.contains { $0.key == physical.spec.key && ($0.side == .either || $0.side == physical.spec.side) }
            }
        }
        let required = NSEvent.ModifierFlags(rawValue: hotkey.modifiers).intersection([.command, .control, .option, .shift, .function])
        return pressed.genericFlags.subtracting(required).isEmpty
    }

    private func modifiersMatch(_ pressed: Set<HotkeyPhysicalModifier>, hotkey: HotkeyCombo) -> Bool {
        requiredModifiersPresent(pressed, hotkey: hotkey) && modifiersAreAllowed(pressed, hotkey: hotkey)
    }

    private func isTranslationModifierCandidate(_ pressed: Set<HotkeyPhysicalModifier>, hotkey: HotkeyCombo) -> Bool {
        guard hotkey.triggerMode == .hold, isKeyDown,
              MainActor.assumeIsolated({ allowsTranslationShortcut?() ?? false }) else { return false }
        let withoutShift = pressed.filter { $0.spec.key != .shift }
        if hotkey.isPureModifier {
            return hotkey.pressedModifiersAreSubsetOfRecordedSpecialModifiers(withoutShift)
        }
        return modifiersAreAllowed(withoutShift, hotkey: hotkey)
    }

    private func isTranslationKey(_ code: UInt16, pressed: Set<HotkeyPhysicalModifier>, hotkey: HotkeyCombo) -> Bool {
        code == UInt16(kVK_Tab) && pressed.contains { $0.spec.key == .shift }
            && isTranslationModifierCandidate(pressed, hotkey: hotkey)
    }

    // MARK: - Modifier Conversion

    private static func carbonModifiers(from nsModifiers: UInt) -> UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: nsModifiers)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }

    private func handleSpecialEvent(_ event: NSEvent, hotkey: HotkeyCombo) {
        if hotkey.triggerMode != .singlePress { handleModeEvent(event); return }
        let gestureEvent: SpecialHotkeyGestureEvent
        switch event.type {
        case .flagsChanged:
            gestureEvent = .modifierFlagsChanged(
                HotkeyPhysicalModifier.pressedSet(from: event.modifierFlags)
            )
        case .keyDown:
            gestureEvent = .keyDown(UInt16(event.keyCode))
        case .systemDefined:
            gestureEvent = .systemDefined
        default:
            return
        }

        consumeSpecialGestureEvent(gestureEvent, hotkey: hotkey)
    }

    @discardableResult
    func consumeSpecialGestureEvent(
        _ gestureEvent: SpecialHotkeyGestureEvent,
        hotkey: HotkeyCombo
    ) -> Bool {
        if isBlockedUntilRelease {
            if case .modifierFlagsChanged(let pressed) = gestureEvent, pressed.isEmpty { isBlockedUntilRelease = false }
            return false
        }
        guard canTrigger || isSuspended else { return false }
        let transition = Self.resolveSpecialGestureEvent(
            gestureEvent,
            hotkey: hotkey,
            state: specialHotkeyGestureState,
            isSuspended: isSuspended
        )
        specialHotkeyGestureState = transition.state

        publishSpecialGestureAction(transition.action)

        return transition.shouldTrigger
    }

    /// 纯修饰键按下时进入候选态；未参与其他组合键的完整释放才确认触发。
    static func resolveSpecialGestureEvent(
        _ event: SpecialHotkeyGestureEvent,
        hotkey: HotkeyCombo,
        state: SpecialHotkeyGestureState,
        isSuspended: Bool
    ) -> SpecialHotkeyTransition {
        guard !isSuspended else {
            return SpecialHotkeyTransition(
                state: .idle,
                action: state == .idle ? .none : .cancelled
            )
        }

        switch (state, event) {
        case (.idle, .modifierFlagsChanged(let pressed))
            where hotkey.matchesSpecialPressedModifiers(pressed):
            return SpecialHotkeyTransition(state: .armed, action: .began)
        case (.idle, .modifierFlagsChanged(let pressed))
            where hotkey.pressedModifiersAreSubsetOfRecordedSpecialModifiers(pressed):
            return SpecialHotkeyTransition(state: .idle, shouldTrigger: false)
        case (.idle, .modifierFlagsChanged):
            return SpecialHotkeyTransition(state: .cancelled, shouldTrigger: false)
        case (.armed, .keyDown(let keyCode))
            where !HotkeyPhysicalModifier.modifierKeyCodes.contains(keyCode):
            return SpecialHotkeyTransition(state: .cancelled, shouldTrigger: false)
        case (.armed, .systemDefined):
            return SpecialHotkeyTransition(state: .cancelled, shouldTrigger: false)
        case (.armed, .modifierFlagsChanged(let pressed)) where pressed.isEmpty:
            return SpecialHotkeyTransition(state: .idle, action: .confirmed)
        case (.armed, .modifierFlagsChanged(let pressed))
            where hotkey.matchesSpecialPressedModifiers(pressed)
                || hotkey.pressedModifiersAreSubsetOfRecordedSpecialModifiers(pressed):
            return SpecialHotkeyTransition(state: .armed, shouldTrigger: false)
        case (.armed, .modifierFlagsChanged):
            return SpecialHotkeyTransition(state: .cancelled, shouldTrigger: false)
        case (.cancelled, .modifierFlagsChanged(let pressed)) where pressed.isEmpty:
            return SpecialHotkeyTransition(state: .idle, action: .cancelled)
        default:
            return SpecialHotkeyTransition(state: state, shouldTrigger: false)
        }
    }

    private func cancelPendingSpecialGesture() {
        guard specialHotkeyGestureState != .idle else { return }
        specialHotkeyGestureState = .idle
        publishSpecialGestureAction(.cancelled)
    }

    private func publishSpecialGestureAction(_ action: SpecialHotkeyGestureAction) {
        guard action != .none, let callback = onSpecialGestureAction else { return }
        MainActor.assumeIsolated { callback(action) }
    }

    private func handlePhysicalStandardEvent(_ event: NSEvent, hotkey: HotkeyCombo) {
        if hotkey.triggerMode != .singlePress { handleModeEvent(event); return }
        if event.type == .keyDown && event.isARepeat { return }
        let pressed = HotkeyPhysicalModifier.pressedSet(from: event.modifierFlags)

        switch event.type {
        case .keyDown:
            if hotkey.matchesStandardPressedModifiers(
                keyCode: UInt16(event.keyCode),
                pressed: pressed
            ) {
                handlePress()
            }
        case .keyUp:
            if hotkey.keyCode == UInt16(event.keyCode) {
                handleRelease()
            }
        case .flagsChanged:
            guard isKeyDown, let keyCode = hotkey.keyCode else { return }
            if !hotkey.matchesStandardPressedModifiers(keyCode: keyCode, pressed: pressed) {
                handleRelease()
            }
        default:
            return
        }
    }
}

// MARK: - Carbon Callback

private func carbonHotkeyCallback(
    _: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else {
        return OSStatus(eventNotHandledErr)
    }

    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()

    switch GetEventKind(event) {
    case UInt32(kEventHotKeyPressed):
        manager.handlePress(at: GetEventTime(event))
    case UInt32(kEventHotKeyReleased):
        manager.handleRelease(at: GetEventTime(event), primaryIsDown: manager.registeredHotkey?.keyCode.map {
            CGEventSource.keyState(.combinedSessionState, key: $0)
        } ?? false)
    default:
        return OSStatus(eventNotHandledErr)
    }

    return noErr
}
