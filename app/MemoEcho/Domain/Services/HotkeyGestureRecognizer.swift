import Foundation

enum HotkeyGestureAction: Equatable, Sendable {
    case toggle
    case holdBegan(UInt64)
    case holdEnded(UInt64)
    case holdCancelled(UInt64)
}

/// 输入须为去重后的有效按下／释放；时间戳采用系统单调时钟。
struct HotkeyGestureRecognizer {
    static let doublePressInterval: TimeInterval = 0.4
    let mode: HotkeyTriggerMode
    private var firstTap: TimeInterval?
    private var activePress: (time: TimeInterval, isSecond: Bool, id: UInt64)?
    private var nextID: UInt64 = 0

    init(mode: HotkeyTriggerMode) { self.mode = mode }

    mutating func press(at time: TimeInterval, isRepeat: Bool = false) -> HotkeyGestureAction? {
        guard activePress == nil, !isRepeat else { return nil }
        nextID &+= 1
        let isSecond = firstTap.map { time >= $0 && time - $0 <= Self.doublePressInterval } ?? false
        firstTap = nil
        activePress = (time, isSecond, nextID)
        switch mode {
        case .singlePress: return .toggle
        case .doublePress: return nil
        case .hold: return .holdBegan(nextID)
        }
    }

    mutating func release(at time: TimeInterval) -> HotkeyGestureAction? {
        guard let current = activePress else { return nil }
        activePress = nil
        switch mode {
        case .singlePress: return nil
        case .hold: return .holdEnded(current.id)
        case .doublePress:
            guard time >= current.time, time - current.time <= Self.doublePressInterval else {
                firstTap = nil
                return nil
            }
            if current.isSecond { return .toggle }
            firstTap = current.time
            return nil
        }
    }

    mutating func reset() -> HotkeyGestureAction? {
        let cancelled = mode == .hold ? activePress.map { HotkeyGestureAction.holdCancelled($0.id) } : nil
        activePress = nil
        firstTap = nil
        return cancelled
    }
}

/// 松键只能操作同一手势启动、且仍在录音的会话。
struct HoldHotkeyInteraction {
    private var owner: (gesture: UInt64, session: String)?

    mutating func began(gesture: UInt64, session: String) {
        owner = (gesture, session)
    }

    mutating func consume(gesture: UInt64, session: String, state: SessionState) -> Bool {
        guard let current = owner, current.gesture == gesture else { return false }
        owner = nil
        return current.session == session && state == .recording
    }

    mutating func reset() { owner = nil }
}
