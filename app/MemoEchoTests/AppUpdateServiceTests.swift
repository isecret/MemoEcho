import XCTest
@testable import MemoEcho

@MainActor
final class AppUpdateServiceTests: XCTestCase {
    func testDebugInstallationCannotUsePublicUpdateFeed() {
        #if DEBUG
        XCTAssertEqual(Bundle.main.bundleIdentifier, "me.wangmao.memoecho.debug")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "MemoEcho Dev")
        let service = AppUpdateService()
        service.start()
        service.setAutomaticallyChecksForUpdates(true)
        service.checkForUpdates()
        XCTAssertFalse(service.isAvailable)
        XCTAssertFalse(service.canCheckForUpdates)
        XCTAssertFalse(service.automaticallyChecksForUpdates)
        #endif
    }
}
