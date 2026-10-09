import AppKit
import SwiftUI
import XCTest
@testable import MemoEcho

@MainActor
final class HUDFeedbackControllerTests: XCTestCase {
    private final class MockFeedbackSoundPlayer: FeedbackSoundPlaying {
        var startCount = 0
        var stopCount = 0
        func playStart() { startCount += 1 }
        func playStop() { stopCount += 1 }
    }

    func testMissingSignalKeepsRecordingControlsAndDoesNotPlaySounds() {
        let sounds = MockFeedbackSoundPlayer()
        let controller = HUDFeedbackController(soundPlayer: sounds)
        controller.handleEvent(.recordingStarted)
        controller.handleEvent(.recordingSignalChanged(missing: true))
        XCTAssertEqual(controller.hudState, .recording)
        XCTAssertTrue(controller.recordingSignalMissing)
        controller.handleEvent(.modeSwitched(.translate))
        XCTAssertTrue(controller.recordingSignalMissing)
        controller.handleEvent(.recordingSignalChanged(missing: false))
        XCTAssertFalse(controller.recordingSignalMissing)
        XCTAssertEqual(sounds.startCount, 0)
        XCTAssertEqual(sounds.stopCount, 0)
        controller.handleEvent(.processingCancelled)
    }

    func testRecoveryShowsProcessingWithoutRecordingSounds() {
        let sounds = MockFeedbackSoundPlayer()
        let controller = HUDFeedbackController(soundPlayer: sounds)
        controller.handleEvent(.recoveryStarted)
        XCTAssertEqual(controller.hudState, .processing)
        XCTAssertTrue(controller.isHUDPresented)
        XCTAssertEqual(sounds.startCount, 0)
        XCTAssertEqual(sounds.stopCount, 0)
        controller.handleEvent(.processingCancelled)
    }

    func testRecoveryActionOnlyRunsInFailureStateAndFitsHUD() {
        let controller = HUDFeedbackController(soundPlayer: MockFeedbackSoundPlayer())
        var calls = 0
        controller.recoveryActionTitle = "重试翻译"
        controller.onRecoveryAction = { calls += 1 }
        controller.performRecoveryAction()
        XCTAssertEqual(calls, 0)
        controller.handleEvent(.processingFailed(.translationFailed))
        controller.performRecoveryAction()
        XCTAssertEqual(calls, 1)
        controller.performRecoveryAction()
        XCTAssertEqual(calls, 1, "Recovery is consumed before invoking its callback")
        controller.clearRecoveryAction()
        controller.performRecoveryAction()
        XCTAssertEqual(calls, 1)
        controller.handleEvent(.processingCancelled)
    }

    func testCopyConfirmationClearsActionAndShowsAcknowledgement() {
        let controller = HUDFeedbackController(soundPlayer: MockFeedbackSoundPlayer())
        controller.recoveryActionTitle = "复制结果"
        controller.handleEvent(.processingFailed(.injectionFailed))
        controller.showCopyConfirmation()
        XCTAssertEqual(controller.hudState, .notice("已复制"))
        XCTAssertTrue(controller.isCopyConfirmation)
        XCTAssertEqual(controller.presentation.dismissSeconds, 1.2)
        XCTAssertNil(controller.recoveryActionTitle)
        XCTAssertNil(controller.onRecoveryAction)
        controller.handleEvent(.processingCancelled)
    }

    func testFailureEventPresentsHUDWhenHidden() {
        let controller = HUDFeedbackController()

        XCTAssertEqual(controller.hudState, .hidden)
        XCTAssertFalse(controller.isHUDPresented)

        controller.handleEvent(.processingFailed(.permissionDenied))

        XCTAssertEqual(controller.hudState, .failure(.permissionDenied))
        XCTAssertTrue(controller.isHUDPresented)
    }

    func testHotkeyCandidatePresentsIdleHUDWithoutRecordingSideEffects() {
        let soundPlayer = MockFeedbackSoundPlayer()
        let controller = HUDFeedbackController(soundPlayer: soundPlayer)
        controller.audioLevelProvider = { 1 }

        controller.presentHotkeyCandidate()

        XCTAssertEqual(controller.hudState, .hotkeyPending)
        XCTAssertTrue(controller.isHUDPresented)
        XCTAssertEqual(controller.barHeights, Array(repeating: HUDLayout.resetBarHeight, count: 7))
        XCTAssertEqual(soundPlayer.startCount, 0)
    }

    func testCancellingHotkeyCandidateDismissesHUD() async {
        let controller = HUDFeedbackController()
        controller.presentHotkeyCandidate()

        controller.dismissHotkeyCandidate()
        await waitForHUDToHide(controller)

        XCTAssertEqual(controller.hudState, .hidden)
        XCTAssertFalse(controller.isHUDPresented)
    }

    func testRecordingCanStartFromHotkeyCandidateHUD() {
        let controller = HUDFeedbackController()
        controller.presentHotkeyCandidate()

        controller.handleEvent(.recordingStarted)

        XCTAssertEqual(controller.hudState, .recording)
        XCTAssertTrue(controller.isHUDPresented)
        controller.handleEvent(.processingCancelled)
    }

    func testRecordingHUDStaysVisibleWhenCandidateWasJustDismissed() async throws {
        let previousWindows = Set(NSApp.windows.map(\.windowNumber))
        let controller = HUDFeedbackController(soundPlayer: MockFeedbackSoundPlayer())
        controller.presentHotkeyCandidate()
        let window = try XCTUnwrap(NSApp.windows.first {
            $0 is HUDWindow && !previousWindows.contains($0.windowNumber)
        })
        try await Task.sleep(for: .milliseconds(250))

        // Match AppCoordinator's clean modifier-release path: candidate dismissal
        // is immediately followed by the session's recordingStarted event.
        controller.dismissHotkeyCandidate()
        controller.handleEvent(.recordingStarted)
        try await Task.sleep(for: .milliseconds(350))

        XCTAssertEqual(controller.hudState, .recording)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.alphaValue, 1, accuracy: 0.01, "An old fade-out must not make the recording HUD transparent")
        controller.handleEvent(.processingCancelled)
        await waitForHUDToHide(controller)
    }

    func testRecordingEventsDoNotInterruptHUDFadeIn() async throws {
        for event: SessionFeedbackEvent in [.startSoundCue(delayMs: 0), .modeSwitched(.translate), .recordingStopped] {
            let previousWindows = Set(NSApp.windows.map(\.windowNumber))
            let controller = HUDFeedbackController(soundPlayer: MockFeedbackSoundPlayer())
            controller.handleEvent(.recordingStarted)
            let window = try XCTUnwrap(NSApp.windows.first {
                $0 is HUDWindow && !previousWindows.contains($0.windowNumber)
            })

            // These events may arrive before the 200 ms fade-in has completed.
            controller.handleEvent(event)
            try await Task.sleep(for: .milliseconds(350))

            XCTAssertTrue(window.isVisible)
            XCTAssertEqual(window.alphaValue, 1, accuracy: 0.01,
                           "\(event) must not leave the HUD partially transparent")
            controller.handleEvent(.processingCancelled)
            await waitForHUDToHide(controller)
        }
    }

    func testLateCandidateCancellationDoesNotDismissRecordingHUD() {
        let controller = HUDFeedbackController()
        controller.presentHotkeyCandidate()
        controller.handleEvent(.recordingStarted)

        controller.dismissHotkeyCandidate()

        XCTAssertEqual(controller.hudState, .recording)
        XCTAssertTrue(controller.isHUDPresented)
        controller.handleEvent(.processingCancelled)
    }

    func testFailureEventStopsRecordingPresentationSideEffects() {
        let controller = HUDFeedbackController()

        controller.handleEvent(.recordingStarted)
        XCTAssertEqual(controller.hudState, .recording)
        XCTAssertTrue(controller.isHUDPresented)

        controller.handleEvent(.processingFailed(.permissionDenied))

        XCTAssertEqual(controller.hudState, .failure(.permissionDenied))
        XCTAssertTrue(controller.isHUDPresented)
        XCTAssertEqual(controller.barHeights, Array(repeating: HUDLayout.resetBarHeight, count: 7))
    }

    func testInteractionSoundDisabledSkipsStartAndStopPlayback() {
        let soundPlayer = MockFeedbackSoundPlayer()
        let controller = HUDFeedbackController(soundPlayer: soundPlayer)
        controller.isInteractionSoundEnabled = { false }

        controller.handleEvent(.startSoundCue(delayMs: 0))
        controller.handleEvent(.recordingStopped)

        XCTAssertEqual(soundPlayer.startCount, 0)
        XCTAssertEqual(soundPlayer.stopCount, 0)
    }

    func testInteractionSoundEnabledPlaysStartAndStopSounds() async {
        let soundPlayer = MockFeedbackSoundPlayer()
        let controller = HUDFeedbackController(soundPlayer: soundPlayer)
        controller.isInteractionSoundEnabled = { true }

        controller.handleEvent(.recordingStarted)
        controller.handleEvent(.startSoundCue(delayMs: 0))
        await waitForStartSound(soundPlayer)
        controller.handleEvent(.recordingStopped)

        XCTAssertEqual(soundPlayer.startCount, 1)
        XCTAssertEqual(soundPlayer.stopCount, 1)
    }

    func testStoppingRecordingCancelsPendingStartSound() async {
        let soundPlayer = MockFeedbackSoundPlayer()
        let controller = HUDFeedbackController(soundPlayer: soundPlayer)
        controller.isInteractionSoundEnabled = { true }
        controller.handleEvent(.recordingStarted)
        controller.handleEvent(.startSoundCue(delayMs: 200))
        await Task.yield()
        controller.handleEvent(.recordingStopped)
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(soundPlayer.startCount, 0)
        XCTAssertEqual(soundPlayer.stopCount, 1)
    }

    func testDelayedStartPlaysOnceAndRespectsSoundToggle() async {
        let player = MockFeedbackSoundPlayer()
        let controller = HUDFeedbackController(soundPlayer: player)
        var enabled = true
        controller.isInteractionSoundEnabled = { enabled }
        controller.handleEvent(.recordingStarted)
        controller.handleEvent(.startSoundCue(delayMs: 60))
        await Task.yield()
        XCTAssertEqual(player.startCount, 0)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(player.startCount, 1)
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(player.startCount, 1, "No automatic retry")
        controller.handleEvent(.startSoundCue(delayMs: 60))
        enabled = false
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(player.startCount, 1)
        controller.handleEvent(.processingCancelled)
    }

    func testModeSwitchCueKeepsRecordingState() {
        let controller = HUDFeedbackController()

        controller.handleEvent(.recordingStarted)
        controller.handleEvent(.modeSwitched(.translate))

        XCTAssertEqual(controller.hudState, .recording)
        XCTAssertEqual(controller.modeCueLabel, "TRANSLATE")
    }

    func testConsecutiveModeSwitchCueShowsLatestLabel() async {
        let controller = HUDFeedbackController(modeCueDuration: .milliseconds(10))

        controller.handleEvent(.recordingStarted)
        controller.handleEvent(.modeSwitched(.translate))
        controller.handleEvent(.modeSwitched(.polish))

        XCTAssertEqual(controller.hudState, .recording)
        XCTAssertEqual(controller.modeCueLabel, "DICTATE")

        await waitForModeCueToClear(controller)

        XCTAssertEqual(controller.hudState, .recording)
        XCTAssertNil(controller.modeCueLabel)
    }

    func testStoppingRecordingClearsModeCue() {
        let controller = HUDFeedbackController()

        controller.handleEvent(.recordingStarted)
        controller.handleEvent(.modeSwitched(.translate))
        controller.handleEvent(.recordingStopped)

        XCTAssertEqual(controller.hudState, .processing)
        XCTAssertNil(controller.modeCueLabel)
    }

    func testUnverifiedPasteDismissesHUDWithoutNoticeOrRetryAction() async {
        let controller = HUDFeedbackController()
        controller.handleEvent(.recoveryStarted)
        controller.recoveryActionTitle = "重试写入"
        controller.onRecoveryAction = {}
        controller.handleEvent(.outputDispatched)
        XCTAssertEqual(controller.hudState, .processing, "Dismiss without flashing a result notice")
        XCTAssertNil(controller.recoveryActionTitle)
        XCTAssertNil(controller.onRecoveryAction)
        await waitForHUDToHide(controller)
        XCTAssertEqual(controller.hudState, .hidden)
        XCTAssertFalse(controller.isHUDPresented)
    }

    func testProcessingFinishedDismissesHUDWithoutSuccessState() async {
        let controller = HUDFeedbackController()

        controller.handleEvent(.recordingStarted)
        controller.handleEvent(.recordingStopped)
        controller.handleEvent(.processingFinished)

        await waitForHUDToHide(controller)

        XCTAssertEqual(controller.hudState, .hidden)
        XCTAssertFalse(controller.isHUDPresented)
    }

    func testProcessingCancelledDismissesHUDWithoutCancelledState() async {
        let controller = HUDFeedbackController()

        controller.handleEvent(.recordingStarted)
        controller.handleEvent(.recordingStopped)
        controller.handleEvent(.processingCancelled)

        await waitForHUDToHide(controller)

        XCTAssertEqual(controller.hudState, .hidden)
        XCTAssertFalse(controller.isHUDPresented)
    }

    func testProcessingCancelledFromRecordingDismissesHUD() async {
        let controller = HUDFeedbackController()

        controller.handleEvent(.recordingStarted)
        controller.handleEvent(.processingCancelled)

        await waitForHUDToHide(controller)

        XCTAssertEqual(controller.hudState, .hidden)
        XCTAssertFalse(controller.isHUDPresented)
    }

    func testDictionaryTermLearnedShowsNoticeHUD() {
        let controller = HUDFeedbackController()

        controller.handleEvent(.dictionaryTermLearned("朴邻"))

        XCTAssertEqual(controller.hudState, .notice("朴邻"))
        XCTAssertTrue(controller.isHUDPresented)
    }

    func testDictionaryTermLearnedPreservesFullDisplayText() {
        let controller = HUDFeedbackController()

        controller.handleEvent(.dictionaryTermLearned("客户成功部"))

        XCTAssertEqual(controller.hudState, .notice("客户成功部"))
        controller.handleEvent(.dictionaryTermLearned("已复制"))
        XCTAssertFalse(controller.isCopyConfirmation, "A dictionary term is not a copy acknowledgement")
        XCTAssertEqual(controller.presentation.dismissSeconds, 2.4)
        controller.handleEvent(.processingCancelled)
    }

    func testDictionaryTermLearnedUsesExtendedDefaultDismissDuration() {
        XCTAssertEqual(HUDFeedbackController.defaultLearnedTermNoticeDismissSeconds, 2.4, accuracy: 0.001)
    }

    func testRecordingWaveformStaysLowBelowDisplayThreshold() async {
        let controller = HUDFeedbackController()
        controller.audioLevelProvider = { 0.05 }

        controller.handleEvent(.recordingStarted)
        await waitForWaveformUpdate(controller)

        let maxHeight = controller.barHeights.max() ?? 0
        XCTAssertLessThan(maxHeight, HUDLayout.waveformMaxHeight * 0.45)

        controller.handleEvent(.processingCancelled)
    }

    func testRecordingWaveformExpandsToCenterHighWhenLevelExceedsThreshold() async {
        let controller = HUDFeedbackController()
        controller.audioLevelProvider = { 0.2 }

        controller.handleEvent(.recordingStarted)
        await waitForWaveform(
            controller,
            matching: { heights in
                heights[3] > HUDLayout.waveformMaxHeight * 0.9
            }
        )

        XCTAssertGreaterThan(controller.barHeights[3], controller.barHeights[2])
        XCTAssertGreaterThan(controller.barHeights[2], controller.barHeights[1])
        XCTAssertGreaterThan(controller.barHeights[1], controller.barHeights[0])
        XCTAssertLessThan(abs(controller.barHeights[0] - controller.barHeights[6]), 1.0)
        XCTAssertLessThan(abs(controller.barHeights[1] - controller.barHeights[5]), 1.0)
        XCTAssertLessThan(abs(controller.barHeights[2] - controller.barHeights[4]), 1.0)

        controller.handleEvent(.processingCancelled)
    }

    func testRecordingWaveformFallsBackSmoothlyAfterVoiceDrops() async {
        let controller = HUDFeedbackController()
        var level: Float = 0.2
        controller.audioLevelProvider = { level }

        controller.handleEvent(.recordingStarted)
        await waitForWaveform(
            controller,
            matching: { heights in
                heights[3] > HUDLayout.waveformMaxHeight * 0.9
            }
        )

        level = 0
        try? await Task.sleep(for: .milliseconds(20))
        let shortlyAfterDrop = controller.barHeights[3]
        XCTAssertGreaterThan(shortlyAfterDrop, HUDLayout.resetBarHeight)

        await waitForWaveform(
            controller,
            matching: { heights in
                heights[3] < shortlyAfterDrop && heights[3] < HUDLayout.waveformMaxHeight * 0.7
            }
        )
        XCTAssertLessThan(controller.barHeights[3], HUDLayout.waveformMaxHeight * 0.7)

        controller.handleEvent(.processingCancelled)
    }

    func testLateDictionaryNoticesNeverPreemptActiveSessionOrFailure() {
        let controller = HUDFeedbackController(soundPlayer: MockFeedbackSoundPlayer())
        controller.handleEvent(.recordingStarted)
        let generation = controller.presentationGeneration
        controller.handleEvent(.dictionaryTermLearned("晚到的词条"))
        XCTAssertEqual(controller.hudState, .recording)
        XCTAssertEqual(controller.presentationGeneration, generation)
        controller.handleEvent(.recordingStopped)
        controller.handleEvent(.dictionaryTermLearned("另一个晚到词条"))
        XCTAssertEqual(controller.hudState, .processing)
        controller.recoveryActionTitle = "重试写入"
        controller.onRecoveryAction = {}
        controller.handleEvent(.processingFailed(.injectionFailed))
        controller.handleEvent(.dictionaryTermLearned("迟到的词条"))
        XCTAssertEqual(controller.hudState, .failure(.injectionFailed))
        XCTAssertEqual(controller.recoveryActionTitle, "重试写入")
        controller.handleEvent(.processingCancelled)
    }

    func testBlankTermDoesNotReplaceNoticeOrCancelItsDismissal() async throws {
        let controller = HUDFeedbackController(learnedTermNoticeDismissSeconds: 0.02)
        controller.handleEvent(.dictionaryTermLearned(" 原始词条 "))
        let generation = controller.presentationGeneration
        controller.handleEvent(.dictionaryTermLearned(" \n "))
        XCTAssertEqual(controller.hudState, .notice("原始词条"))
        XCTAssertEqual(controller.presentationGeneration, generation)
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertFalse(controller.isHUDPresented)
    }

    func testNewRecordingSurvivesOldNoticeTimer() async throws {
        let controller = HUDFeedbackController(soundPlayer: MockFeedbackSoundPlayer(), learnedTermNoticeDismissSeconds: 0.01)
        controller.handleEvent(.dictionaryTermLearned("上次新词"))
        controller.handleEvent(.recordingStarted)
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertEqual(controller.hudState, .recording)
        XCTAssertTrue(controller.isHUDPresented)
        controller.handleEvent(.processingCancelled)
    }

    func testOldRecoveryCallbackCannotTriggerNewFailure() {
        let controller = HUDFeedbackController(soundPlayer: MockFeedbackSoundPlayer())
        var calls = 0
        controller.recoveryActionTitle = "重试写入"
        controller.onRecoveryAction = { calls += 1 }
        controller.handleEvent(.processingFailed(.injectionFailed))
        let stale = controller.presentationGeneration
        controller.handleEvent(.recoveryStarted)
        controller.recoveryActionTitle = "重试写入"
        controller.onRecoveryAction = { calls += 1 }
        controller.handleEvent(.processingFailed(.injectionFailed))
        controller.performRecoveryAction(expectedGeneration: stale)
        XCTAssertEqual(calls, 0)
        controller.performRecoveryAction(expectedGeneration: controller.presentationGeneration)
        controller.performRecoveryAction()
        XCTAssertEqual(calls, 1)
        controller.handleEvent(.processingCancelled)
    }

    func testNativePanelContainsMultilineNoticeAndShrinksAfterReplacement() async throws {
        let previousWindows = Set(NSApp.windows.map(\.windowNumber))
        let controller = HUDFeedbackController(soundPlayer: MockFeedbackSoundPlayer())
        let term = String(repeating: "跨区域知识管理", count: 12)
        controller.handleEvent(.dictionaryTermLearned(term))
        let window = try XCTUnwrap(NSApp.windows.first {
            $0 is HUDWindow && !previousWindows.contains($0.windowNumber)
        })
        XCTAssertEqual(controller.hudState, .notice(term))
        XCTAssertEqual(controller.presentation.lines.count, 2)
        XCTAssertGreaterThanOrEqual(window.frame.width, controller.presentation.panelSize.width)
        XCTAssertGreaterThanOrEqual(window.frame.height, controller.presentation.panelSize.height)
        XCTAssertFalse(window.canBecomeKey)
        let bottom = window.frame.minY
        controller.handleEvent(.recordingStarted)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(window.frame.size, controller.presentation.panelSize)
        XCTAssertEqual(window.frame.minY, bottom, accuracy: 0.01)
        controller.handleEvent(.recordingSignalChanged(missing: true))
        XCTAssertGreaterThan(controller.presentation.capsuleSize.width, HUDLayout.activeWidth)
        controller.handleEvent(.recordingSignalChanged(missing: false))
        XCTAssertEqual(controller.presentation.capsuleSize.width, HUDLayout.activeWidth)
        controller.handleEvent(.processingCancelled)
    }

    func testDismissCountdownResumesRemainingTimeRatherThanRestarting() {
        var countdown = HUDDismissCountdown(remaining: 5)
        XCTAssertEqual(countdown.resume(at: 100), 5)
        countdown.pause(at: 102)
        XCTAssertEqual(countdown.remaining, 3)
        countdown.pause(at: 200) // A second pause source cannot consume paused time.
        XCTAssertEqual(countdown.resume(at: 300), 3)
        countdown.pause(at: 301)
        XCTAssertEqual(countdown.remaining, 2)
        XCTAssertEqual(countdown.resume(at: 400), 2)
        countdown.pause(at: 405)
        XCTAssertEqual(countdown.resume(at: 500), 0)
    }

    func testHoverAndAccessibilityFocusIndependentlyPauseFailureTimer() async throws {
        let controller = HUDFeedbackController(soundPlayer: MockFeedbackSoundPlayer())
        controller.recoveryActionTitle = "重试写入"
        controller.onRecoveryAction = {}
        controller.handleEvent(.processingFailed(.injectionFailed))
        let generation = controller.presentationGeneration
        controller.setRecoveryHover(true, generation: generation)
        controller.setRecoveryAccessibilityFocus(true, generation: generation)
        controller.setRecoveryHover(false, generation: generation)
        // Focus alone must keep the failure alive beyond the five-second deadline.
        try await Task.sleep(for: .milliseconds(5600))
        XCTAssertEqual(controller.hudState, .failure(.injectionFailed))
        XCTAssertTrue(controller.isHUDPresented)
        controller.setRecoveryAccessibilityFocus(false, generation: generation)
        controller.handleEvent(.recordingStarted)
        // Stale hover/focus callbacks cannot pause the next presentation.
        controller.setRecoveryHover(true, generation: generation)
        controller.handleEvent(.processingCancelled)
        await waitForHUDToHide(controller)
        XCTAssertFalse(controller.isHUDPresented)
    }

    func testSyntheticHUDRenderings() async throws {
        let previousWindows = Set(NSApp.windows.map(\.windowNumber))
        let controller = HUDFeedbackController(soundPlayer: MockFeedbackSoundPlayer())
        let samples: [(String, SessionFeedbackEvent, String?)] = [
            ("long-term", .dictionaryTermLearned("跨区域企业级知识管理与智能语音交互平台的多语言协同工作流解决方案"), nil),
            ("truncated-term", .dictionaryTermLearned(String(repeating: "Accessibility语音协作👨‍👩‍👧‍👦", count: 8)), nil),
            ("short-recovery", .processingFailed(.injectionFailed), "重试写入"),
            ("recovery", .processingFailed(.recordingInterrupted), "继续处理已录内容"),
            ("missing-signal", .recordingStarted, nil)
        ]
        for (name, event, action) in samples {
            controller.recoveryActionTitle = action
            controller.onRecoveryAction = action == nil ? nil : {}
            controller.handleEvent(event)
            if name == "missing-signal" { controller.handleEvent(.recordingSignalChanged(missing: true)) }
            if let action {
                XCTAssertEqual(controller.presentation.actionLines, [action])
                XCTAssertEqual(controller.presentation.lines.count, 1)
                XCTAssertEqual(controller.presentation.capsuleSize.height, 34)
            }
            try await Task.sleep(for: .milliseconds(300))
            let window = try XCTUnwrap(NSApp.windows.first {
                $0 is HUDWindow && !previousWindows.contains($0.windowNumber)
            })
            let view = try XCTUnwrap(window.contentView)
            view.layoutSubtreeIfNeeded()
            let native = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: native)
            let nativeData = try XCTUnwrap(native.representation(using: .png, properties: [:]))
            try nativeData.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("memoecho-hud-" + name + "-native.png"))
            let nativeAttachment = XCTAttachment(data: nativeData, uniformTypeIdentifier: "public.png")
            nativeAttachment.name = "HUD-" + name + "-native"
            nativeAttachment.lifetime = .keepAlways
            add(nativeAttachment)
            let size = controller.presentation.panelSize
            let renderer = ImageRenderer(content: HUDContentView(controller: controller)
                .frame(width: size.width, height: size.height))
            renderer.scale = 3
            let cgImage = try XCTUnwrap(renderer.cgImage)
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
            attachment.name = "HUD-" + name
            attachment.lifetime = .keepAlways
            add(attachment)
            // Synthetic-only artifacts for local visual review; no user text or clipboard access.
            try data.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("memoecho-hud-" + name + ".png"))
        }
        controller.handleEvent(.processingCancelled)
        await waitForHUDToHide(controller)
    }

    func testNativeHUDBorderStaysInsideRoundedOutline() async throws {
        let previousWindows = Set(NSApp.windows.map(\.windowNumber))
        let controller = HUDFeedbackController(soundPlayer: MockFeedbackSoundPlayer())
        controller.recoveryActionTitle = "重试写入"
        controller.onRecoveryAction = {}
        controller.handleEvent(.processingFailed(.injectionFailed))
        defer { controller.handleEvent(.processingCancelled) }
        try await Task.sleep(for: .milliseconds(400))
        let window = try XCTUnwrap(NSApp.windows.first {
            $0 is HUDWindow && !previousWindows.contains($0.windowNumber)
        })
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let capsule = controller.presentation.capsuleSize
        let radius = controller.presentation.cornerRadius
        let scaleX = CGFloat(bitmap.pixelsWide) / view.bounds.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / view.bounds.height
        let centerX = view.bounds.width / 2
        let centerY = view.bounds.height - HUDLayout.panelPadding.height - capsule.height / 2
        var outsidePixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let dx = abs((CGFloat(x) + 0.5) / scaleX - centerX) - (capsule.width / 2 - radius)
                let dy = abs((CGFloat(y) + 0.5) / scaleY - centerY) - (capsule.height / 2 - radius)
                let distance = hypot(max(dx, 0), max(dy, 0)) + min(max(dx, dy), 0) - radius
                // Allow a full point for antialiasing; solid stroke beyond that is an artifact.
                if distance > 1, (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.15 {
                    outsidePixels += 1
                }
            }
        }
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("memoecho-hud-border-probe.png"))
        XCTAssertEqual(outsidePixels, 0, "Native HUD must not leave border fragments outside its rounded outline")
    }

    private func waitForModeCueToClear(_ controller: HUDFeedbackController) async {
        for _ in 0..<20 {
            if controller.modeCueLabel == nil { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private func waitForStartSound(_ soundPlayer: MockFeedbackSoundPlayer) async {
        for _ in 0..<20 {
            if soundPlayer.startCount > 0 { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private func waitForHUDToHide(_ controller: HUDFeedbackController) async {
        for _ in 0..<20 {
            if controller.hudState == .hidden, controller.isHUDPresented == false { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private func waitForWaveformUpdate(_ controller: HUDFeedbackController) async {
        await waitForWaveform(
            controller,
            matching: { heights in
                heights != Array(repeating: HUDLayout.resetBarHeight, count: 7)
            }
        )
    }

    private func waitForWaveform(
        _ controller: HUDFeedbackController,
        matching predicate: ([CGFloat]) -> Bool
    ) async {
        for _ in 0..<30 {
            if predicate(controller.barHeights) { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
