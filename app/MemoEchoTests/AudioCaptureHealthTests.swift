import XCTest
@testable import MemoEcho

final class AudioCaptureHealthTests: XCTestCase {
    func testRecoveryBufferReleasesCompletedAudioAndKeepsOrderedRemainder() {
        let buffer = RecordingRecoveryBuffer()
        for i in 0..<3 {
            buffer.append(SealedSegment(index: i, pcmData: Data(repeating: 1, count: 32000),
                sampleCount: 16000, sealReason: .finalize, voicedDetected: true))
        }
        buffer.complete(index: 0, text: "first")
        buffer.complete(index: 1, text: "second")
        let snapshot = buffer.snapshot()
        XCTAssertEqual(snapshot.transcripts, ["first", "second"])
        XCTAssertEqual(snapshot.segments.map(\.index), [2])
        buffer.clear()
        XCTAssertTrue(buffer.snapshot().segments.isEmpty)
        XCTAssertTrue(buffer.snapshot().transcripts.isEmpty)
        XCTAssertEqual(snapshot.segments.map(\.index), [2], "checkpoint snapshot survives buffer cleanup")
    }

    func testNoBuffersFailsOnceAfterStartupBudget() {
        var health = AudioCaptureHealth(startedAt: 100)
        XCTAssertNil(health.evaluate(now: 102.9, lastBufferAt: nil, peakRMS: 0))
        XCTAssertEqual(health.evaluate(now: 103, lastBufferAt: nil, peakRMS: 0), .interrupted(.stalled))
        XCTAssertNil(health.evaluate(now: 110, lastBufferAt: nil, peakRMS: 0))
    }

    func testQuietBuffersWarnWithoutInterruptingAndVoiceClearsWarning() {
        var health = AudioCaptureHealth(startedAt: 0)
        XCTAssertNil(health.evaluate(now: 0, lastBufferAt: 0, peakRMS: 0))
        XCTAssertNil(health.evaluate(now: 3.9, lastBufferAt: 3.9, peakRMS: 0.0001))
        XCTAssertEqual(health.evaluate(now: 4, lastBufferAt: 4, peakRMS: 0), .signalMissing)
        XCTAssertNil(health.evaluate(now: 8, lastBufferAt: 8, peakRMS: 0))
        XCTAssertEqual(health.evaluate(now: 8.5, lastBufferAt: 8.5, peakRMS: 0.02), .signalRestored)
        XCTAssertNil(health.evaluate(now: 9, lastBufferAt: 9, peakRMS: 0))
        XCTAssertEqual(health.evaluate(now: 13, lastBufferAt: 13, peakRMS: 0), .signalMissing)
    }

    func testStreamStallAfterVoiceIsNotMistakenForSilence() {
        var health = AudioCaptureHealth(startedAt: 0)
        XCTAssertNil(health.evaluate(now: 4, lastBufferAt: 4, peakRMS: 0.2))
        XCTAssertEqual(health.evaluate(now: 7, lastBufferAt: 4, peakRMS: 0), .interrupted(.stalled))
    }

    func testShortPausesAndLowButAudibleInputDoNotWarn() {
        var health = AudioCaptureHealth(startedAt: 0)
        for i in 0..<20 {
            XCTAssertNil(health.evaluate(now: Double(i), lastBufferAt: Double(i), peakRMS: i % 3 == 0 ? 0.003 : 0))
        }
    }
}
