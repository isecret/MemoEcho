import AppKit
import XCTest
@testable import MemoEcho

@MainActor
final class HotkeySyntheticEventTests: XCTestCase {
    private final class Output {
        var special: [SpecialHotkeyGestureAction] = []
        var gestures: [HotkeyGestureAction] = []
        var presses = 0
    }

    private func fixture(_ combo: HotkeyCombo) -> (HotkeyManager, Output) {
        let manager = HotkeyManager()
        let output = Output()
        manager.testInstallHandler = { _ in .success }
        XCTAssertEqual(manager.register(hotkey: combo), .success)
        manager.onSpecialGestureAction = { output.special.append($0) }
        manager.onGestureAction = { output.gestures.append($0) }
        manager.onKeyDown = { output.presses += 1 }
        return (manager, output)
    }

    private func event(_ code: UInt16, flags: UInt, at time: TimeInterval,
                       type: NSEvent.EventType = .flagsChanged) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: .init(rawValue: flags),
                         timestamp: time, windowNumber: 0, context: nil, characters: "",
                         charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }

    func testCapturedRemoteMicRightCommandSequenceReachesSinglePressCallbacks() {
        let (manager, output) = fixture(.default)
        // Captured from two actual RemoteMic gestures; no audio or typed content.
        for time in [20.46865, 24.16050] {
            manager.handleEvent(event(54, flags: 0x20100000, at: time))
            manager.handleEvent(event(54, flags: 0x20000000, at: time + 2))
        }
        XCTAssertEqual(output.special, [.began, .confirmed, .began, .confirmed])
    }

    func testEveryModifierWithoutDeviceBitsSupportsAllRecordingModes() {
        for key in HotkeyPhysicalModifier.allCases {
            for mode in [HotkeyTriggerMode.singlePress, .doublePress, .hold] {
                let combo = HotkeyCombo.special(modifiers: [key.spec]).withTriggerMode(mode)
                let (manager, output) = fixture(combo)
                for time in [0.0, 0.2] {
                    manager.handleEvent(event(key.rawValue, flags: key.genericFlags.rawValue, at: time))
                    manager.handleEvent(event(key.rawValue, flags: 0, at: time + 0.1))
                }
                switch mode {
                case .singlePress:
                    XCTAssertEqual(output.special, [.began, .confirmed, .began, .confirmed], "\(key)")
                case .doublePress:
                    XCTAssertEqual(output.gestures, [.toggle], "\(key)")
                case .hold:
                    XCTAssertEqual(output.gestures, [.holdBegan(1), .holdEnded(1), .holdBegan(2), .holdEnded(2)], "\(key)")
                }
            }
        }
    }

    func testOppositeSideNeverTriggersSideQualifiedHotkey() {
        for key in HotkeyPhysicalModifier.allCases where key != .function {
            let opposite = HotkeyPhysicalModifier.allCases.first {
                $0.spec.key == key.spec.key && $0 != key
            }!
            for mode in [HotkeyTriggerMode.singlePress, .doublePress, .hold] {
                let (manager, output) = fixture(.special(modifiers: [key.spec]).withTriggerMode(mode))
                for time in [0.0, 0.2] {
                    manager.handleEvent(event(opposite.rawValue, flags: key.genericFlags.rawValue, at: time))
                    manager.handleEvent(event(opposite.rawValue, flags: 0, at: time + 0.1))
                }
                XCTAssertFalse(output.special.contains(.began), "\(key)")
                XCTAssertTrue(output.gestures.isEmpty, "\(key)")
            }
        }
    }

    func testDuplicateFlagsDoNotToggleOrReleaseModifiers() {
        for key in HotkeyPhysicalModifier.allCases {
            let (manager, output) = fixture(.special(modifiers: [key.spec]).withTriggerMode(.hold))
            for time in [0.0, 0.1, 0.2] {
                manager.handleEvent(event(key.rawValue, flags: key.genericFlags.rawValue, at: time))
            }
            XCTAssertEqual(output.gestures, [.holdBegan(1)])
            for time in [0.3, 0.4] {
                manager.handleEvent(event(key.rawValue, flags: 0, at: time))
            }
            XCTAssertEqual(output.gestures, [.holdBegan(1), .holdEnded(1)])
        }
    }

    func testOrdinaryKeyCancelsSyntheticModifierGesture() {
        for mode in [HotkeyTriggerMode.singlePress, .doublePress, .hold] {
            let (manager, output) = fixture(.default.withTriggerMode(mode))
            manager.handleEvent(event(54, flags: 0x100000, at: 0))
            manager.handleEvent(event(8, flags: 0x100000, at: 0.1, type: .keyDown))
            manager.handleEvent(event(54, flags: 0, at: 0.2))
            XCTAssertFalse(output.special.contains(.confirmed))
            if mode == .hold { XCTAssertEqual(output.gestures, [.holdBegan(1), .holdCancelled(1)]) }
            else { XCTAssertTrue(output.gestures.isEmpty) }
        }
    }

    func testExtraKnownOrUnknownModifierCancelsAndCannotRearmUntilRelease() {
        // 56 identifies left Shift; 0 leaves its side unknown and must not be ignored.
        for extraCode: UInt16 in [56, 0] {
            for mode in [HotkeyTriggerMode.singlePress, .hold] {
                let (manager, output) = fixture(.default.withTriggerMode(mode))
                manager.handleEvent(event(54, flags: 0x100000, at: 0))
                manager.handleEvent(event(extraCode, flags: 0x120000, at: 0.1))
                manager.handleEvent(event(extraCode, flags: 0x100000, at: 0.2))
                manager.handleEvent(event(54, flags: 0x100000, at: 0.3))
                manager.handleEvent(event(54, flags: 0, at: 0.4))
                if mode == .singlePress { XCTAssertEqual(output.special, [.began, .cancelled]) }
                else { XCTAssertEqual(output.gestures, [.holdBegan(1), .holdCancelled(1)]) }
                manager.handleEvent(event(54, flags: 0x100000, at: 1))
                manager.handleEvent(event(54, flags: 0, at: 1.1))
                if mode == .singlePress { XCTAssertEqual(output.special.suffix(2), [.began, .confirmed]) }
                else { XCTAssertEqual(output.gestures.suffix(2), [.holdBegan(2), .holdEnded(2)]) }
            }
        }
    }

    func testUnknownGenericFlagsNeverGuessConfiguredSideOrConfirmRelease() {
        for combo in [HotkeyCombo.default, .special(modifiers: [.init(key: .command, side: .either)]),
                      .special(modifiers: [.init(key: .command, side: .left), .init(key: .command, side: .right)])] {
            let (manager, output) = fixture(combo)
            manager.handleEvent(event(0, flags: 0x100000, at: 0))
            manager.handleEvent(event(54, flags: 0x100000, at: 0.1))
            manager.handleEvent(event(54, flags: 0, at: 0.2))
            XCTAssertTrue(output.special.isEmpty)
        }
        let (manager, output) = fixture(.default)
        manager.handleEvent(event(54, flags: 0x100000, at: 0))
        // Command released, but an unqualified Shift remains: not a clean release.
        manager.handleEvent(event(54, flags: 0x20000, at: 0.1))
        manager.handleEvent(event(56, flags: 0, at: 0.2))
        XCTAssertEqual(output.special, [.began, .cancelled])
    }

    func testBothSidesAndPartialReleaseDoNotBecomeCleanSingleSideGesture() {
        for key in HotkeyPhysicalModifier.allCases where key.spec.side == .right {
            let left = HotkeyPhysicalModifier.allCases.first { $0.spec.key == key.spec.key && $0 != key }!
            let flags = key.genericFlags.rawValue
            let (manager, output) = fixture(.special(modifiers: [key.spec]))
            manager.handleEvent(event(left.rawValue, flags: flags, at: 0))
            manager.handleEvent(event(key.rawValue, flags: flags, at: 0.1))
            manager.handleEvent(event(left.rawValue, flags: flags, at: 0.2))
            manager.handleEvent(event(key.rawValue, flags: 0, at: 0.3))
            XCTAssertFalse(output.special.contains(.began))

            let (both, bothOutput) = fixture(.special(modifiers: [left.spec, key.spec]).withTriggerMode(.hold))
            both.handleEvent(event(left.rawValue, flags: flags, at: 0))
            both.handleEvent(event(key.rawValue, flags: flags, at: 0.1))
            both.handleEvent(event(left.rawValue, flags: flags, at: 0.2))
            XCTAssertEqual(bothOutput.gestures, [.holdBegan(1)])
            both.handleEvent(event(key.rawValue, flags: 0, at: 0.3))
            XCTAssertEqual(bothOutput.gestures, [.holdBegan(1), .holdEnded(1)])
        }
    }

    func testPhysicalDeviceBitsOverrideInferenceForEverySide() {
        let masks: [UInt16: UInt] = [55: 8, 54: 16, 58: 32, 61: 64, 59: 1, 62: 8192, 56: 2, 60: 4]
        for key in HotkeyPhysicalModifier.allCases where key != .function {
            let opposite = HotkeyPhysicalModifier.allCases.first { $0.spec.key == key.spec.key && $0 != key }!
            let flags = key.genericFlags.rawValue
            let (manager, output) = fixture(.special(modifiers: [key.spec]).withTriggerMode(.hold))
            // keyCode names the released key; the device bit names the opposite key still held.
            manager.handleEvent(event(key.rawValue, flags: flags | masks[opposite.rawValue]!, at: 0))
            manager.handleEvent(event(opposite.rawValue, flags: 0, at: 0.1))
            XCTAssertTrue(output.gestures.isEmpty)
            manager.handleEvent(event(key.rawValue, flags: flags | masks[key.rawValue]!, at: 1))
            manager.handleEvent(event(key.rawValue, flags: 0, at: 1.1))
            XCTAssertEqual(output.gestures, [.holdBegan(1), .holdEnded(1)])
        }
    }

    func testInferredModifiersSurviveOtherModifierAndOrdinaryKeyEvents() {
        let combo = HotkeyCombo.standard(keyCode: 49, modifiers: 0x140000, keyLabel: "Space",
                                        physicalModifiers: [.init(key: .command, side: .right),
                                                            .init(key: .control, side: .left)])
        for mode in [HotkeyTriggerMode.singlePress, .doublePress, .hold] {
            let (manager, output) = fixture(combo.withTriggerMode(mode))
            manager.handleEvent(event(54, flags: 0x100000, at: 0))
            manager.handleEvent(event(59, flags: 0x140000, at: 0.01))
            for time in [0.02, 0.22] {
                manager.handleEvent(event(49, flags: 0x140000, at: time, type: .keyDown))
                manager.handleEvent(event(49, flags: 0x140000, at: time + 0.1, type: .keyUp))
            }
            manager.handleEvent(event(54, flags: 0, at: 0.4))
            switch mode {
            case .singlePress: XCTAssertEqual(output.presses, 2)
            case .doublePress: XCTAssertEqual(output.gestures, [.toggle])
            case .hold: XCTAssertEqual(output.gestures, [.holdBegan(1), .holdEnded(1), .holdBegan(2), .holdEnded(2)])
            }
        }
    }

    func testSyntheticShiftTabStillAllowsTranslationDuringHold() {
        let (manager, output) = fixture(.default.withTriggerMode(.hold))
        manager.allowsTranslationShortcut = { true }
        manager.handleEvent(event(54, flags: 0x100000, at: 0))
        manager.handleEvent(event(56, flags: 0x120000, at: 0.1))
        manager.handleEvent(event(48, flags: 0x120000, at: 0.2, type: .keyDown))
        manager.handleEvent(event(56, flags: 0x100000, at: 0.3))
        manager.handleEvent(event(54, flags: 0, at: 0.4))
        XCTAssertEqual(output.gestures, [.holdBegan(1), .holdEnded(1)])
    }

    func testResetAndSuspensionCancelHeldGestureWithoutLateReleaseOrRestart() {
        for suspend in [false, true] {
            let (manager, output) = fixture(.default.withTriggerMode(.hold))
            manager.handleEvent(event(54, flags: 0x100000, at: 0))
            if suspend { manager.setSuspended(true); manager.setSuspended(false) }
            else { manager.resetGesture() }
            manager.handleEvent(event(54, flags: 0x100000, at: 0.1))
            manager.handleEvent(event(54, flags: 0, at: 0.2))
            XCTAssertEqual(output.gestures, [.holdBegan(1), .holdCancelled(1)])
            manager.handleEvent(event(54, flags: 0x100000, at: 1))
            manager.handleEvent(event(54, flags: 0, at: 1.1))
            XCTAssertEqual(output.gestures.suffix(2), [.holdBegan(2), .holdEnded(2)])
        }
    }

    func testRecorderCapturesEverySyntheticModifierWithCorrectSide() {
        for key in HotkeyPhysicalModifier.allCases {
            let control = HotkeyRecorderControl(frame: .zero)
            var captured: [HotkeyCombo] = []
            control.onCommit = { captured.append($0) }
            control.isActive = true
            control.flagsChanged(with: event(key.rawValue, flags: key.genericFlags.rawValue, at: 0))
            XCTAssertTrue(captured.isEmpty)
            control.flagsChanged(with: event(key.rawValue, flags: 0, at: 0.1))
            control.isActive = false
            XCTAssertEqual(captured, [.special(modifiers: [key.spec])], "\(key)")
        }
    }

    func testReregistrationCannotReuseInferredSideFromPreviousListener() {
        let (manager, output) = fixture(.default)
        manager.handleEvent(event(54, flags: 0x100000, at: 0))
        manager.register(hotkey: .default)
        XCTAssertEqual(output.special, [.began, .cancelled])
        manager.handleEvent(event(0, flags: 0x100000, at: 0.1))
        manager.handleEvent(event(54, flags: 0x100000, at: 0.2))
        manager.handleEvent(event(54, flags: 0, at: 0.3))
        XCTAssertEqual(output.special, [.began, .cancelled])
        manager.handleEvent(event(54, flags: 0x100000, at: 1))
        manager.handleEvent(event(54, flags: 0, at: 1.1))
        XCTAssertEqual(output.special.suffix(2), [.began, .confirmed])
    }

    func testRecorderPreservesSyntheticModifierForOrdinaryKeyAndRejectsUnknownSide() {
        let control = HotkeyRecorderControl(frame: .zero)
        var captured: [HotkeyCombo] = []
        var cancels = 0
        control.onCommit = { captured.append($0) }
        control.onCancel = { cancels += 1 }
        control.isActive = true
        control.flagsChanged(with: event(61, flags: 0x80000, at: 0))
        control.keyDown(with: event(49, flags: 0x80000, at: 0.1, type: .keyDown))
        control.isActive = false
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?.specialModifiers, [.init(key: .option, side: .right)])
        control.isActive = true
        control.flagsChanged(with: event(0, flags: 0x80000, at: 1))
        control.isActive = false
        XCTAssertEqual(cancels, 1)
        XCTAssertEqual(captured.count, 1)
    }
}
