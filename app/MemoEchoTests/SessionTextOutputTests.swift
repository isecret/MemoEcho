import XCTest
@testable import MemoEcho

@MainActor
final class SessionTextOutputTests: XCTestCase {
    func testTrialDeliversOnlyToItsTextBoxWithoutExternalInjection() throws {
        var received = ""
        let output = SessionTextOutput.onboardingTrial { text in
            received = text
            return true
        }
        let result = try output.deliver("这是一次语音试用。") { _ in
            XCTFail("试用不得操作其他应用或剪贴板")
            return .init(path: .paste, breakdown: .init())
        }
        XCTAssertEqual(received, "这是一次语音试用。")
        XCTAssertNil(result)
        XCTAssertTrue(output.isOnboardingTrial)
    }

    func testClosedTrialReceiverDoesNotFallBackToExternalApplication() {
        let output = SessionTextOutput.onboardingTrial { _ in false }
        XCTAssertThrowsError(try output.deliver("不应写入任何位置") { _ in
            XCTFail("无效试用接收器不能回退到外部注入")
            return .init(path: .paste, breakdown: .init())
        }) { error in
            XCTAssertEqual(error as? MemoEchoError, .sessionCancelled)
        }
    }

    func testNormalRecordingStillUsesExistingTextInjection() throws {
        var injected = ""
        let result = try SessionTextOutput.focusedApplication.deliver("正常语音输入") { text in
            injected = text
            return .init(path: .axFallback, breakdown: .init())
        }
        XCTAssertEqual(injected, "正常语音输入")
        XCTAssertEqual(result?.path, .axFallback)
        XCTAssertFalse(SessionTextOutput.focusedApplication.isOnboardingTrial)
    }
}
