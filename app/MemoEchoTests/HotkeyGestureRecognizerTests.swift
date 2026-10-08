import XCTest
@testable import MemoEcho

final class HotkeyGestureRecognizerTests: XCTestCase {
    func testSinglePressTogglesOncePerCompleteCycle() {
        var gesture = HotkeyGestureRecognizer(mode: .singlePress)
        XCTAssertEqual(gesture.press(at: 0), .toggle)
        XCTAssertNil(gesture.press(at: 0.1, isRepeat: true))
        XCTAssertNil(gesture.press(at: 0.2))
        XCTAssertNil(gesture.release(at: 1))
        XCTAssertEqual(gesture.press(at: 2), .toggle)
    }

    func testDoublePressRequiresTwoReleasedTapsAndHasNoFirstPressAction() {
        var gesture = HotkeyGestureRecognizer(mode: .doublePress)
        XCTAssertNil(gesture.press(at: 0))
        XCTAssertNil(gesture.press(at: 0.1))
        XCTAssertNil(gesture.release(at: 0.15))
        XCTAssertNil(gesture.press(at: 0.3))
        XCTAssertEqual(gesture.release(at: 0.35), .toggle)
    }

    func testDoublePressBoundaryAndTimeoutStartsNewPair() {
        for interval in [0.399, 0.4, 0.401] {
            var gesture = HotkeyGestureRecognizer(mode: .doublePress)
            _ = gesture.press(at: 0)
            _ = gesture.release(at: 0.1)
            _ = gesture.press(at: interval)
            let result = gesture.release(at: interval + 0.05)
            XCTAssertEqual(result, interval <= 0.4 ? .toggle : nil)
            if interval > 0.4 {
                _ = gesture.press(at: interval + 0.2)
                XCTAssertEqual(gesture.release(at: interval + 0.25), .toggle)
            }
        }
    }

    func testLongFirstOrSecondPressCannotToggle() {
        var gesture = HotkeyGestureRecognizer(mode: .doublePress)
        _ = gesture.press(at: 0)
        XCTAssertNil(gesture.release(at: 1))
        _ = gesture.press(at: 1.1)
        XCTAssertNil(gesture.release(at: 1.2))
        _ = gesture.press(at: 1.3)
        XCTAssertNil(gesture.release(at: 2))
        _ = gesture.press(at: 2.1)
        XCTAssertNil(gesture.release(at: 2.2))
    }

    func testTriplePressDoesNotReuseSecondTap() {
        var gesture = HotkeyGestureRecognizer(mode: .doublePress)
        _ = gesture.press(at: 0)
        _ = gesture.release(at: 0.05)
        _ = gesture.press(at: 0.1)
        XCTAssertEqual(gesture.release(at: 0.15), .toggle)
        _ = gesture.press(at: 0.2)
        XCTAssertNil(gesture.release(at: 0.25))
    }

    func testResetClearsPendingDoublePressAndRepeatsNeverArm() {
        var gesture = HotkeyGestureRecognizer(mode: .doublePress)
        _ = gesture.press(at: 0)
        _ = gesture.release(at: 0.1)
        XCTAssertNil(gesture.reset())
        XCTAssertNil(gesture.press(at: 0.15, isRepeat: true))
        XCTAssertNil(gesture.release(at: 0.16))
        _ = gesture.press(at: 0.2)
        XCTAssertNil(gesture.release(at: 0.3))
    }

    func testHoldBeginsImmediatelyAndEndsWithSameIdentityOnlyOnce() {
        var gesture = HotkeyGestureRecognizer(mode: .hold)
        XCTAssertEqual(gesture.press(at: 0), .holdBegan(1))
        XCTAssertNil(gesture.press(at: 0.1, isRepeat: true))
        XCTAssertEqual(gesture.release(at: 20), .holdEnded(1))
        XCTAssertNil(gesture.release(at: 21))
        XCTAssertEqual(gesture.press(at: 22), .holdBegan(2))
    }

    func testHoldResetCancelsWithoutSubmissionOrDelayedRelease() {
        var gesture = HotkeyGestureRecognizer(mode: .hold)
        _ = gesture.press(at: 0)
        XCTAssertEqual(gesture.reset(), .holdCancelled(1))
        XCTAssertNil(gesture.release(at: 1))
        XCTAssertNil(gesture.reset())
    }

    func testHoldReleaseCannotFinishDifferentOrAlreadyEndedSession() {
        var interaction = HoldHotkeyInteraction()
        XCTAssertFalse(interaction.consume(gesture: 1, session: "existing", state: .recording))
        interaction.began(gesture: 1, session: "own")
        XCTAssertFalse(interaction.consume(gesture: 2, session: "own", state: .recording))
        XCTAssertTrue(interaction.consume(gesture: 1, session: "own", state: .recording))
        XCTAssertFalse(interaction.consume(gesture: 1, session: "own", state: .recording))
        interaction.began(gesture: 2, session: "old")
        XCTAssertFalse(interaction.consume(gesture: 2, session: "new", state: .recording))
        interaction.began(gesture: 3, session: "own")
        XCTAssertFalse(interaction.consume(gesture: 3, session: "own", state: .transcribing))
    }
}
