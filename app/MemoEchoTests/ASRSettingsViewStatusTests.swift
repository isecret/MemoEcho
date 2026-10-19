import SwiftUI
import XCTest
@testable import MemoEcho

final class ASRSettingsViewStatusTests: XCTestCase {
    func testInitialPresentationUsesVerifiedStateAsReady() {
        let presentation = ASRCloudStatusPresentation.initial(
            isComplete: true,
            persistedState: .verified,
            errorMessage: nil
        )

        XCTAssertEqual(presentation, .ready)
        XCTAssertEqual(presentation.text, "已就绪")
    }

    func testInitialPresentationUsesFailedStateWhenErrorExists() {
        let presentation = ASRCloudStatusPresentation.initial(
            isComplete: true,
            persistedState: .failed,
            errorMessage: "认证失败"
        )

        XCTAssertEqual(presentation, .failed)
        XCTAssertEqual(presentation.text, "未就绪")
        XCTAssertTrue(presentation.showsErrorMessage)
    }

    func testInitialPresentationFallsBackToNotReadyWithoutCompleteConfig() {
        let presentation = ASRCloudStatusPresentation.initial(
            isComplete: false,
            persistedState: .verified,
            errorMessage: nil
        )

        XCTAssertEqual(presentation, .notReady)
    }

    func testCurrentSessionPresentationDoesNotTreatCheckingAsReady() {
        let presentation = ASRCloudStatusPresentation.currentSession(
            isComplete: true,
            serviceStatus: .checking,
            errorMessage: nil
        )

        XCTAssertEqual(presentation, .checking)
        XCTAssertEqual(presentation.text, "检查中…")
        XCTAssertFalse(presentation.showsRetry)
    }

    func testCurrentSessionPresentationUsesFailedStateWhenErrorExists() {
        let presentation = ASRCloudStatusPresentation.currentSession(
            isComplete: true,
            serviceStatus: .failed,
            errorMessage: "网络错误"
        )

        XCTAssertEqual(presentation, .failed)
        XCTAssertEqual(presentation.systemImage, "xmark.circle.fill")
    }

    func testTransientFailureShowsUnavailableAndRetryWithoutRequiringErrorText() {
        let presentation = ASRCloudStatusPresentation.currentSession(
            isComplete: true,
            serviceStatus: .failed,
            errorMessage: nil,
            isTransientFailure: true
        )

        XCTAssertEqual(presentation.text, "暂不可用")
        XCTAssertTrue(presentation.showsRetry)
        XCTAssertTrue(presentation.showsErrorMessage)
    }

    func testRetryVisibilityOnlyIncludesUnavailableAndNotReady() {
        for presentation: ASRCloudStatusPresentation in [.notReady, .failed, .temporarilyUnavailable] {
            XCTAssertTrue(presentation.showsRetry)
        }
        for presentation: ASRCloudStatusPresentation in [.ready, .checking] {
            XCTAssertFalse(presentation.showsRetry)
        }
    }

    func testMissingFieldsDoNotShowStaleUnavailableState() {
        let presentation = ASRCloudStatusPresentation.currentSession(
            isComplete: false,
            serviceStatus: .failed,
            errorMessage: "服务暂时不可用",
            isTransientFailure: true
        )

        XCTAssertEqual(presentation, .notReady)
        XCTAssertTrue(presentation.showsRetry)
        XCTAssertFalse(presentation.showsErrorMessage)
    }
}

final class LLMSettingsViewStatusTests: XCTestCase {
    func testTransientAndConfigurationFailuresOfferRetryWithDistinctStatus() {
        let transient = LLMStatusPresentation(status: .failed, isTransientFailure: true)
        let configuration = LLMStatusPresentation(status: .failed)

        XCTAssertEqual(transient.text, "暂不可用")
        XCTAssertEqual(configuration.text, "未就绪")
        XCTAssertTrue(transient.showsRetry)
        XCTAssertTrue(configuration.showsRetry)
    }

    func testReadyAndCheckingHideRetry() {
        let ready = LLMStatusPresentation(status: .ready)
        let checking = LLMStatusPresentation(status: .checking)

        XCTAssertEqual(ready.text, "已就绪")
        XCTAssertEqual(checking.text, "检查中…")
        XCTAssertFalse(ready.showsRetry)
        XCTAssertFalse(checking.showsRetry)
    }

    func testIncompleteConfigUsesNotReadyAndKeepsRetryVisible() {
        let presentation = LLMStatusPresentation(status: .incomplete, isTransientFailure: true)

        XCTAssertEqual(presentation.text, "未就绪")
        XCTAssertTrue(presentation.showsRetry)
    }
}
