import AppKit
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
        for label in ["翻译失败 · 重试翻译", "识别失败 · 检查设置", "写入失败 · 复制结果"] {
            XCTAssertLessThanOrEqual(HUDLayout.recoveryWidth(for: label), HUDLayout.windowSize.width)
        }
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
        XCTAssertNil(controller.recoveryActionTitle)
        XCTAssertNil(controller.onRecoveryAction)
        controller.handleEvent(.processingCancelled)
    }

    func testResultTransitionClearsInterruptedRecordingLayer() {
        var layers = HUDLayerState(
            recordingOpacity: 1,
            processingOpacity: 0.14,
            resultOpacity: 0,
            recordingControlsOpacity: 0,
            recordingWaveOpacity: 0.18
        )

        layers.prepareForTransition(to: .failure(.notHeard))

        XCTAssertEqual(layers.recordingOpacity, 0)
        XCTAssertEqual(layers.recordingControlsOpacity, 0)
        XCTAssertEqual(layers.recordingWaveOpacity, 0)
        XCTAssertEqual(layers.processingOpacity, 0.14)
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

    func testDictionaryTermLearnedTruncatesLongDisplayText() {
        let controller = HUDFeedbackController()

        controller.handleEvent(.dictionaryTermLearned("客户成功部"))

        XCTAssertEqual(controller.hudState, .notice("客户成功…"))
    }

    func testDictionaryTermLearnedUsesExtendedDefaultDismissDuration() {
        XCTAssertEqual(HUDFeedbackController.defaultLearnedTermNoticeDismissSeconds, 1.8, accuracy: 0.001)
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
