import AVFoundation
import XCTest
@testable import MemoEcho

@MainActor
final class MicrophoneLevelControllerTests: XCTestCase {
    func testSlowStopResetsUIImmediatelyAndRestartWaitsForMicrophoneRelease() async {
        let recorder = TestRecorder()
        let controller = MicrophoneLevelController(recorder: recorder)
        controller.start(device: nil, authorize: {})
        await settle()
        let stopEntered = expectation(description: "Meter stop entered")
        var release: CheckedContinuation<Void, Never>?
        recorder.stopOperation = {
            await withCheckedContinuation { continuation in
                release = continuation
                stopEntered.fulfill()
            }
        }
        controller.stop()
        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(controller.level, 0)
        await fulfillment(of: [stopEntered], timeout: 1)
        controller.start(device: nil, authorize: {})
        let startedTooEarly = expectation(description: "Meter must await old close")
        startedTooEarly.isInverted = true
        recorder.onStart = { startedTooEarly.fulfill() }
        await fulfillment(of: [startedTooEarly], timeout: 0.03)
        XCTAssertEqual(recorder.starts, 1)
        recorder.onStart = nil
        let restarted = expectation(description: "Meter restarted after old close")
        recorder.onStart = { restarted.fulfill() }
        release?.resume()
        await fulfillment(of: [restarted], timeout: 1)
        XCTAssertEqual(recorder.starts, 2)
        XCTAssertTrue(controller.isRunning)
        recorder.stopOperation = nil
        await controller.stopAndWait()
        XCTAssertEqual(recorder.stops, 2)
    }

    func testStopAndWaitDoesNotReleaseMainRecordingBarrierEarly() async {
        let recorder = TestRecorder()
        let controller = MicrophoneLevelController(recorder: recorder)
        controller.start(device: nil, authorize: {})
        await settle()
        let stopEntered = expectation(description: "Meter close entered")
        var release: CheckedContinuation<Void, Never>?
        recorder.stopOperation = {
            await withCheckedContinuation { continuation in
                release = continuation
                stopEntered.fulfill()
            }
        }
        var mayOpenMainCapture = false
        let handoff = Task { await controller.stopAndWait(); mayOpenMainCapture = true }
        await fulfillment(of: [stopEntered], timeout: 1)
        XCTAssertFalse(mayOpenMainCapture)
        XCTAssertFalse(controller.isRunning)
        release?.resume()
        await handoff.value
        XCTAssertTrue(mayOpenMainCapture)
    }

    func testPermissionFailureDoesNotStartCapture() async {
        let recorder = TestRecorder()
        let controller = MicrophoneLevelController(recorder: recorder)
        controller.start(device: nil) { throw PermissionError.microphonePermissionDenied }
        await Task.yield()
        XCTAssertEqual(recorder.starts, 0)
        XCTAssertFalse(controller.isRunning)
        XCTAssertTrue((controller.message ?? "").contains("权限"))
    }

    func testMeterUpdatesAndStoppingResetsLevelAndReleasesCapture() async {
        let recorder = TestRecorder()
        let controller = MicrophoneLevelController(recorder: recorder)
        controller.start(device: nil, authorize: {})
        await settle()
        XCTAssertEqual(controller.level, 0.2)
        recorder.onCaptureEvent?(.signalMissing)
        XCTAssertTrue(controller.isRunning)
        XCTAssertNil(controller.message)
        controller.stop()
        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(controller.level, 0)
        XCTAssertNil(recorder.onCaptureEvent)
        await controller.stopAndWait()
        XCTAssertEqual(recorder.stops, 1)
        controller.start(device: nil, authorize: {})
        await settle()
        XCTAssertEqual(recorder.starts, 2)
        XCTAssertEqual(controller.level, 0.2)
        controller.stop()
    }

    func testInterruptionStopsMeterAndOldCallbackCannotStopNewMeter() async {
        let recorder = TestRecorder()
        let controller = MicrophoneLevelController(recorder: recorder)
        controller.start(device: nil, authorize: {})
        await settle()
        let oldCallback = recorder.onCaptureEvent
        oldCallback?(.interrupted(.deviceDisconnected))
        XCTAssertFalse(controller.isRunning)
        XCTAssertTrue((controller.message ?? "").contains("不可用"))
        controller.start(device: nil, authorize: {})
        await settle()
        oldCallback?(.interrupted(.streamFailed))
        XCTAssertTrue(controller.isRunning)
        XCTAssertEqual(recorder.stops, 1)
        controller.stop()
    }

    func testLeavingBeforeStartTaskRunsDoesNotOpenMicrophone() async {
        let recorder = TestRecorder()
        let controller = MicrophoneLevelController(recorder: recorder)
        controller.start(device: nil, authorize: {})
        controller.stop()
        await settle()
        XCTAssertEqual(recorder.starts, 0)
        XCTAssertFalse(controller.isRunning)
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(20)) }

    private final class TestRecorder: AudioRecording {
        var onCaptureEvent: (@MainActor @Sendable (AudioCaptureEvent) -> Void)?
        var currentDurationMs = 1000
        var starts = 0
        var stops = 0
        var onStart: (() -> Void)?
        var stopOperation: (() async -> Void)?
        func startRecording(device: AVCaptureDevice?, onPCMChunk: (@Sendable (Data) -> Void)?) async throws { starts += 1; onStart?() }
        func currentLevel() -> Float { 0.2 }
        func stopRecording() async -> AudioRecordingResult {
            stops += 1
            await stopOperation?()
            return .init(data: WAVAudioEncoder.encodePCM16(pcmData: Data(repeating: 0, count: 32000), sampleRate: 16000, channels: 1), durationMs: 1000)
        }
    }
}
