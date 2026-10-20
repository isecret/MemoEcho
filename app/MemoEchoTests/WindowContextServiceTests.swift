import XCTest
@testable import MemoEcho

final class WindowContextServiceTests: XCTestCase {
    func testOwnProcessNeverEntersBackgroundContextProvider() async {
        // A same-process AX request calls SwiftUI accessibility synchronously on
        // the worker queue, which traps when it evaluates a MainActor binding.
        let service = WindowContextService { _, _, _, _ in
            XCTFail("MemoEcho's own UI must not enter the background AX reader")
            return WindowContextCandidate(appName: "MemoEcho", visibleText: "synthetic settings text")
        }
        for bundleID in [nil, "me.wangmao.memoecho", "me.wangmao.memoecho.debug"] as [String?] {
            let result = await service.captureContextResult(
                targetPID: ProcessInfo.processInfo.processIdentifier, targetBundleID: bundleID,
                onBasic: { _ in XCTFail("Own-window context must not be published") })
            XCTAssertNil(result.snapshot)
            XCTAssertEqual(result.event, .unavailable)
        }
    }

    func testOtherProcessStillReceivesBasicAndExtendedContext() async {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let targetPID: pid_t = ownPID == 42 ? 43 : 42
        let service = WindowContextService { pid, bundleID, _, phase in
            XCTAssertEqual(pid, targetPID)
            XCTAssertEqual(bundleID, "com.example.editor")
            return WindowContextCandidate(appName: "Example", bundleID: bundleID,
                visibleText: phase == .extended ? "synthetic editor text" : nil)
        }
        let basic = expectation(description: "Basic context arrives")
        let result = await service.captureContextResult(targetPID: targetPID, targetBundleID: "com.example.editor",
            onBasic: { result in
                XCTAssertEqual(result.snapshot?.appName, "Example")
                XCTAssertNil(result.snapshot?.visibleText)
                basic.fulfill()
            })
        await fulfillment(of: [basic], timeout: 1)
        XCTAssertEqual(result.event, .captured)
        XCTAssertEqual(result.snapshot?.visibleText, "synthetic editor text")
    }

    func testBuildSnapshotTrimsAndCapsFields() {
        let candidate = WindowContextCandidate(
            appName: "  WeChat  ",
            bundleID: " com.tencent.xinWeChat ",
            windowTitle: "  聊天窗口  ",
            elementRole: " AXTextField ",
            elementSubrole: "  ",
            placeholder: "  说点什么  ",
            selectedText: String(repeating: "选", count: 1240),
            surroundingTextBefore: String(repeating: "前", count: 1100),
            surroundingTextAfter: String(repeating: "后", count: 1120),
            nearbyLabels: ["  回复  ", "", "回复", " 评论 ", " 发送 ", "额外标签"]
        )

        let result = WindowContextService.buildSnapshot(from: candidate)

        XCTAssertFalse(result.redacted)
        XCTAssertEqual(result.snapshot?.appName, "WeChat")
        XCTAssertEqual(result.snapshot?.bundleID, "com.tencent.xinWeChat")
        XCTAssertEqual(result.snapshot?.windowTitle, "聊天窗口")
        XCTAssertEqual(result.snapshot?.surfaceKind, .chatComposer)
        XCTAssertEqual(result.snapshot?.selectedText?.count, 1000)
        XCTAssertEqual(result.snapshot?.surroundingTextBefore?.count, 1000)
        XCTAssertEqual(result.snapshot?.surroundingTextAfter?.count, 1000)
        XCTAssertEqual(result.snapshot?.nearbyLabels, ["回复", "评论", "发送", "额外标签"])
    }

    func testBuildSnapshotFiltersEmptyValues() {
        let candidate = WindowContextCandidate(
            appName: "   ",
            bundleID: nil,
            windowTitle: "\n",
            elementRole: nil,
            elementSubrole: nil,
            placeholder: " ",
            selectedText: nil,
            surroundingTextBefore: nil,
            surroundingTextAfter: nil,
            nearbyLabels: [" ", "\n"]
        )

        let result = WindowContextService.buildSnapshot(from: candidate)

        XCTAssertNil(result.snapshot)
        XCTAssertFalse(result.redacted)
    }

    func testSensitiveContextRedactsBodyText() {
        let candidate = WindowContextCandidate(
            appName: "1Password",
            bundleID: "com.1password.1password",
            windowTitle: "登录",
            elementRole: "AXTextField",
            elementSubrole: "AXSecureTextField",
            placeholder: "Password",
            selectedText: "hunter2",
            surroundingTextBefore: "prefix",
            surroundingTextAfter: "suffix",
            nearbyLabels: ["Master Password", "Sign In"]
        )

        let result = WindowContextService.buildSnapshot(from: candidate)

        XCTAssertTrue(result.redacted)
        XCTAssertEqual(result.snapshot?.appName, "1Password")
        XCTAssertEqual(result.snapshot?.bundleID, "com.1password.1password")
        XCTAssertNil(result.snapshot?.placeholder)
        XCTAssertNil(result.snapshot?.selectedText)
        XCTAssertNil(result.snapshot?.surroundingTextBefore)
        XCTAssertNil(result.snapshot?.surroundingTextAfter)
        XCTAssertEqual(result.snapshot?.nearbyLabels, [])
    }

    func testCaptureContextResultMarksRedactedEvent() async {
        let service = WindowContextService { _, _, _, _ in
            WindowContextCandidate(
                appName: "Terminal",
                bundleID: "com.apple.Terminal",
                windowTitle: "zsh",
                elementRole: "AXTextArea",
                elementSubrole: nil,
                placeholder: nil,
                selectedText: "secret",
                surroundingTextBefore: "before",
                surroundingTextAfter: "after",
                nearbyLabels: ["Shell"]
            )
        }

        let result = await service.captureContextResult(targetPID: nil, targetBundleID: nil)

        XCTAssertEqual(result.event, .redacted)
        XCTAssertNil(result.snapshot?.selectedText)
    }
}
