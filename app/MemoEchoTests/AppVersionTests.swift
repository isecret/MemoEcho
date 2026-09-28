import XCTest
@testable import MemoEcho

final class AppVersionTests: XCTestCase {

    func testParsesReleaseTagsWithLeadingV() {
        let version = AppVersion("v1.2.3")

        XCTAssertEqual(version?.rawValue, "1.2.3")
    }

    func testComparesVersionsNumerically() {
        XCTAssertLessThan(AppVersion("1.2.9")!, AppVersion("1.2.10")!)
        XCTAssertLessThan(AppVersion("1.2")!, AppVersion("1.2.1")!)
        XCTAssertEqual(AppVersion("1.2")!, AppVersion("1.2.0")!)
    }

    func testRejectsInvalidVersions() {
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("v1.beta"))
        XCTAssertNil(AppVersion("release-1"))
        XCTAssertNil(AppVersion("1.0.0-beta.0"))
        XCTAssertNil(AppVersion("1.0.0-beta.01"))
        XCTAssertNil(AppVersion("1.0.0-beta.256"))
        XCTAssertNil(AppVersion("1.0.0-beta."))
    }

    func testBetaVersionsSortBeforeStableRelease() {
        XCTAssertEqual(AppVersion("v1.0.0-beta.1")?.rawValue, "1.0.0-beta.1")
        XCTAssertLessThan(AppVersion("1.0.0-beta.2")!, AppVersion("1.0.0-beta.10")!)
        XCTAssertLessThan(AppVersion("1.0.0-beta.255")!, AppVersion("1.0.0")!)
        XCTAssertLessThan(AppVersion("1.0.0")!, AppVersion("1.1.0-beta.1")!)
    }
}
