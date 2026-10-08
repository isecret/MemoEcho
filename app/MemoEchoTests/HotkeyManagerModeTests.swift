import AppKit
import XCTest
@testable import MemoEcho

@MainActor
final class HotkeyManagerModeTests: XCTestCase {
    private final class Output { var actions: [HotkeyGestureAction] = [] }

    private func fixture(_ combo: HotkeyCombo) -> (HotkeyManager, Output) {
        let manager = HotkeyManager()
        let output = Output()
        manager.testInstallHandler = { _ in .success }
        _ = manager.register(hotkey: combo)
        manager.onGestureAction = { output.actions.append($0) }
        return (manager, output)
    }

    private func ordinary(_ mode: HotkeyTriggerMode, physical: Bool = true) -> HotkeyCombo {
        .standard(keyCode: 49, modifiers: NSEvent.ModifierFlags.option.rawValue, keyLabel: "Space",
                  physicalModifiers: physical ? [.init(key: .option, side: .left)] : []).withTriggerMode(mode)
    }

    func testPureModifierDoublePressWaitsForBothCompleteReleases() {
        let (manager, output) = fixture(.default.withTriggerMode(.doublePress))
        manager.consumeEvent(.modifiersChanged([.rightCommand]), at: 0)
        manager.consumeEvent(.modifiersChanged([.rightCommand]), at: 0.05)
        XCTAssertTrue(output.actions.isEmpty)
        manager.consumeEvent(.modifiersChanged([]), at: 0.1)
        manager.consumeEvent(.modifiersChanged([.rightCommand]), at: 0.2)
        XCTAssertTrue(output.actions.isEmpty)
        manager.consumeEvent(.modifiersChanged([]), at: 0.3)
        XCTAssertEqual(output.actions, [.toggle])
    }

    func testPhysicalDoublePressCanKeepModifiersHeld() {
        let (manager, output) = fixture(ordinary(.doublePress))
        for time in [0.0, 0.2] {
            manager.consumeEvent(.keyDown(49, modifiers: [.leftOption], isRepeat: false), at: time)
            manager.consumeEvent(.keyDown(49, modifiers: [.leftOption], isRepeat: true), at: time + 0.01)
            manager.consumeEvent(.keyUp(49), at: time + 0.05)
        }
        XCTAssertEqual(output.actions, [.toggle])
    }

    func testCarbonSupplementDoesNotCountPressTwice() {
        let (manager, output) = fixture(ordinary(.doublePress, physical: false))
        for time in [0.0, 0.2] {
            manager.handlePress(at: time)
            manager.consumeEvent(.keyDown(49, modifiers: [.rightOption], isRepeat: false), at: time)
            manager.consumeEvent(.keyUp(49), at: time + 0.05)
            manager.handleRelease(at: time + 0.05)
        }
        XCTAssertEqual(output.actions, [.toggle])
    }

    func testCarbonReleaseWithPrimaryStillHeldInvalidatesDoubleTap() {
        let (manager, output) = fixture(ordinary(.doublePress, physical: false))
        manager.handlePress(at: 0)
        manager.handleRelease(at: 0.1, primaryIsDown: true)
        manager.handlePress(at: 0.15) // cannot re-arm until primary release
        manager.handleRelease(at: 0.2)
        manager.handlePress(at: 0.25)
        manager.handleRelease(at: 0.3)
        XCTAssertTrue(output.actions.isEmpty)
    }

    func testUnrelatedKeysSystemEventsAndExtraModifiersBreakPendingPair() {
        let interruptions: [HotkeyInputEvent] = [
            .keyDown(8, modifiers: [], isRepeat: false), .systemDefined,
            .modifiersChanged([.leftOption])
        ]
        for interruption in interruptions {
            let (manager, output) = fixture(.default.withTriggerMode(.doublePress))
            manager.consumeEvent(.modifiersChanged([.rightCommand]), at: 0)
            manager.consumeEvent(.modifiersChanged([]), at: 0.05)
            manager.consumeEvent(interruption, at: 0.1)
            manager.consumeEvent(.modifiersChanged([]), at: 0.15)
            manager.consumeEvent(.modifiersChanged([.rightCommand]), at: 0.2)
            manager.consumeEvent(.modifiersChanged([]), at: 0.25)
            XCTAssertTrue(output.actions.isEmpty)
        }
    }

    func testRemovingExtraModifierFromInvalidChordCannotArmWhileTargetRemainsHeld() {
        for mode in [HotkeyTriggerMode.doublePress, .hold] {
            let (manager, output) = fixture(.default.withTriggerMode(mode))
            manager.consumeEvent(.modifiersChanged([.rightCommand, .leftOption]), at: 0)
            manager.consumeEvent(.modifiersChanged([.rightCommand]), at: 0.1)
            manager.consumeEvent(.modifiersChanged([]), at: 0.2)
            XCTAssertTrue(output.actions.isEmpty)
        }
    }

    func testPureModifierHoldCancelsChordWithoutSubmittingOrRestarting() {
        let (manager, output) = fixture(.default.withTriggerMode(.hold))
        manager.consumeEvent(.modifiersChanged([.rightCommand]), at: 0)
        manager.consumeEvent(.keyDown(8, modifiers: [.rightCommand], isRepeat: false), at: 1)
        manager.consumeEvent(.modifiersChanged([.rightCommand]), at: 1.1)
        manager.consumeEvent(.modifiersChanged([]), at: 1.2)
        XCTAssertEqual(output.actions, [.holdBegan(1), .holdCancelled(1)])
        manager.consumeEvent(.modifiersChanged([.rightCommand]), at: 2)
        manager.consumeEvent(.modifiersChanged([]), at: 3)
        XCTAssertEqual(output.actions.suffix(2), [.holdBegan(2), .holdEnded(2)])
    }

    func testMultiplePureModifiersHoldUntilAllTargetModifiersAreReleased() {
        let combo = HotkeyCombo.special(modifiers: [.init(key: .command, side: .right), .init(key: .option, side: .left)])
        let (manager, output) = fixture(combo.withTriggerMode(.hold))
        manager.consumeEvent(.modifiersChanged([.rightCommand]), at: 0)
        XCTAssertTrue(output.actions.isEmpty)
        manager.consumeEvent(.modifiersChanged([.rightCommand, .leftOption]), at: 0.1)
        manager.consumeEvent(.modifiersChanged([.leftOption]), at: 1)
        XCTAssertEqual(output.actions, [.holdBegan(1)])
        manager.consumeEvent(.modifiersChanged([]), at: 2)
        XCTAssertEqual(output.actions, [.holdBegan(1), .holdEnded(1)])
    }

    func testPhysicalHoldEndsOnPrimaryOrEarlyRequiredModifierRelease() {
        for release in [HotkeyInputEvent.keyUp(49), .modifiersChanged([])] {
            let (manager, output) = fixture(ordinary(.hold))
            manager.consumeEvent(.keyDown(49, modifiers: [.leftOption], isRepeat: false), at: 0)
            manager.consumeEvent(release, at: 1)
            manager.consumeEvent(.keyDown(49, modifiers: [.leftOption], isRepeat: true), at: 1.1)
            manager.consumeEvent(.keyUp(49), at: 1.2)
            XCTAssertEqual(output.actions, [.holdBegan(1), .holdEnded(1)])
        }
    }

    func testCarbonHoldEarlyModifierReleaseDoesNotDuplicateEnd() {
        let (manager, output) = fixture(ordinary(.hold, physical: false))
        manager.handlePress(at: 0)
        manager.consumeEvent(.modifiersChanged([]), at: 1)
        manager.handleRelease(at: 1.1)
        XCTAssertEqual(output.actions, [.holdBegan(1), .holdEnded(1)])
    }

    func testHoldAllowsShiftTabButStillCancelsOtherShiftChords() {
        let (manager, output) = fixture(.default.withTriggerMode(.hold))
        manager.allowsTranslationShortcut = { true }
        manager.consumeEvent(.modifiersChanged([.rightCommand]), at: 0)
        manager.consumeEvent(.modifiersChanged([.rightCommand, .leftShift]), at: 1)
        manager.consumeEvent(.keyDown(48, modifiers: [.rightCommand, .leftShift], isRepeat: false), at: 1.1)
        manager.consumeEvent(.modifiersChanged([.rightCommand]), at: 1.2)
        XCTAssertEqual(output.actions, [.holdBegan(1)])
        manager.consumeEvent(.modifiersChanged([.rightCommand, .leftShift]), at: 2)
        manager.consumeEvent(.keyDown(8, modifiers: [.rightCommand, .leftShift], isRepeat: false), at: 2.1)
        XCTAssertEqual(output.actions, [.holdBegan(1), .holdCancelled(1)])
    }

    func testFnHoldDoesNotTreatModifierKeyDownAsOrdinaryChord() {
        let combo = HotkeyCombo.special(modifiers: [.init(key: .function)]).withTriggerMode(.hold)
        let (manager, output) = fixture(combo)
        manager.consumeEvent(.modifiersChanged([.function]), at: 0)
        manager.consumeEvent(.keyDown(63, modifiers: [.function], isRepeat: false), at: 0.1)
        manager.consumeEvent(.modifiersChanged([]), at: 1)
        XCTAssertEqual(output.actions, [.holdBegan(1), .holdEnded(1)])
    }

    func testSuspendReregisterAndLifecycleResetCancelHoldInsteadOfEnding() {
        for reset in 0..<3 {
            let combo = HotkeyCombo.default.withTriggerMode(.hold)
            let (manager, output) = fixture(combo)
            manager.consumeEvent(.modifiersChanged([.rightCommand]), at: 0)
            switch reset {
            case 0: manager.setSuspended(true); manager.setSuspended(false)
            case 1: _ = manager.replace(with: combo)
            default: manager.resetGesture()
            }
            manager.consumeEvent(.modifiersChanged([]), at: 1)
            XCTAssertEqual(output.actions, [.holdBegan(1), .holdCancelled(1)])
        }
    }

    func testProcessingGateAndResetDoNotLeavePendingDoublePress() {
        let (manager, output) = fixture(.default.withTriggerMode(.doublePress))
        manager.consumeEvent(.modifiersChanged([.rightCommand]), at: 0)
        manager.consumeEvent(.modifiersChanged([]), at: 0.05)
        manager.isTriggerAllowed = { false }
        manager.resetGesture()
        manager.consumeEvent(.modifiersChanged([.rightCommand]), at: 0.1)
        manager.consumeEvent(.modifiersChanged([]), at: 0.15)
        manager.isTriggerAllowed = { true }
        manager.consumeEvent(.modifiersChanged([.rightCommand]), at: 0.2)
        manager.consumeEvent(.modifiersChanged([]), at: 0.25)
        XCTAssertTrue(output.actions.isEmpty)
    }
}
