import AVFoundation
import XCTest
@testable import MemoEcho

@MainActor
final class AudioRecorderLifecycleTests: XCTestCase {
    func testSlowStopKeepsMainActorResponsiveAndDrainsLastPCMExactlyOnce() async throws {
        let capture = SyntheticAudioCapture()
        let recorder = AudioRecorder(captureFactory: { _ in capture })
        let probe = PCMCallbackProbe()
        let stopEntered = expectation(description: "Hardware stop entered")
        let releaseStop = DispatchSemaphore(value: 0)
        defer { releaseStop.signal() }
        capture.onStart = { [weak recorder, weak capture] in
            guard let capture else { return false }
            recorder?.acceptPCMChunk(Data(repeating: 1, count: 32_000), from: capture.output)
            return true
        }
        capture.onStop = { [weak recorder, weak capture] in
            guard let capture else { return }
            XCTAssertFalse(Thread.isMainThread)
            stopEntered.fulfill()
            _ = releaseStop.wait(timeout: .now() + 3)
            recorder?.acceptPCMChunk(Data(repeating: 1, count: 1_554), from: capture.output)
        }
        try await recorder.startRecording(device: nil, onPCMChunk: { probe.append($0) })
        let stopping = Task { await recorder.stopRecording() }
        await fulfillment(of: [stopEntered], timeout: 1)
        // Reaching this actor while the device is blocked proves the UI executor is free.
        XCTAssertEqual(probe.bytes, 32_000)
        let repeated = Task { await recorder.stopRecording() }
        await Task.yield()
        stopping.cancel() // Hardware teardown must continue despite cancellation of its caller.
        releaseStop.signal()
        let first = await stopping.value
        let second = await repeated.value
        XCTAssertEqual(first.sampleCount, 16_777)
        XCTAssertEqual(second.sampleCount, first.sampleCount)
        XCTAssertEqual(probe.bytes, 33_554)
        XCTAssertEqual(capture.stops, 1)
        XCTAssertEqual(recorder.currentDurationMs, 0)
        XCTAssertEqual(recorder.currentLevel(), 0)
    }

    func testCancelledStartupIsClosedBeforeRestartAndOldOutputCannotReachNewCallback() async throws {
        let first = SyntheticAudioCapture()
        let second = SyntheticAudioCapture()
        let startEntered = expectation(description: "Old startup entered")
        let stopRequested = expectation(description: "Stop requested on MainActor")
        let stopEntered = expectation(description: "Old stop entered")
        let releaseStart = DispatchSemaphore(value: 0)
        let releaseStop = DispatchSemaphore(value: 0)
        defer { releaseStart.signal(); releaseStop.signal() }
        first.onStart = {
            startEntered.fulfill()
            _ = releaseStart.wait(timeout: .now() + 3)
            return true
        }
        first.onStop = {
            stopEntered.fulfill()
            _ = releaseStop.wait(timeout: .now() + 3)
        }
        var creations = 0
        let recorder = AudioRecorder(captureFactory: { _ in
            creations += 1
            return creations == 1 ? first : second
        })
        let originalStart = Task { try await recorder.startRecording(device: nil) }
        await fulfillment(of: [startEntered], timeout: 1)
        originalStart.cancel()
        let stopping = Task {
            stopRequested.fulfill()
            return await recorder.stopRecording()
        }
        await fulfillment(of: [stopRequested], timeout: 1)
        let newPCM = PCMCallbackProbe()
        let restart = Task { try await recorder.startRecording(device: nil, onPCMChunk: { newPCM.append($0) }) }
        releaseStart.signal()
        await fulfillment(of: [stopEntered], timeout: 1)
        XCTAssertEqual(creations, 1, "Restart must not install new buffers before old hardware closes")
        releaseStop.signal()
        _ = await stopping.value
        do { try await originalStart.value; XCTFail("Old startup must be cancelled") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await restart.value
        XCTAssertEqual(creations, 2)
        XCTAssertEqual(first.stops, 1)
        recorder.acceptPCMChunk(Data(repeating: 1, count: 320), from: first.output)
        XCTAssertEqual(newPCM.bytes, 0)
        recorder.acceptPCMChunk(Data(repeating: 1, count: 640), from: second.output)
        XCTAssertEqual(newPCM.bytes, 640)
        let final = await recorder.stopRecording()
        XCTAssertEqual(final.sampleCount, 320)
        XCTAssertEqual(second.stops, 1)
    }

    func testFailedStartupDrainsBeforeReportingFailure() async throws {
        let capture = SyntheticAudioCapture()
        capture.onStart = { false }
        let recorder = AudioRecorder(captureFactory: { _ in capture })
        do { try await recorder.startRecording(device: nil); XCTFail("Expected startup failure") }
        catch { XCTAssertTrue(error is AudioRecorderError) }
        XCTAssertEqual(capture.stops, 1)
        XCTAssertEqual(recorder.currentDurationMs, 0)
    }
}

private final class SyntheticAudioCapture: AudioCaptureSessionDriving, @unchecked Sendable {
    let output = AVCaptureAudioDataOutput()
    var session: AVCaptureSession? { nil }
    var device: AVCaptureDevice? { nil }
    var onStart: @Sendable () -> Bool = { true }
    var onStop: @Sendable () -> Void = {}
    private let lock = NSLock()
    private var stopCount = 0
    var stops: Int { lock.withLock { stopCount } }
    func start() -> Bool { onStart() }
    func stop() { lock.withLock { stopCount += 1 }; onStop() }
}

private final class PCMCallbackProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var bytes: Int { lock.withLock { count } }
    func append(_ data: Data) { lock.withLock { count += data.count } }
}
