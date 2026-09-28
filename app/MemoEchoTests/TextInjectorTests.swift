import AppKit
import XCTest
@testable import MemoEcho

@MainActor
final class TextInjectorTests: XCTestCase {
    func testDelayedPasteIsConfirmedWithoutAXRetryAndClipboardRestored() async throws {
        let driver = FakeInjectionDriver()
        let original = driver.board.items
        driver.onWait = { tick in if tick == 5 { driver.apply("hello") } }
        let result = try await TextInjector(driver: driver).inject(text: "hello", target: driver.current)
        XCTAssertEqual(result.path, .paste)
        XCTAssertEqual(result.beforeInjection?.value, "前后")
        XCTAssertEqual(driver.pastes, 1)
        XCTAssertEqual(driver.axWrites, 0)
        XCTAssertEqual(driver.board.items, original)
        XCTAssertEqual(driver.waits, 5)
        XCTAssertFalse(driver.isInjecting)
    }

    func testUnchangedValueTimesOutWithoutDuplicateAXInsertion() async {
        let driver = FakeInjectionDriver()
        await fails(driver)
        XCTAssertEqual(driver.pastes, 1)
        XCTAssertEqual(driver.axWrites, 0)
        XCTAssertEqual(driver.waits, 21)
        XCTAssertEqual(driver.board.restores, 1)
    }

    func testUnrelatedTextChangeDoesNotCountAsSuccess() async {
        let driver = FakeInjectionDriver()
        driver.onWait = { tick in if tick == 2 { driver.apply("unrelated") } }
        await fails(driver)
        XCTAssertEqual(driver.axWrites, 0)
    }

    func testFailedActivationNeverWritesClipboardOrEvents() async {
        let driver = FakeInjectionDriver()
        driver.canActivate = false
        await fails(driver)
        XCTAssertEqual(driver.board.writes, 0)
        XCTAssertEqual(driver.pastes, 0)
        XCTAssertEqual(driver.axWrites, 0)
    }

    func testMissingOriginalTargetDoesNotUseCurrentFocus() async {
        let driver = FakeInjectionDriver()
        do {
            _ = try await TextInjector(driver: driver).inject(text: "hello", target: nil)
            XCTFail("Expected failure")
        } catch {}
        XCTAssertEqual(driver.board.writes, 0)
    }

    func testDifferentFieldAtDeliveryIsRejected() async {
        let driver = FakeInjectionDriver()
        let target = driver.current
        driver.current = FakeInjectionDriver.focus(identity: "other")
        await fails(driver, target: target)
        XCTAssertEqual(driver.board.writes, 0)
    }

    func testSelectionChangeDuringPropagationStopsPaste() async {
        let driver = FakeInjectionDriver()
        driver.onWait = { _ in driver.current = FakeInjectionDriver.focus(selection: NSRange(location: 0, length: 0)) }
        await fails(driver)
        XCTAssertEqual(driver.pastes, 0)
        XCTAssertEqual(driver.axWrites, 0)
        XCTAssertEqual(driver.board.restores, 1)
    }

    func testFieldChangeDuringPropagationStopsPaste() async {
        let driver = FakeInjectionDriver()
        driver.onWait = { _ in driver.current = FakeInjectionDriver.focus(identity: "other") }
        await fails(driver)
        XCTAssertEqual(driver.pastes, 0)
    }

    func testTransientFocusLossAfterPasteCannotLaterBecomeSuccess() async {
        let driver = FakeInjectionDriver()
        driver.onWait = { tick in
            if tick == 2 { driver.current = nil }
            if tick == 3 { driver.current = FakeInjectionDriver.focus(value: "前hello后") }
        }
        await fails(driver)
        XCTAssertEqual(driver.axWrites, 0)
        XCTAssertEqual(driver.waits, 21)
    }

    func testNewCopyDuringPropagationIsPreservedAndStopsPaste() async {
        let driver = FakeInjectionDriver()
        driver.onWait = { _ in driver.board.userCopy("user copy") }
        await fails(driver)
        XCTAssertEqual(driver.pastes, 0)
        XCTAssertEqual(driver.axWrites, 0)
        XCTAssertEqual(driver.board.restores, 0)
        XCTAssertEqual(driver.board.items, [[.string: Data("user copy".utf8)]])
    }

    func testNewCopyAfterDispatchSurvivesSuccessfulVerification() async throws {
        let driver = FakeInjectionDriver()
        driver.onWait = { tick in
            if tick == 2 { driver.board.userCopy("new copy"); driver.apply("hello") }
        }
        _ = try await TextInjector(driver: driver).inject(text: "hello", target: driver.current)
        XCTAssertEqual(driver.board.restores, 0)
        XCTAssertEqual(driver.board.items, [[.string: Data("new copy".utf8)]])
    }

    func testAXFallbackOnlyBeforeEventDispatchAndMustVerify() async throws {
        let driver = FakeInjectionDriver()
        driver.canPost = false
        driver.axUpdatesValue = true
        let result = try await TextInjector(driver: driver).inject(text: "hello", target: driver.current)
        XCTAssertEqual(result.path, .axFallback)
        XCTAssertEqual(driver.pastes, 0)
        XCTAssertEqual(driver.axWrites, 1)
        XCTAssertEqual(driver.board.restores, 1)
    }

    func testClipboardWriteFailureCanUseVerifiedAXFallback() async throws {
        let driver = FakeInjectionDriver()
        driver.board.canWrite = false
        driver.axUpdatesValue = true
        let result = try await TextInjector(driver: driver).inject(text: "hello", target: driver.current)
        XCTAssertEqual(result.path, .axFallback)
        XCTAssertEqual(driver.pastes, 0)
        XCTAssertEqual(driver.board.restores, 1)
    }

    func testAXSuccessCodeWithoutTextChangeDoesNotReportSuccess() async {
        let driver = FakeInjectionDriver()
        driver.canPost = false
        await fails(driver)
        XCTAssertEqual(driver.axWrites, 1)
    }

    func testUnreadableFieldPastesOnceButDoesNotClaimConfirmation() async {
        let driver = FakeInjectionDriver()
        driver.current = FakeInjectionDriver.focus(readable: false)
        await fails(driver)
        XCTAssertEqual(driver.pastes, 1)
        XCTAssertEqual(driver.axWrites, 0)
    }

    func testIMECompositionPreventsInsertion() async {
        let driver = FakeInjectionDriver()
        driver.current = FakeInjectionDriver.focus(composing: true)
        await fails(driver)
        XCTAssertEqual(driver.board.writes, 0)
    }

    func testUTF16SelectionReplacementPreservesSurroundingText() async throws {
        let driver = FakeInjectionDriver()
        driver.current = FakeInjectionDriver.focus(value: "A😀旧词Z", selection: NSRange(location: 3, length: 2))
        driver.onWait = { tick in if tick == 2 { driver.apply("新词") } }
        _ = try await TextInjector(driver: driver).inject(text: "新词", target: driver.current)
        XCTAssertEqual(driver.current?.snapshot?.value, "A😀新词Z")
    }

    func testOverlappingInjectorCannotOverwriteFirstClipboard() async throws {
        let driver = FakeInjectionDriver()
        var rejected = false
        driver.onAsyncWait = { tick in
            if tick == 1 {
                do {
                    _ = try await TextInjector(driver: driver).inject(text: "second", target: driver.current)
                    XCTFail("Must reject overlapping output")
                } catch { rejected = true }
            }
        }
        driver.onWait = { tick in if tick == 2 { driver.apply("hello") } }
        _ = try await TextInjector(driver: driver).inject(text: "hello", target: driver.current)
        XCTAssertTrue(rejected)
        XCTAssertEqual(driver.board.writes, 1)
        XCTAssertEqual(driver.pastes, 1)
    }

    func testStaleGenerationBeforeDispatchDoesNotWrite() async {
        let driver = FakeInjectionDriver()
        var active = true
        driver.onWait = { _ in active = false }
        do {
            _ = try await TextInjector(driver: driver).inject(text: "hello", target: driver.current, shouldContinue: { active })
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(driver.pastes, 0)
        XCTAssertEqual(driver.board.restores, 1)
    }

    func testStaleGenerationAfterDispatchDrainsClipboardWindowWithoutRetry() async {
        let driver = FakeInjectionDriver()
        var active = true
        driver.onWait = { tick in if tick == 2 { active = false; driver.apply("hello") } }
        do {
            _ = try await TextInjector(driver: driver).inject(text: "hello", target: driver.current, shouldContinue: { active })
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(driver.waits, 21)
        XCTAssertEqual(driver.axWrites, 0)
        XCTAssertEqual(driver.board.restores, 1)
    }

    func testLeaseRestoresAllItemsOnceAndDoesNotOverwriteLaterCopy() throws {
        let board = FakeInjectionPasteboard()
        let original = board.items
        let lease = try InjectionPasteboardLease(pasteboard: board)
        XCTAssertTrue(lease.write("transient"))
        lease.restore()
        XCTAssertEqual(board.items, original)
        board.userCopy("later")
        lease.restore()
        XCTAssertEqual(board.restores, 1)
        XCTAssertEqual(board.items, [[.string: Data("later".utf8)]])
    }

    func testNativePasteboardRestoresMultipleItemsAndFormats() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("MemoEcho-output-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let original = [NSPasteboardItem(), NSPasteboardItem()]
        original[0].setString("synthetic clipboard", forType: .string)
        let richText = NSAttributedString(string: "synthetic clipboard")
        let rtf = try richText.data(from: NSRange(location: 0, length: richText.length),
                                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        original[0].setData(rtf, forType: .rtf)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.bitmapData?.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        original[1].setData(try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), forType: .png)
        XCTAssertTrue(board.writeObjects(original))
        let adapter = NativeInjectionPasteboard(board: board)
        let snapshot = try adapter.snapshot()
        let lease = try InjectionPasteboardLease(pasteboard: adapter)
        XCTAssertTrue(lease.write("transient"))
        lease.restore()
        XCTAssertEqual(try adapter.snapshot(), snapshot)
        XCTAssertEqual(board.pasteboardItems?.count, 2)
    }

    func testNativePasteboardPreservesExternalWrite() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("MemoEcho-output-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let lease = try InjectionPasteboardLease(pasteboard: NativeInjectionPasteboard(board: board))
        XCTAssertTrue(lease.write("transient"))
        board.clearContents()
        board.setString("external", forType: .string)
        lease.restore()
        XCTAssertEqual(board.string(forType: .string), "external")
    }

    func testCancellationAfterDispatchWaitsBeforeRestoringClipboard() async {
        let driver = FakeInjectionDriver()
        let work = Task { try await TextInjector(driver: driver).inject(text: "hello", target: driver.current) }
        driver.onWait = { tick in if tick == 2 { work.cancel(); driver.apply("hello") } }
        do {
            _ = try await work.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(driver.waits, 21)
        XCTAssertEqual(driver.axWrites, 0)
        XCTAssertEqual(driver.board.restores, 1)
        XCTAssertFalse(driver.isInjecting)
    }

    func testDeniedPermissionDoesNotTouchDestination() async {
        let driver = FakeInjectionDriver()
        driver.authorized = false
        do {
            _ = try await TextInjector(driver: driver).inject(text: "hello", target: driver.current)
            XCTFail("Expected permission error")
        } catch { XCTAssertEqual(error as? MemoEchoError, .accessibilityPermissionDenied) }
        XCTAssertEqual(driver.board.writes, 0)
        XCTAssertEqual(driver.pastes, 0)
    }

    func testSameValueReplacementIsNotMistakenForAcknowledgement() async {
        let driver = FakeInjectionDriver()
        driver.current = FakeInjectionDriver.focus(value: "hello", selection: NSRange(location: 0, length: 5))
        driver.onWait = { tick in if tick == 2 { driver.apply("hello") } }
        await fails(driver)
        XCTAssertEqual(driver.pastes, 1)
        XCTAssertEqual(driver.axWrites, 0)
    }

    private func fails(_ driver: FakeInjectionDriver, target: TextInjectionFocus? = nil) async {
        do {
            _ = try await TextInjector(driver: driver).inject(text: "hello", target: target ?? driver.current)
            XCTFail("Expected unconfirmed/failed output")
        } catch {
            guard case .textInjectionFailure = error as? MemoEchoError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }
}

@MainActor
final class FakeInjectionPasteboard: InjectionPasteboard {
    var changeCount = 0
    var items: InjectionPasteboardSnapshot = [
        [.string: Data("original".utf8), .rtf: Data([1, 2, 3])],
        [.png: Data([4, 5, 6])]
    ]
    var canWrite = true
    var writes = 0
    var restores = 0
    func snapshot() -> InjectionPasteboardSnapshot { items }
    func write(_ text: String) -> Bool {
        writes += 1
        changeCount += 1
        items = canWrite ? [[.string: Data(text.utf8)]] : []
        return canWrite
    }
    func userCopy(_ text: String) { changeCount += 1; items = [[.string: Data(text.utf8)]] }
    func restore(_ snapshot: InjectionPasteboardSnapshot) { restores += 1; changeCount += 1; items = snapshot }
}

@MainActor
final class FakeInjectionDriver: TextInjectionDriver {
    var authorized = true
    var isInjecting = false
    let board = FakeInjectionPasteboard()
    var pasteboard: any InjectionPasteboard { board }
    var canActivate = true
    var canPost = true
    var axUpdatesValue = false
    var pastes = 0
    var axWrites = 0
    var waits = 0
    var current: TextInjectionFocus? = FakeInjectionDriver.focus()
    var onWait: ((Int) -> Void)?
    var onAsyncWait: ((Int) async -> Void)?

    static func focus(value: String = "前后", selection: NSRange = NSRange(location: 1, length: 0),
                      identity: String = "field", readable: Bool = true, composing: Bool = false) -> TextInjectionFocus {
        let id = FocusedElementIdentity(token: identity)
        let snapshot = readable ? FocusedElementTextSnapshot(pid: 42, bundleID: "test", identity: id,
                                                             value: value, selection: selection, isComposing: composing) : nil
        return .init(pid: 42, bundleID: "test", identity: id, snapshot: snapshot)
    }
    func activate(pid: pid_t, bundleID: String?) -> Bool { canActivate }
    func focus(pid: pid_t, bundleID: String?) -> TextInjectionFocus? { current }
    func postPaste(into target: TextInjectionFocus) -> Bool { if canPost { pastes += 1 }; return canPost }
    func insertViaAX(_ text: String, into target: TextInjectionFocus) -> Bool {
        axWrites += 1
        if axUpdatesValue { apply(text) }
        return true
    }
    func wait(milliseconds: Int) async { waits += 1; onWait?(waits); await onAsyncWait?(waits) }
    func apply(_ text: String) {
        guard let before = current?.snapshot, let range = Range(before.selection, in: before.value) else { return }
        current = Self.focus(value: before.value.replacingCharacters(in: range, with: text),
                             selection: NSRange(location: before.selection.location + text.utf16.count, length: 0))
    }
}
