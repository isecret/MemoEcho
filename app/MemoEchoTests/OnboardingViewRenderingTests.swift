import AppKit
import SwiftUI
import XCTest
@testable import MemoEcho

/// These are layout smoke tests, not pixel-perfect snapshots. Their PNG artifacts are
/// intended for visual review and contain only isolated fixture configuration.
@MainActor
final class OnboardingViewRenderingTests: XCTestCase {
    func testOnboardingWindowKeepsNativeCenteredTitleWithoutSeparator() throws {
        let fixture = try OnboardingTestFixture()
        defer { fixture.cleanup() }
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let window = AppCoordinator.makeOnboardingWindow(coordinator: fixture.coordinator)
            defer { window.close() }
            window.appearance = NSAppearance(named: appearanceName)
            let content = try XCTUnwrap(window.contentView)
            let frameView = try XCTUnwrap(content.superview)
            frameView.layoutSubtreeIfNeeded()

            XCTAssertEqual(window.title, "设置 MemoEcho")
            XCTAssertEqual(window.titleVisibility, .hidden)
            XCTAssertEqual(window.toolbarStyle, .unifiedCompact)
            XCTAssertEqual(window.titlebarSeparatorStyle, .none)
            XCTAssertTrue(window.titlebarAppearsTransparent)
            XCTAssertEqual(content.bounds.width, 760, accuracy: 0.5)
            XCTAssertEqual(content.bounds.height, 660, accuracy: 0.5)
            XCTAssertEqual(window.styleMask, [.titled, .closable, .miniaturizable])
            XCTAssertNotNil(window.standardWindowButton(.closeButton))
            XCTAssertNotNil(window.standardWindowButton(.miniaturizeButton))

            let toolbar = try XCTUnwrap(window.toolbar)
            let titleItem = try XCTUnwrap(toolbar.items.first {
                toolbar.centeredItemIdentifiers.contains($0.itemIdentifier)
            })
            let title = try XCTUnwrap(titleItem.view as? NSTextField)
            XCTAssertEqual(title.stringValue, window.title)
            XCTAssertFalse(title.isEditable)
            XCTAssertFalse(titleItem.isBordered)
            XCTAssertFalse(toolbar.allowsUserCustomization)
            let titleFrame = title.convert(title.bounds, to: frameView)
            XCTAssertEqual(titleFrame.midX, frameView.bounds.midX, accuracy: 1,
                           "The title must be centered in the window, not placed beside the traffic lights")

            let bitmap = try XCTUnwrap(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
            frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("MemoEchoOnboardingPreviews", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let theme = appearanceName == .aqua ? "light" : "dark"
            try data.write(to: directory.appendingPathComponent("window-chrome-\(theme).png"))
        }
    }

    func testMicrophoneCopyMatchesSettingsForEveryAuthorizationState() {
        XCTAssertEqual(PermissionCopy.microphoneTitle, "麦克风权限")
        for (status, expected) in [
            (MicrophonePermission.notDetermined, "尚未请求"), (.granted, "已授权"),
            (.denied, "已拒绝"), (.restricted, "受限（由系统策略控制）"),
        ] {
            XCTAssertEqual(PermissionCopy.microphoneStatus(status), expected)
        }
        XCTAssertEqual(PermissionCopy.microphoneAction(.notDetermined), "请求权限")
        XCTAssertEqual(PermissionCopy.microphoneAction(.notDetermined, isRequesting: true), "请求中…")
        XCTAssertEqual(PermissionCopy.microphoneAction(.denied), "打开系统设置")
        XCTAssertNil(PermissionCopy.microphoneAction(.granted))
        XCTAssertNil(PermissionCopy.microphoneAction(.restricted))
    }

    func testAccessibilityCopyMatchesSettingsForEveryAuthorizationState() {
        XCTAssertEqual(PermissionCopy.accessibilityTitle, "辅助功能权限")
        XCTAssertEqual(PermissionCopy.accessibilityStatus(.granted), "已授权")
        XCTAssertEqual(PermissionCopy.accessibilityStatus(.unchecked), "未检查")
        XCTAssertEqual(PermissionCopy.accessibilityAction(.unchecked), "检查权限")
        XCTAssertEqual(PermissionCopy.accessibilityStatus(.requiresManualEnable), "未授权")
        XCTAssertEqual(PermissionCopy.accessibilityAction(.requiresManualEnable), "打开系统设置")
        XCTAssertNil(PermissionCopy.accessibilityAction(.granted))
    }

    func testEveryPermissionStateRendersInBothAppearances() throws {
        for microphone in [MicrophonePermission.notDetermined, .granted, .denied, .restricted] {
            let fixture = try OnboardingTestFixture(microphone: microphone, accessibility: .requiresManualEnable)
            defer { fixture.cleanup() }
            fixture.coordinator.go(to: .permissions)
            for (scheme, appearance, theme) in [
                (ColorScheme.light, NSAppearance.Name.aqua, "light"),
                (ColorScheme.dark, NSAppearance.Name.darkAqua, "dark"),
            ] {
                try capture(OnboardingView(coordinator: fixture.coordinator).environment(\.colorScheme, scheme),
                            appearanceName: appearance, name: "permissions-\(microphone.rawValue)-\(theme)",
                            size: NSSize(width: 760, height: 660))
            }
        }
    }

    func testConfigurationSummaryStaysOnOneLineWithOptionalEditAction() throws {
        for editable in [false, true] {
            let summary = OnboardingConfigurationSummary(onChange: editable ? {} : nil)
                .frame(width: 550)
            let size = NSHostingView(rootView: summary).fittingSize
            XCTAssertEqual(size.width, 550, accuracy: 0.5)
            XCTAssertLessThanOrEqual(size.height, 24, "Status and edit action must stay on one line")
            try capture(summary.frame(height: 40).background(Color(nsColor: .windowBackgroundColor)),
                        appearanceName: .aqua, name: editable ? "summary-editable" : "summary-local",
                        size: NSSize(width: 550, height: 40))
        }
    }

    func testModelDownloadProgressUsesCompactWidthWithinOnboardingCopyRegion() {
        let view = NSHostingView(rootView: OnboardingDownloadProgress(progress: 0.95))
        XCTAssertEqual(view.fittingSize.width, 220, accuracy: 1)
        XCTAssertLessThan(view.fittingSize.width, 550 / 2)
    }

    func testDemoCopyMatchesApprovedConversationAndSelfCorrectionExample() {
        XCTAssertEqual(OnboardingDemoCopy.question, "关于记录灵感的工具，你有什么想法吗？")
        XCTAssertEqual(OnboardingDemoCopy.originalText, "嗯…我觉得先把分类做起来，啊不对，先把语音入口做起来吧，让记录更顺手。用户想到什么，嗯，那个，就先记录，不管是笔记、任务还是想法，都先记下来，然后至于后面怎么理解、分类和整理，呃，就是交给 AI 就好了。")
        XCTAssertEqual(OnboardingDemoCopy.reply, "我觉得先把语音入口做起来，让记录更顺手。用户想到什么就先记录，不管是笔记、任务还是想法，都先记下来，至于后面怎么理解、分类和整理，交给 AI 就好了。")
        XCTAssertEqual(SetupStep.llm.subtitle, "删掉口头禅，保留你改口后的想法。")
    }

    func testModelExampleOnlyHighlightsTheFinalDecision() {
        let text = OnboardingDemoCopy.highlightedReply
        XCTAssertEqual(String(text.characters), OnboardingDemoCopy.reply,
                       "Highlighting must not add, remove, or rewrite the approved reply")
        let highlighted = text.runs.filter { $0.backgroundColor != nil }
        XCTAssertEqual(highlighted.map { String(text[$0.range].characters) },
                       ["先把语音入口做起来"])
        for run in highlighted {
            XCTAssertEqual(run.foregroundColor, Color.accentColor)
            XCTAssertEqual(run.backgroundColor, Color.accentColor.opacity(0.14))
        }
        for run in text.runs where run.backgroundColor == nil {
            XCTAssertNil(run.foregroundColor, "Unchanged copy must keep its normal text styling")
        }
    }

    func testModelExampleMarksSelfCorrectionAndDeletedFillerInOriginalText() {
        let text = OnboardingDemoCopy.highlightedOriginalText
        XCTAssertEqual(String(text.characters), OnboardingDemoCopy.originalText,
                       "Deletion markers must preserve the complete original transcription")
        let deleted = text.runs.filter { $0.strikethroughStyle != nil }
        XCTAssertEqual(deleted.map { String(text[$0.range].characters) },
                       ["嗯…", "先把分类做起来，啊不对，", "吧", "，嗯，那个，", "然后", "呃，就是"],
                       "Mark the rejected first idea and every removed filler")
        for run in deleted {
            XCTAssertEqual(run.strikethroughStyle, Text.LineStyle.single)
            XCTAssertEqual(run.foregroundColor, Color.red)
            XCTAssertEqual(run.backgroundColor, Color.red.opacity(0.08))
        }
        for run in text.runs where run.strikethroughStyle == nil {
            XCTAssertNil(run.foregroundColor)
            XCTAssertNil(run.backgroundColor)
        }
        let retainedText = text.runs.filter { $0.strikethroughStyle == nil }
            .map { String(text[$0.range].characters) }.joined()
        XCTAssertEqual(retainedText, OnboardingDemoCopy.reply,
                       "Removing only the marked spans must produce the shared polished reply")
        for phrase in OnboardingDemoCopy.deletedOriginalPhrases {
            XCTAssertTrue(OnboardingDemoCopy.originalAccessibilityLabel.contains("“\(phrase)”"))
        }
        XCTAssertTrue(OnboardingDemoCopy.originalAccessibilityLabel.contains("改口后的想法"))
        XCTAssertFalse(OnboardingDemoCopy.highlightedReply.runs.contains { $0.strikethroughStyle != nil },
                       "The polished result must not include deleted words or deletion markers")
    }

    func testEveryStepRendersInLightAppearance() async throws {
        try await renderSteps(colorScheme: .light, appearanceName: .aqua, theme: "light")
    }

    func testEveryStepRendersInDarkAppearance() async throws {
        try await renderSteps(colorScheme: .dark, appearanceName: .darkAqua, theme: "dark")
    }

    func testReadyTrialRendersWithoutShortcutDecoration() async throws {
        try await renderSteps(colorScheme: .light, appearanceName: .aqua, theme: "ready-light", readyTrial: true)
        try await renderSteps(colorScheme: .dark, appearanceName: .darkAqua, theme: "ready-dark", readyTrial: true)
    }

    func testConfiguredStepsRenderTheirCopyAndActionsInBothAppearances() async throws {
        let fixture = try OnboardingTestFixture()
        defer { fixture.cleanup() }
        try await fixture.makeReady()
        try fixture.store.saveOnboardingProgress(.init(hasConfirmedHotkey: true))
        for (scheme, appearance, theme) in [
            (ColorScheme.light, NSAppearance.Name.aqua, "light"),
            (ColorScheme.dark, NSAppearance.Name.darkAqua, "dark"),
        ] {
            for step in [SetupStep.asr, .llm, .permissions, .hotkey] {
                fixture.coordinator.go(to: step)
                try capture(OnboardingView(coordinator: fixture.coordinator).environment(\.colorScheme, scheme),
                            appearanceName: appearance, name: "configured-\(theme)-\(step.rawValue)",
                            size: NSSize(width: 760, height: 660))
            }
        }
    }

    func testModelValidationStatesRenderWithoutMovingTheFooter() async throws {
        let fixture = try OnboardingTestFixture()
        defer { fixture.cleanup() }
        try await fixture.makeReady()
        fixture.coordinator.go(to: .llm)
        fixture.coordinator.llmValidationService.invalidateCurrentValidation()

        for state in ["failed", "checking"] {
            if state == "checking" {
                fixture.coordinator.retryCurrentValidation()
                XCTAssertEqual(fixture.coordinator.llmValidationService.status, .checking)
            } else {
                XCTAssertEqual(fixture.coordinator.llmValidationService.status, .failed)
            }
            // Synchronous rendering keeps the injected validator pending without a live request.
            for (scheme, appearance, theme) in [
                (ColorScheme.light, NSAppearance.Name.aqua, "light"),
                (ColorScheme.dark, NSAppearance.Name.darkAqua, "dark"),
            ] {
                try capture(OnboardingView(coordinator: fixture.coordinator).environment(\.colorScheme, scheme),
                            appearanceName: appearance, name: "model-\(state)-\(theme)",
                            size: NSSize(width: 760, height: 660))
            }
        }
    }

    func testPermissionAndFunctionKeyHintsFitTheCopyRegion() async throws {
        let restricted = try OnboardingTestFixture(microphone: .restricted)
        defer { restricted.cleanup() }
        restricted.coordinator.go(to: .permissions)
        try capture(OnboardingView(coordinator: restricted.coordinator), appearanceName: .aqua,
                    name: "restricted-permissions", size: NSSize(width: 760, height: 660))

        let ready = try OnboardingTestFixture()
        defer { ready.cleanup() }
        try await ready.makeReady()
        var general = ready.store.generalConfig
        general.hotkey = .special(modifiers: [.init(key: .function)])
        try ready.store.saveGeneralConfig(general, confirmingHotkey: true)
        ready.coordinator.go(to: .hotkey)
        try capture(OnboardingView(coordinator: ready.coordinator), appearanceName: .aqua,
                    name: "function-hotkey-hint", size: NSSize(width: 760, height: 660))
    }

    func testLongRecoveryCopyScrollsWithoutExpandingThePage() throws {
        let fixture = try OnboardingTestFixture(microphone: .denied, accessibility: .requiresManualEnable)
        defer { fixture.cleanup() }
        var asr = fixture.store.asrConfig
        asr.selectedPlatform = .tencentCloudRealtime
        try fixture.store.saveASRConfig(asr)
        let longReason = String(repeating: "快捷键暂时不可用，请检查系统设置后重试。", count: 8)
        fixture.readinessService.hotkeyRegistrationResult = .failure(longReason)
        fixture.coordinator.go(to: .tryIt)
        let readiness = fixture.coordinator.readiness
        XCTAssertTrue([readiness.asr, readiness.llm, readiness.microphone, readiness.accessibility, readiness.hotkey]
            .allSatisfy { !$0.isReady })
        fixture.coordinator.onApplyHotkey = { _ in .failure(longReason) }
        XCTAssertFalse(fixture.coordinator.applyHotkey(fixture.store.generalConfig.hotkey))

        try capture(OnboardingView(coordinator: fixture.coordinator), appearanceName: .aqua,
                    name: "long-recovery-copy", size: NSSize(width: 760, height: 660)) { view in
            let scrollView = try XCTUnwrap(self.descendants(of: view).compactMap { $0 as? NSScrollView }.first {
                guard let document = $0.documentView else { return false }
                return !(document is NSTextView) && !self.descendants(of: document).contains { $0 is NSTextView }
            }, "Overflowing recovery text must scroll independently of the trial editor")
            let document = try XCTUnwrap(scrollView.documentView)
            XCTAssertLessThanOrEqual(scrollView.frame.height, 158.5)
            XCTAssertGreaterThan(document.bounds.height, scrollView.contentSize.height)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height - scrollView.contentSize.height))
            XCTAssertGreaterThan(scrollView.contentView.bounds.origin.y, 0)
        }
    }

    func testDemoBackgroundsAreBundledAndDistinct() throws {
        var images = Set<Data>()
        for asset in OnboardingDemoBackground.allCases {
            let background = try XCTUnwrap(NSImage(named: asset.rawValue),
                                          "Every demo needs its own bundled background: \(asset)")
            XCTAssertGreaterThanOrEqual(background.size.width / background.size.height, 1.6)
            images.insert(try XCTUnwrap(background.tiffRepresentation))
        }
        XCTAssertEqual(images.count, 4, "Do not reuse or rename the same image across the four demos")
    }

    func testWelcomeSequenceRendersEachStageAndLoops() throws {
        XCTAssertNotNil(NSImage(named: "OnboardingAvatar"), "The supplied avatar must be bundled, not loaded from a developer's photo library")
        let frames: [(TimeInterval, OnboardingWelcomePhase)] = [
            (0.2, .waiting), (0.8, .pending), (2, .recording),
            (4.8, .thinking), (7, .filled), (9.2, .waiting),
        ]
        for (time, expected) in frames {
            XCTAssertEqual(OnboardingWelcomePhase.at(time), expected)
        }
        for (colorScheme, appearanceName, theme) in [
            (ColorScheme.light, NSAppearance.Name.aqua, "light"),
            (ColorScheme.dark, NSAppearance.Name.darkAqua, "dark"),
        ] {
            for phase in OnboardingWelcomePhase.allCases {
                let view = OnboardingDemoStage(background: .welcome, alignment: .top) {
                    OnboardingWelcomeScene(phase: phase)
                }
                    .frame(width: 760, height: 390)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, colorScheme)
                try capture(view, appearanceName: appearanceName, name: "\(theme)-welcome-\(phase)",
                            size: NSSize(width: 760, height: 390))
            }
        }
    }

    func testWelcomeSceneKeepsSameSizeAcrossHUDStages() {
        let sizes = OnboardingWelcomePhase.allCases.map { phase in
            NSHostingView(rootView: OnboardingDemoStage(background: .welcome, alignment: .top) {
                OnboardingWelcomeScene(phase: phase)
            }).fittingSize
        }
        XCTAssertEqual(sizes[0].width, 640, accuracy: 0.5)
        XCTAssertEqual(sizes[0].height, 366, accuracy: 0.5)
        for size in sizes.dropFirst() {
            XCTAssertEqual(size.width, sizes[0].width, accuracy: 0.5)
            XCTAssertEqual(size.height, sizes[0].height, accuracy: 0.5,
                           "Showing or hiding the HUD must not move the chat composer")
        }
    }

    func testWelcomeChatCardKeepsItsOwnBoundsAcrossHUDStages() {
        for phase in OnboardingWelcomePhase.allCases {
            let size = NSHostingView(rootView: OnboardingWelcomeScene(phase: phase)).fittingSize
            XCTAssertEqual(size.width, 550, accuracy: 0.5)
            XCTAssertEqual(size.height, 326, accuracy: 0.5)
        }
    }

    func testTrialEditorHidesScrollbarsButKeepsLongResultsScrollable() async throws {
        let fixture = try OnboardingTestFixture()
        defer { fixture.cleanup() }
        try await fixture.makeReady()
        try fixture.store.saveOnboardingProgress(.init(lastVisitedStep: .tryIt, hasConfirmedHotkey: true))
        fixture.coordinator.prepareForPresentation(at: .tryIt)
        for (name, text) in [("empty", ""), ("long", String(repeating: "这是试用文本。\n", count: 50))] {
            fixture.coordinator.trialText = text
            try capture(OnboardingView(coordinator: fixture.coordinator), appearanceName: .aqua,
                        name: "trial-editor-\(name)", size: NSSize(width: 760, height: 660)) { view in
                let editor = try XCTUnwrap(self.descendants(of: view).compactMap { $0 as? NSTextView }.first)
                let scrollView = try XCTUnwrap(editor.enclosingScrollView)
                // Exercise the always-visible system scrollbar style without changing user defaults.
                scrollView.scrollerStyle = .legacy
                scrollView.layoutSubtreeIfNeeded()
                XCTAssertEqual(editor.string, text)
                XCTAssertTrue(!scrollView.hasVerticalScroller || scrollView.verticalScroller?.isHidden == true)
                XCTAssertTrue(!scrollView.hasHorizontalScroller || scrollView.horizontalScroller?.isHidden == true)
                XCTAssertLessThanOrEqual(scrollView.frame.height, 140)
                if !text.isEmpty {
                    XCTAssertGreaterThan(editor.bounds.height, scrollView.contentSize.height)
                    editor.scrollRangeToVisible(NSRange(location: (text as NSString).length, length: 0))
                    XCTAssertGreaterThan(scrollView.contentView.bounds.origin.y, 0,
                                         "Long trial results must remain reachable without scrollbar controls")
                }
            }
        }
    }

    func testReadyTrialFocusesEditorWhenEnteredAndReopened() async throws {
        let fixture = try OnboardingTestFixture()
        defer { fixture.cleanup() }
        try await fixture.makeReady()
        try fixture.store.saveOnboardingProgress(.init(hasConfirmedHotkey: true))
        fixture.coordinator.prepareForPresentation(at: .hotkey)

        let hostingView = NSHostingView(rootView: OnboardingView(coordinator: fixture.coordinator))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 660),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        defer { window.close() }

        for visit in 0..<2 {
            if visit == 0 {
                fixture.coordinator.go(to: .tryIt)
            } else {
                fixture.coordinator.dismissed()
                window.makeFirstResponder(nil)
                // The actual app keeps the same hosting view when the guide is closed.
                await Task.yield()
                fixture.coordinator.prepareForPresentation(at: .tryIt)
            }
            for _ in 0..<100 {
                hostingView.layoutSubtreeIfNeeded()
                if window.firstResponder is NSTextView { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let editor = try XCTUnwrap(window.firstResponder as? NSTextView,
                                      "Entering the ready trial must focus its editor without an extra click")
            XCTAssertTrue(descendants(of: hostingView).contains { $0 === editor })
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func renderSteps(
        colorScheme: ColorScheme,
        appearanceName: NSAppearance.Name,
        theme: String,
        readyTrial: Bool = false
    ) async throws {
        for step in (readyTrial ? [.tryIt] : SetupStep.allCases) {
            let fixture = try OnboardingTestFixture()
            defer { fixture.cleanup() }
            if readyTrial {
                try await fixture.makeReady()
                var general = fixture.store.generalConfig
                general.hotkey = .special(modifiers: [.init(key: .command, side: .right)])
                try fixture.store.saveGeneralConfig(general, confirmingHotkey: true)
                fixture.coordinator.refresh()
                XCTAssertTrue(fixture.coordinator.readiness.isReady)
            }
            fixture.coordinator.go(to: step)
            let view = OnboardingView(coordinator: fixture.coordinator)
                .environment(\.colorScheme, colorScheme)
            try capture(view, appearanceName: appearanceName, name: "\(theme)-\(step.rawValue)",
                        size: NSSize(width: 760, height: 660))
        }
    }

    private func capture(
        _ view: some View, appearanceName: NSAppearance.Name, name: String, size: NSSize,
        validate: (NSView) throws -> Void = { _ in }
    ) throws {
        let outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MemoEchoOnboardingPreviews", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
        try XCTContext.runActivity(named: name) { activity in
            let hostingView = NSHostingView(rootView: view)
            let bounds = NSRect(origin: .zero, size: size)
            hostingView.frame = bounds
            hostingView.appearance = appearance

            // Hidden windows provide layout without activating the app or needing screen capture.
            let window = NSWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = appearance
            window.contentView = hostingView
            defer { window.close() }
            hostingView.layoutSubtreeIfNeeded()
            try validate(hostingView)

            XCTAssertEqual(hostingView.fittingSize.width, bounds.width, accuracy: 0.5)
            XCTAssertEqual(hostingView.fittingSize.height, bounds.height, accuracy: 0.5)
            let bitmap = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
            appearance.performAsCurrentDrawingAppearance {
                hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
            }
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 4_096, "The rendered page should contain more than an empty surface.")
            try png.write(to: outputDirectory.appendingPathComponent("\(name).png"), options: .atomic)
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = name
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
    }
}
