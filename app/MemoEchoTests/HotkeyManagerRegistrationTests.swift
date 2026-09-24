import AppKit
import XCTest
@testable import MemoEcho

@MainActor
final class HotkeyManagerRegistrationTests: XCTestCase {
    private final class CallbackRecorder {
        var specialActions: [SpecialHotkeyGestureAction] = []
        var standardPressCount = 0
    }

    private let rightCommand = HotkeyCombo.special(
        modifiers: [HotkeyModifierSpec(key: .command, side: .right)]
    )

    private func configureExistingOptionSpace(_ store: ConfigStore) throws {
        var general = store.generalConfig
        general.hotkey = .standard(
            keyCode: 49, modifiers: NSEvent.ModifierFlags.option.rawValue, keyLabel: "Space"
        )
        try store.saveGeneralConfig(general)
    }

    func testReplaceRestoresPreviousHotkeyWhenInstallFails() {
        let manager = HotkeyManager()
        let original = HotkeyCombo.special(
            modifiers: [HotkeyModifierSpec(key: .option, side: .left)]
        )
        let incoming = HotkeyCombo.special(
            modifiers: [HotkeyModifierSpec(key: .command, side: .right)]
        )

        manager.testInstallHandler = { combo in
            combo == incoming ? .failure("无法注册该快捷键，可能已被系统占用。") : .success
        }

        XCTAssertEqual(manager.register(hotkey: original), .success)
        XCTAssertEqual(manager.registeredHotkey, original)

        let result = manager.replace(with: incoming)
        XCTAssertEqual(result, .failure("无法注册该快捷键，可能已被系统占用。"))
        XCTAssertEqual(manager.registeredHotkey, original)
    }

    func testReplacePersistsNewHotkeyWhenInstallSucceeds() {
        let manager = HotkeyManager()
        let original = HotkeyCombo.default
        let incoming = HotkeyCombo.special(
            modifiers: [HotkeyModifierSpec(key: .function)]
        )
        manager.testInstallHandler = { _ in .success }

        XCTAssertEqual(manager.register(hotkey: original), .success)
        XCTAssertEqual(manager.replace(with: incoming), .success)
        XCTAssertEqual(manager.registeredHotkey, incoming)
    }

    func testAppShortcutChangeSavesAndConfirmsOnlyAfterRegistration() throws {
        let fixture = try OnboardingTestFixture()
        defer { fixture.cleanup() }
        try configureExistingOptionSpace(fixture.store)
        let manager = HotkeyManager()
        manager.testInstallHandler = { _ in .success }
        _ = manager.register(hotkey: fixture.store.generalConfig.hotkey)
        XCTAssertEqual(AppCoordinator.applyHotkey(rightCommand, manager: manager, configStore: fixture.store), .success)
        XCTAssertEqual(fixture.store.generalConfig.hotkey, rightCommand)
        XCTAssertTrue(fixture.store.onboardingProgress.hasConfirmedHotkey)
    }

    func testAppShortcutSaveFailureRestoresOldListenerAndConfiguration() throws {
        let fixture = try OnboardingTestFixture()
        defer { fixture.cleanup() }
        try configureExistingOptionSpace(fixture.store)
        let manager = HotkeyManager()
        manager.testInstallHandler = { _ in .success }
        let original = fixture.store.generalConfig.hotkey
        _ = manager.register(hotkey: original)
        let configURL = fixture.directory.appendingPathComponent("config.json")
        try FileManager.default.removeItem(at: configURL)
        try FileManager.default.createDirectory(at: configURL, withIntermediateDirectories: false)
        let result = AppCoordinator.applyHotkey(rightCommand, manager: manager, configStore: fixture.store)
        XCTAssertNotEqual(result, .success)
        XCTAssertEqual(manager.registeredHotkey, original)
        XCTAssertEqual(fixture.store.generalConfig.hotkey, original)
        XCTAssertFalse(fixture.store.onboardingProgress.hasConfirmedHotkey)
    }

    func testNewRegistrationAndRollbackBothFailLeaveNoListenerAndNoConfirmation() throws {
        let fixture = try OnboardingTestFixture()
        defer { fixture.cleanup() }
        try configureExistingOptionSpace(fixture.store)
        let manager = HotkeyManager()
        manager.testInstallHandler = { _ in .success }
        let original = fixture.store.generalConfig.hotkey
        _ = manager.register(hotkey: original)
        manager.testInstallHandler = { _ in .failure("注册失败") }
        XCTAssertNotEqual(AppCoordinator.applyHotkey(rightCommand, manager: manager, configStore: fixture.store), .success)
        XCTAssertNil(manager.registeredHotkey)
        XCTAssertEqual(fixture.store.generalConfig.hotkey, original)
        XCTAssertFalse(fixture.store.onboardingProgress.hasConfirmedHotkey)
    }

    func testSuspendingManagerClearsArmedSpecialGesture() {
        let manager = HotkeyManager()
        _ = manager.consumeSpecialGestureEvent(
            .modifierFlagsChanged([.rightCommand]),
            hotkey: rightCommand
        )

        manager.setSuspended(true)
        manager.setSuspended(false)

        XCTAssertFalse(
            manager.consumeSpecialGestureEvent(.modifierFlagsChanged([]), hotkey: rightCommand)
        )
    }

    func testUnregisteringManagerClearsArmedSpecialGesture() {
        let manager = HotkeyManager()
        _ = manager.consumeSpecialGestureEvent(
            .modifierFlagsChanged([.rightCommand]),
            hotkey: rightCommand
        )

        manager.unregister()

        XCTAssertFalse(
            manager.consumeSpecialGestureEvent(.modifierFlagsChanged([]), hotkey: rightCommand)
        )
    }

    func testFailedReplacementAndRollbackClearArmedSpecialGesture() {
        let manager = HotkeyManager()
        let incoming = HotkeyCombo.special(
            modifiers: [HotkeyModifierSpec(key: .function)]
        )
        manager.testInstallHandler = { combo in
            combo == incoming ? .failure("无法注册该快捷键，可能已被系统占用。") : .success
        }
        XCTAssertEqual(manager.register(hotkey: rightCommand), .success)
        _ = manager.consumeSpecialGestureEvent(
            .modifierFlagsChanged([.rightCommand]),
            hotkey: rightCommand
        )

        _ = manager.replace(with: incoming)

        XCTAssertFalse(
            manager.consumeSpecialGestureEvent(.modifierFlagsChanged([]), hotkey: rightCommand)
        )
    }

    func testSpecialGesturePublishesPhasesWithoutUsingStandardPressCallback() async {
        let manager = HotkeyManager()
        let recorder = CallbackRecorder()
        manager.onSpecialGestureAction = { action in
            recorder.specialActions.append(action)
        }
        manager.onKeyDown = {
            recorder.standardPressCount += 1
        }

        _ = manager.consumeSpecialGestureEvent(
            .modifierFlagsChanged([.rightCommand]),
            hotkey: rightCommand
        )
        await Task.yield()
        _ = manager.consumeSpecialGestureEvent(
            .modifierFlagsChanged([]),
            hotkey: rightCommand
        )
        await Task.yield()

        XCTAssertEqual(recorder.specialActions, [.began, .confirmed])
        XCTAssertEqual(recorder.standardPressCount, 0)
    }

    func testSuspendingManagerPublishesPendingGestureCancellation() async {
        let manager = HotkeyManager()
        let recorder = CallbackRecorder()
        manager.onSpecialGestureAction = { action in
            recorder.specialActions.append(action)
        }

        _ = manager.consumeSpecialGestureEvent(
            .modifierFlagsChanged([.rightCommand]),
            hotkey: rightCommand
        )
        await Task.yield()
        manager.setSuspended(true)
        await Task.yield()

        XCTAssertEqual(recorder.specialActions, [.began, .cancelled])
    }
}
