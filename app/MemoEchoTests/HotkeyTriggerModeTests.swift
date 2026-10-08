import XCTest
import AppKit
import Carbon.HIToolbox
@testable import MemoEcho

@MainActor
final class HotkeyTriggerModeTests: XCTestCase {
    func testAssignmentPolicyIsSharedByAllModes() {
        for mode in HotkeyTriggerMode.allCases {
            for code in [kVK_ANSI_A, kVK_Space, kVK_Return, kVK_Tab, kVK_Delete, kVK_LeftArrow] {
                for flags in [NSEvent.ModifierFlags(), .shift] {
                    let combo = HotkeyCombo.standard(keyCode: UInt16(code), modifiers: flags.rawValue, keyLabel: "test")
                    XCTAssertNotNil(HotkeyAssignmentPolicy.error(for: combo.withTriggerMode(mode)))
                }
            }
            for flags in [NSEvent.ModifierFlags.command, .option, .control, HotkeyModifierKey.functionFlag] {
                let combo = HotkeyCombo.standard(keyCode: UInt16(kVK_ANSI_A), modifiers: flags.rawValue, keyLabel: "A")
                XCTAssertNil(HotkeyAssignmentPolicy.error(for: combo.withTriggerMode(mode)))
            }
            XCTAssertNil(HotkeyAssignmentPolicy.error(for: HotkeyCombo.special(modifiers: [.init(key: .shift)]).withTriggerMode(mode)))
            XCTAssertNil(HotkeyAssignmentPolicy.error(for: HotkeyCombo.default.withTriggerMode(mode)))
            XCTAssertNotNil(HotkeyAssignmentPolicy.error(for: .standard(keyCode: UInt16(kVK_Escape), modifiers: NSEvent.ModifierFlags.command.rawValue, keyLabel: "Esc")))
        }
    }

    func testInvalidShortcutDoesNotReplaceListenerOrSavedConfiguration() throws {
        let fixture = try OnboardingTestFixture()
        defer { fixture.cleanup() }
        let manager = HotkeyManager()
        manager.testInstallHandler = { _ in .success }
        let original = fixture.store.generalConfig.hotkey
        _ = manager.register(hotkey: original)
        manager.testInstallHandler = { _ in XCTFail("Invalid assignment must not touch listener"); return .success }
        let invalid = HotkeyCombo.standard(keyCode: UInt16(kVK_ANSI_A), modifiers: 0, keyLabel: "A")
        XCTAssertNotEqual(AppCoordinator.applyHotkey(invalid, manager: manager, configStore: fixture.store), .success)
        XCTAssertEqual(manager.registeredHotkey, original)
        XCTAssertEqual(ConfigStore(configDirectory: fixture.directory).generalConfig.hotkey, original)
        XCTAssertFalse(fixture.coordinator.applyHotkey(invalid))
        XCTAssertNotNil(fixture.coordinator.lastErrorMessage)
    }

    func testLegacyConfigurationDefaultsToSingleAndPreservesSerializedFingerprint() throws {
        let legacy = Data(#"{"kind":"special","modifiers":1048576,"specialModifiers":[{"key":"command","side":"right"}]}"#.utf8)
        let combo = try JSONDecoder().decode(HotkeyCombo.self, from: legacy)
        XCTAssertEqual(combo.triggerMode, .singlePress)
        XCTAssertEqual(combo, .default)
        let before = try JSONSerialization.jsonObject(with: legacy) as? NSDictionary
        let after = try JSONSerialization.jsonObject(with: JSONEncoder().encode(combo)) as? NSDictionary
        XCTAssertEqual(before, after)
        XCTAssertNil(after?["triggerMode"])
    }

    func testOnboardingRejectsModeEditWhileSessionIsActive() throws {
        let fixture = try OnboardingTestFixture()
        defer { fixture.cleanup() }
        fixture.coordinator.onApplyHotkey = { _ in XCTFail("Active session must not re-register"); return .success }
        fixture.coordinator.canEditHotkey = false
        XCTAssertFalse(fixture.coordinator.applyHotkey(.default.withTriggerMode(.hold)))
        XCTAssertEqual(fixture.store.generalConfig.hotkey.triggerMode, .singlePress)
    }

    func testSystemConflictCopyFollowsRecordingMode() {
        let fn = HotkeyCombo.special(modifiers: [.init(key: .function)])
        XCTAssertFalse(HotkeySystemConflict.functionKeyInstruction(for: fn).contains("听写"))
        XCTAssertTrue(HotkeySystemConflict.functionKeyInstruction(for: fn.withTriggerMode(.doublePress)).contains("听写"))
        XCTAssertNil(HotkeySystemConflict.warning(for: .default))
        XCTAssertNotNil(HotkeySystemConflict.warning(for: .default.withTriggerMode(.doublePress)))
    }

    func testExplicitModesRoundTripWithoutChangingKeyPresentation() throws {
        for mode in HotkeyTriggerMode.allCases {
            let combo = HotkeyCombo.default.withTriggerMode(mode)
            XCTAssertEqual(try JSONDecoder().decode(HotkeyCombo.self, from: JSONEncoder().encode(combo)), combo)
            XCTAssertEqual(HotkeyPresentation(combo: combo), HotkeyPresentation(combo: .default))
        }
    }

    func testChangingModeIsSavedAndConfirmedInSameTransaction() throws {
        let fixture = try OnboardingTestFixture()
        defer { fixture.cleanup() }
        let manager = HotkeyManager()
        manager.testInstallHandler = { _ in .success }
        _ = manager.register(hotkey: fixture.store.generalConfig.hotkey)
        for mode in [HotkeyTriggerMode.doublePress, .hold, .singlePress] {
            let combo = fixture.store.generalConfig.hotkey.withTriggerMode(mode)
            XCTAssertEqual(AppCoordinator.applyHotkey(combo, manager: manager, configStore: fixture.store), .success)
            let reloaded = ConfigStore(configDirectory: fixture.directory)
            XCTAssertEqual(reloaded.generalConfig.hotkey, combo)
            XCTAssertTrue(reloaded.onboardingProgress.hasConfirmedHotkey)
            XCTAssertEqual(manager.registeredHotkey, combo)
        }
    }

    func testFailedModeRegistrationRestoresPreviousMode() throws {
        let fixture = try OnboardingTestFixture()
        defer { fixture.cleanup() }
        let original = fixture.store.generalConfig.hotkey
        let manager = HotkeyManager()
        manager.testInstallHandler = { $0.triggerMode == .hold ? .failure("synthetic_conflict") : .success }
        _ = manager.register(hotkey: original)
        XCTAssertNotEqual(AppCoordinator.applyHotkey(original.withTriggerMode(.hold), manager: manager,
                                                     configStore: fixture.store), .success)
        XCTAssertEqual(manager.registeredHotkey, original)
        XCTAssertEqual(fixture.store.generalConfig.hotkey, original)
    }

    func testFailedModeConfirmationRestoresConfigurationAndListener() throws {
        let fixture = try OnboardingTestFixture()
        defer { fixture.cleanup() }
        try fixture.store.saveGeneralConfig(fixture.store.generalConfig, confirmingHotkey: true)
        let original = fixture.store.generalConfig.hotkey
        let manager = HotkeyManager()
        manager.testInstallHandler = { _ in .success }
        _ = manager.register(hotkey: original)
        let stateURL = fixture.directory.appendingPathComponent("state.json")
        try FileManager.default.removeItem(at: stateURL)
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: false)
        XCTAssertNotEqual(AppCoordinator.applyHotkey(original.withTriggerMode(.doublePress), manager: manager,
                                                     configStore: fixture.store), .success)
        XCTAssertEqual(manager.registeredHotkey, original)
        XCTAssertEqual(fixture.store.generalConfig.hotkey, original)
        XCTAssertTrue(fixture.store.onboardingProgress.hasConfirmedHotkey)
    }
}
