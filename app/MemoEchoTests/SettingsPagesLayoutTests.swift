import AppKit
import SwiftUI
import XCTest
@testable import MemoEcho

/// Real settings forms with temporary stores and stubbed permissions/providers.
@MainActor
final class SettingsPagesLayoutTests: XCTestCase {
    func testAllSettingsPagePairsKeepContentAtTopAndFitWindow() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        for source in SettingsTab.allCases {
            fixture.show(source)
            await settle(fixture)
            for destination in SettingsTab.allCases {
                fixture.show(destination)
                await settle(fixture)
                assertFits(fixture, scenario: "\(source) → \(destination)")
                fixture.show(source)
                await settle(fixture)
            }
        }
    }

    func testGeneralFunctionKeyHelpExpandsAndShrinksWindow() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.show(.general)
        await settle(fixture)
        let normalHeight = fixture.window.contentLayoutRect.height
        fixture.show(.permissions)
        await settle(fixture)
        var general = fixture.config.generalConfig
        general.hotkey = .special(modifiers: [HotkeyModifierSpec(key: .function)])
        try fixture.config.saveGeneralConfig(general)
        fixture.show(.general)
        await settle(fixture)
        assertFits(fixture, scenario: "Fn help shown")
        XCTAssertGreaterThan(fixture.window.contentLayoutRect.height, normalHeight)
        fixture.show(.dictionary)
        await settle(fixture)
        general.hotkey = .default
        try fixture.config.saveGeneralConfig(general)
        fixture.show(.general)
        await settle(fixture)
        assertFits(fixture, scenario: "Fn help removed")
        XCTAssertEqual(fixture.window.contentLayoutRect.height, normalHeight, accuracy: 0.5)
    }

    func testPermissionsStatusesAndGuideErrorResizeWithoutTopGap() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.show(.permissions)
        for microphone: MicrophonePermission in [.notDetermined, .denied, .restricted, .granted] {
            for accessibility: AccessibilityPermission in [.requiresManualEnable, .granted] {
                fixture.permissionState.microphone = microphone
                fixture.permissionState.accessibility = accessibility
                fixture.permissions.refreshAll()
                await settle(fixture)
                assertFits(fixture, scenario: "permissions \(microphone) / \(accessibility)")
            }
        }
        fixture.permissionState.accessibility = .requiresManualEnable
        fixture.permissions.refreshAll()
        await settle(fixture)
        let normalHeight = fixture.window.contentLayoutRect.height
        fixture.permissions.onAccessibilityGuideRequested = { false }
        fixture.permissions.promptAndOpenAccessibilitySettings()
        await settle(fixture)
        XCTAssertNotNil(fixture.permissions.accessibilityGuideError)
        XCTAssertGreaterThan(fixture.window.contentLayoutRect.height, normalHeight)
        assertFits(fixture, scenario: "guide error added")
        fixture.permissions.onAccessibilityGuideRequested = { true }
        fixture.permissions.promptAndOpenAccessibilitySettings()
        await settle(fixture)
        assertFits(fixture, scenario: "guide error removed")
        XCTAssertEqual(fixture.window.contentLayoutRect.height, normalHeight, accuracy: 0.5)
    }

    func testDictionaryEmptyAndLongPopulatedListHaveSameWindowHeight() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.show(.dictionary)
        await settle(fixture)
        assertFits(fixture, scenario: "empty dictionary")
        let emptyHeight = fixture.window.contentLayoutRect.height
        for index in 0..<20 {
            try fixture.dictionary.addEntry(.init(term: "布局验证词条\(index)"))
        }
        try fixture.dictionary.addEntry(.init(term: String(repeating: "长词条", count: 30)))
        await settle(fixture)
        assertFits(fixture, scenario: "dictionary overflow and long term")
        XCTAssertEqual(fixture.window.contentLayoutRect.height, emptyHeight, accuracy: 0.5)
    }

    func testClosingAndReopeningSameWindowKeepsEachPageFitted() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        for tab: SettingsTab in [.general, .dictionary, .permissions] {
            fixture.show(tab)
            await settle(fixture)
            let expectedHeight = fixture.window.contentLayoutRect.height
            fixture.window.close()
            fixture.window.orderFront(nil)
            await settle(fixture)
            assertFits(fixture, scenario: "reopen \(tab)")
            XCTAssertEqual(fixture.window.contentLayoutRect.height, expectedHeight, accuracy: 0.5)
        }
    }

    private func settle(_ fixture: Fixture) async {
        for _ in 0..<8 {
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func assertFits(_ fixture: Fixture, scenario: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        let frame = fixture.model.contentFrame
        XCTAssertGreaterThan(frame.height, 0, scenario, file: file, line: line)
        XCTAssertEqual(frame.minY, 0, accuracy: 0.5, scenario, file: file, line: line)
        XCTAssertEqual(frame.width, SettingsFormLayout.windowContentWidth, accuracy: 0.5,
                       scenario, file: file, line: line)
        XCTAssertEqual(fixture.window.contentLayoutRect.height, ceil(frame.height), accuracy: 0.5,
                       scenario, file: file, line: line)
        XCTAssertEqual(fixture.window.title, fixture.model.tab.title, scenario, file: file, line: line)
    }

    @MainActor @Observable final class Model {
        var tab: SettingsTab = .general
        var contentFrame = CGRect.zero
    }

    @MainActor final class PermissionState {
        var microphone: MicrophonePermission = .granted
        var accessibility: AccessibilityPermission = .granted
    }

    @MainActor private final class Fixture {
        let directory: URL
        let model = Model()
        let layout = SettingsWindowLayout()
        let permissionState = PermissionState()
        let config: ConfigStore
        let dictionary: PersonalDictionaryStore
        let permissions: PermissionsManager
        let updates = AppUpdateService()
        let modelList = LLMModelListService(fetcher: { _ in ["layout-test-model"] })
        let llmValidation = LLMValidationService(validator: { _, _ in })
        let download: ModelDownloadManager
        let cloudValidation: CloudASRValidationService
        var window: NSWindow!

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsPages-\(UUID())")
            config = ConfigStore(configDirectory: directory)
            dictionary = PersonalDictionaryStore(directoryURL: directory)
            try config.saveLLMConfig(.init(baseURL: "https://example.com/v1", model: "layout-test-model"),
                                     apiKey: "layout-test-key")
            permissions = PermissionsManager(operations: .init(
                microphoneStatus: { [permissionState] in permissionState.microphone },
                accessibilityStatus: { [permissionState] in permissionState.accessibility },
                requestMicrophone: {}, openMicrophoneSettings: {}, openAccessibilitySettings: {}
            ), accessibilityStatusQueryEnabled: true)
            download = ModelDownloadManager(configStore: config)
            cloudValidation = CloudASRValidationService(configStore: config, validatorFactory: { _ in ReadyCloud() })
            let host = SettingsWindowLayout.makeHostingController(rootView: Pages(fixture: self))
            window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.toolbarStyle = .preference
            window.toolbar = NSToolbar(identifier: "SettingsPagesLayoutTests")
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 576, height: 320))
            layout.attach(window)
        }

        func show(_ tab: SettingsTab) { layout.select(tab); model.tab = tab }
        func cleanup() {
            window.close()
            window.contentViewController = nil
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private struct Pages: View {
        let fixture: Fixture
        var body: some View {
            SettingsWindowContent(tab: fixture.model.tab, onMeasure: fixture.layout.measure) {
                SettingsPaneContainer {
                    switch fixture.model.tab {
                    case .general:
                        GeneralSettingsView(configStore: fixture.config, updateService: fixture.updates)
                    case .asr:
                        ASRSettingsView(configStore: fixture.config, downloadManager: fixture.download,
                                        validationService: fixture.cloudValidation)
                    case .ai:
                        LLMSettingsView(configStore: fixture.config, modelListService: fixture.modelList,
                                        validationService: fixture.llmValidation)
                    case .dictionary:
                        PersonalDictionarySettingsView(dictionaryStore: fixture.dictionary)
                    case .permissions:
                        PermissionsSettingsView(permissionsManager: fixture.permissions)
                    }
                }
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: FrameKey.self, value: proxy.frame(in: .named("viewport")))
                    }
                }
            }
            .coordinateSpace(name: "viewport")
            .onPreferenceChange(FrameKey.self) { fixture.model.contentFrame = $0 }
        }
    }

    private struct FrameKey: PreferenceKey {
        static let defaultValue = CGRect.zero
        static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
            let next = nextValue()
            if next != .zero { value = next }
        }
    }

    private struct ReadyCloud: CloudASRValidating {
        func validateCredentials() async throws {}
    }
}
