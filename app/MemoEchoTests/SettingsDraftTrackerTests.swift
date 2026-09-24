import XCTest
@testable import MemoEcho

final class SettingsDraftTrackerTests: XCTestCase {
    func testUntouchedOlderEditorDoesNotFlushAfterAnotherEditorSaves() {
        var older = SettingsDraftTracker()
        var newer = SettingsDraftTracker()
        older.loaded("configuration-a")
        newer.loaded("configuration-a")
        XCTAssertTrue(newer.changed(to: "configuration-b"))
        newer.loaded("configuration-b")
        XCTAssertFalse(older.hasPendingChanges)
        XCTAssertFalse(newer.hasPendingChanges)
    }

    func testLoadingSameValuesAndRevertingEditsDoNotWrite() {
        var tracker = SettingsDraftTracker()
        tracker.loaded("a")
        XCTAssertFalse(tracker.changed(to: "a"))
        XCTAssertTrue(tracker.changed(to: "b"))
        XCTAssertFalse(tracker.changed(to: "a"))
    }

    func testSuccessfulSaveClearsPendingButFailureKeepsDraftForRetry() {
        var tracker = SettingsDraftTracker()
        tracker.loaded("a")
        tracker.changed(to: "b")
        XCTAssertTrue(tracker.hasPendingChanges)
        tracker.loaded("b")
        XCTAssertFalse(tracker.hasPendingChanges)
    }
}
