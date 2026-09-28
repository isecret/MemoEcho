import AVFoundation
import XCTest
@testable import MemoEcho

final class FeedbackSoundAssetsTests: XCTestCase {
    func testApprovedPairIsBundledAndMatchesPlaybackFormat() throws {
        for cue in FeedbackSoundCue.allCases {
            let buffer = try FeedbackSoundAssets.makeBuffer(for: cue)
            XCTAssertEqual(buffer.format, FeedbackSoundDesigner.makePlaybackFormat())
            let expectedFrames: AVAudioFrameCount = 18_963
            XCTAssertEqual(buffer.frameLength, expectedFrames, "Retain the approved preview's full tail")
            let channels = try XCTUnwrap(buffer.floatChannelData)
            var energy = 0.0
            var peak: Float = 0
            for channel in 0..<2 {
                XCTAssertEqual(channels[channel][0], 0)
                XCTAssertEqual(channels[channel][Int(buffer.frameLength) - 1], 0)
                for frame in 0..<Int(buffer.frameLength) {
                    let value = channels[channel][frame]
                    XCTAssertTrue(value.isFinite)
                    energy += Double(value * value)
                    peak = max(peak, abs(value))
                }
            }
            let rmsDB = 20 * log10(sqrt(energy / Double(buffer.frameLength * 2)))
            XCTAssertEqual(rmsDB, -32, accuracy: 0.05)
            XCTAssertLessThanOrEqual(peak, 0.09)
        }
    }

    func testEndIsADistinctCueWithMatchingDuration() throws {
        let start = try FeedbackSoundAssets.makeBuffer(for: .start)
        let end = try FeedbackSoundAssets.makeBuffer(for: .stop)
        let a = try XCTUnwrap(start.floatChannelData)
        let b = try XCTUnwrap(end.floatChannelData)
        XCTAssertEqual(start.frameLength, end.frameLength)
        let difference = (0..<Int(min(start.frameLength, end.frameLength))).reduce(0.0) { sum, frame in
            sum + abs(Double(a[0][frame] - b[0][frame]))
        }
        XCTAssertGreaterThan(difference, 1)
    }

    func testMissingResourceThrowsInsteadOfSubstitutingAnotherSound() {
        XCTAssertThrowsError(try FeedbackSoundAssets.makeBuffer(for: .start, bundle: Bundle(for: Self.self))) { error in
            guard case FeedbackSoundAssets.LoadError.missingResource("ufo-start") = error else {
                return XCTFail("Expected a missing-resource error, received \(error)")
            }
        }
    }
}
