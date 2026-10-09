import AppKit
import XCTest
@testable import MemoEcho

@MainActor
final class TextInjectorTests: XCTestCase {
    func testBackupDeadlineDoesNotBlockMainActorOrAccumulateReads() async throws {
        let worker = ClipboardBackupWorker()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let started = Date()
        await assertBackupThrows({
            try await worker.snapshot(timeout: 0.05) { _ in
                XCTAssertFalse(Thread.isMainThread)
                release.wait()
                return [[.string: Data("late snapshot".utf8)]]
            }
        }) { error in
            XCTAssertEqual(error as? MemoEchoError,
                           .textInjectionFailure(detail: "剪贴板备份超时，请重试或手动复制文本"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        await assertBackupThrows({
            try await worker.snapshot { _ in
                XCTFail("A timed-out system read must not allow more queued reads")
                return []
            }
        }) { error in
            XCTAssertEqual(error as? MemoEchoError,
                           .textInjectionFailure(detail: "剪贴板备份仍在等待，请稍后重试"))
        }
    }

    func testBackupCancellationReturnsWithoutWaitingForSystemRead() async throws {
        let worker = ClipboardBackupWorker()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let entered = expectation(description: "Background read entered")
        let task = Task {
            try await worker.snapshot(timeout: 5) { _ in
                entered.fulfill()
                release.wait()
                return []
            }
        }
        await fulfillment(of: [entered], timeout: 1)
        let started = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }

    func testLateBackupCannotWriteAfterTimeoutAXFallback() async throws {
        let worker = ClipboardBackupWorker()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let returned = expectation(description: "Late read returned")
        let driver = FakeInjectionDriver()
        driver.board.asyncSnapshot = {
            try await worker.snapshot(timeout: 0.05) { _ in
                release.wait()
                returned.fulfill()
                return [[.string: Data("late".utf8)]]
            }
        }
        driver.axUpdatesValue = true
        let original = driver.board.items
        let result = try await TextInjector(driver: driver).inject(text: "hello", target: driver.current)
        XCTAssertEqual(result.path, .axFallback)
        release.signal()
        await fulfillment(of: [returned], timeout: 1)
        XCTAssertEqual(driver.axWrites, 1)
        XCTAssertEqual(driver.pastes, 0)
        XCTAssertEqual(driver.board.writes, 0)
        XCTAssertEqual(driver.board.restores, 0)
        XCTAssertEqual(driver.board.items, original)
    }

    func testStateChangesWhileAwaitingBackupPreventAllWrites() async {
        for mode in 0..<3 {
            let driver = FakeInjectionDriver()
            var active = true
            driver.board.asyncSnapshot = {
                await Task.yield()
                switch mode {
                case 0: active = false
                case 1: driver.current = FakeInjectionDriver.focus(identity: "other")
                default: driver.board.userCopy("newer")
                }
                return [[.string: Data("original".utf8)]]
            }
            do {
                _ = try await TextInjector(driver: driver).inject(text: "hello", target: driver.current,
                                                                shouldContinue: { active })
                XCTFail("Expected invalidated backup")
            } catch {}
            XCTAssertEqual(driver.board.writes, 0)
            XCTAssertEqual(driver.board.restores, 0)
            XCTAssertEqual(driver.pastes, 0)
            XCTAssertEqual(driver.axWrites, 0)
        }
    }

    func testDelayedPasteIsConfirmedWithoutAXRetryAndClipboardRestored() async throws {
        let driver = FakeInjectionDriver()
        let original = driver.board.items
        driver.onWait = { tick in if tick == 5 { driver.apply("hello") } }
        let result = try await TextInjector(driver: driver).inject(
            text: "hello", target: driver.current,
            onUnverifiedPasteDispatched: { XCTFail("Readable fields must keep waiting for confirmation") }
        )
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

    func testBackupFailureUsesVerifiedAXWithoutTouchingClipboard() async throws {
        let driver = FakeInjectionDriver()
        driver.board.snapshotError = .textInjectionFailure(detail: "synthetic backup failure")
        driver.axUpdatesValue = true
        let original = driver.board.items
        var attempts = 0
        let result = try await TextInjector(driver: driver).inject(
            text: "hello", target: driver.current, onOutputAttempt: { attempts += 1 })
        XCTAssertEqual(result.path, .axFallback)
        XCTAssertEqual(result.confirmation, .verified)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(driver.axWrites, 1)
        XCTAssertEqual(driver.pastes, 0)
        XCTAssertEqual(driver.board.writes, 0)
        XCTAssertEqual(driver.board.restores, 0)
        XCTAssertEqual(driver.board.items, original)
    }

    func testBackupFailureAXStillRequiresObservedTextChange() async {
        let driver = FakeInjectionDriver()
        driver.board.snapshotError = .textInjectionFailure(detail: "synthetic backup failure")
        await fails(driver)
        XCTAssertEqual(driver.axWrites, 1)
        XCTAssertEqual(driver.pastes, 0)
        XCTAssertEqual(driver.board.writes, 0)
        XCTAssertEqual(driver.board.restores, 0)
    }

    func testBackupFailureCannotBypassTargetOrClipboardChanges() async {
        for change in 0..<4 {
            let driver = FakeInjectionDriver()
            driver.board.snapshotError = .textInjectionFailure(detail: "synthetic backup failure")
            driver.axUpdatesValue = true
            driver.board.onSnapshot = {
                switch change {
                case 0: driver.current = FakeInjectionDriver.focus(identity: "other")
                case 1: driver.current = FakeInjectionDriver.focus(selection: NSRange(location: 0, length: 0))
                case 2: driver.current = FakeInjectionDriver.focus(composing: true)
                default: driver.board.userCopy("newer copy")
                }
            }
            await fails(driver)
            XCTAssertEqual(driver.axWrites, 0)
            XCTAssertEqual(driver.pastes, 0)
            XCTAssertEqual(driver.board.writes, 0)
            XCTAssertEqual(driver.board.restores, 0)
        }
    }

    func testBackupFailureDoesNotWriteUnreadableTargets() async {
        for window in [false, true] {
            let driver = FakeInjectionDriver()
            driver.current = window ? FakeInjectionDriver.window() : FakeInjectionDriver.focus(readable: false)
            driver.current?.continuity = driver.continuity
            driver.board.snapshotError = .textInjectionFailure(detail: "synthetic backup failure")
            await fails(driver)
            XCTAssertEqual(driver.axWrites, 0)
            XCTAssertEqual(driver.pastes, 0)
            XCTAssertEqual(driver.board.writes, 0)
        }
    }

    func testBackupFailureRespectsSessionCancellationBeforeAX() async {
        let driver = FakeInjectionDriver()
        var active = true
        driver.board.snapshotError = .textInjectionFailure(detail: "synthetic backup failure")
        driver.board.onSnapshot = { active = false }
        do {
            _ = try await TextInjector(driver: driver).inject(text: "hello", target: driver.current,
                                                            shouldContinue: { active })
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(driver.axWrites, 0)
        XCTAssertEqual(driver.board.writes, 0)
    }

    func testNativeUnreadableClipboardCanUseAXWithoutReplacingOriginal() async throws {
        let board = NSPasteboard(name: .init("MemoEcho-output-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.declareTypes([.html], owner: nil)
        let count = board.changeCount
        let driver = FakeInjectionDriver()
        driver.pasteboardOverride = NativeInjectionPasteboard(board: board)
        driver.axUpdatesValue = true
        let result = try await TextInjector(driver: driver).inject(text: "hello", target: driver.current)
        XCTAssertEqual(result.path, .axFallback)
        XCTAssertEqual(driver.axWrites, 1)
        XCTAssertEqual(driver.pastes, 0)
        XCTAssertEqual(board.changeCount, count)
        XCTAssertTrue(board.types?.contains(.html) == true)
    }

    func testAXSuccessCodeWithoutTextChangeDoesNotReportSuccess() async {
        let driver = FakeInjectionDriver()
        driver.canPost = false
        await fails(driver)
        XCTAssertEqual(driver.axWrites, 1)
    }

    func testUnreadableFieldPastesOnceButDoesNotClaimConfirmation() async throws {
        let driver = FakeInjectionDriver()
        driver.current = FakeInjectionDriver.focus(readable: false)
        let result = try await TextInjector(driver: driver).inject(text: "hello", target: driver.current)
        XCTAssertEqual(result.confirmation, .dispatched)
        XCTAssertNil(result.beforeInjection)
        XCTAssertEqual(driver.pastes, 1)
        XCTAssertEqual(driver.axWrites, 0)
        XCTAssertEqual(driver.waits, 21)
        XCTAssertEqual(driver.board.restores, 1)
    }

    func testCapturedReadableFieldCannotBecomeUnverified() async throws {
        let driver = FakeInjectionDriver()
        let target = try XCTUnwrap(TextInjector(driver: driver).captureTarget(pid: 42, bundleID: "test"))
        driver.current = FakeInjectionDriver.focus(readable: false)
        await fails(driver, target: target)
        XCTAssertEqual(driver.board.writes, 0)
        XCTAssertEqual(driver.pastes, 0)
    }

    func testUnreadableFieldCannotReportDispatchAfterCompositionStarts() async {
        let driver = FakeInjectionDriver()
        driver.current = FakeInjectionDriver.focus(readable: false)
        driver.onWait = { tick in if tick == 2 { driver.current = FakeInjectionDriver.focus(composing: true) } }
        await fails(driver)
        XCTAssertEqual(driver.pastes, 1)
        XCTAssertEqual(driver.axWrites, 0)
    }

    func testWindowTargetPastesOnceWithoutActivatingAndRestoresClipboard() async throws {
        let driver = FakeInjectionDriver()
        driver.current = FakeInjectionDriver.window()
        let injector = TextInjector(driver: driver)
        let target = try XCTUnwrap(injector.captureTarget(pid: 42, bundleID: "test"))
        let result = try await injector.inject(text: "hello", target: target)
        XCTAssertEqual(result.confirmation, .dispatched)
        XCTAssertNil(result.beforeInjection)
        XCTAssertEqual(driver.activations, 0)
        XCTAssertEqual(driver.pastes, 1)
        XCTAssertEqual(driver.axWrites, 0)
        XCTAssertEqual(driver.waits, 21)
        XCTAssertEqual(driver.board.restores, 1)
    }

    func testWindowSwitchAndReturnPermanentlyPreventsPaste() async throws {
        let driver = FakeInjectionDriver()
        driver.current = FakeInjectionDriver.window()
        let injector = TextInjector(driver: driver)
        let target = try XCTUnwrap(injector.captureTarget(pid: 42, bundleID: "test"))
        driver.continuity.invalidate()
        await fails(driver, target: target)
        XCTAssertEqual(driver.activations, 0)
        XCTAssertEqual(driver.board.writes, 0)
        XCTAssertEqual(driver.pastes, 0)
    }

    func testWindowWithoutMonitorCannotBeCaptured() {
        let driver = FakeInjectionDriver()
        driver.current = FakeInjectionDriver.window()
        driver.canMonitor = false
        XCTAssertNil(TextInjector(driver: driver).captureTarget(pid: 42, bundleID: "test"))
    }

    func testWindowChangeDuringClipboardPropagationPreventsPaste() async throws {
        let driver = FakeInjectionDriver()
        driver.current = FakeInjectionDriver.window()
        let target = try XCTUnwrap(TextInjector(driver: driver).captureTarget(pid: 42, bundleID: "test"))
        driver.onWait = { _ in driver.continuity.invalidate() }
        await fails(driver, target: target)
        XCTAssertEqual(driver.pastes, 0)
        XCTAssertEqual(driver.board.restores, 1)
    }

    func testFieldDisappearanceCannotDowngradeToWindow() async {
        let driver = FakeInjectionDriver()
        let target = driver.current
        driver.current = FakeInjectionDriver.window()
        await fails(driver, target: target)
        XCTAssertEqual(driver.pastes, 0)
        XCTAssertEqual(driver.board.writes, 0)
    }

    func testWindowEventFailureDoesNotAttemptAX() async throws {
        let driver = FakeInjectionDriver()
        driver.current = FakeInjectionDriver.window()
        let target = try XCTUnwrap(TextInjector(driver: driver).captureTarget(pid: 42, bundleID: "test"))
        driver.canPost = false
        await fails(driver, target: target)
        XCTAssertEqual(driver.pastes, 0)
        XCTAssertEqual(driver.axWrites, 0)
        XCTAssertEqual(driver.board.restores, 1)
    }

    func testWindowLossAfterDispatchDrainsWithoutRetryOrConfirmation() async throws {
        let driver = FakeInjectionDriver()
        driver.current = FakeInjectionDriver.window()
        let target = try XCTUnwrap(TextInjector(driver: driver).captureTarget(pid: 42, bundleID: "test"))
        driver.onWait = { tick in if tick == 2 { driver.continuity.invalidate() } }
        await fails(driver, target: target)
        XCTAssertEqual(driver.pastes, 1)
        XCTAssertEqual(driver.axWrites, 0)
        XCTAssertEqual(driver.waits, 21)
        XCTAssertEqual(driver.board.restores, 1)
    }

    func testWindowPastePreservesLaterUserCopy() async throws {
        let driver = FakeInjectionDriver()
        driver.current = FakeInjectionDriver.window()
        let injector = TextInjector(driver: driver)
        let target = try XCTUnwrap(injector.captureTarget(pid: 42, bundleID: "test"))
        driver.onWait = { tick in if tick == 2 { driver.board.userCopy("new copy") } }
        let result = try await injector.inject(text: "hello", target: target)
        XCTAssertEqual(result.confirmation, .dispatched)
        XCTAssertEqual(driver.board.restores, 0)
        XCTAssertEqual(driver.board.items, [[.string: Data("new copy".utf8)]])
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

    func testLeaseRestoresAllItemsOnceAndDoesNotOverwriteLaterCopy() async throws {
        let board = FakeInjectionPasteboard()
        let original = board.items
        let lease = try await InjectionPasteboardLease(pasteboard: board)
        XCTAssertTrue(lease.write("transient"))
        lease.restore()
        XCTAssertEqual(board.items, original)
        board.userCopy("later")
        lease.restore()
        XCTAssertEqual(board.restores, 1)
        XCTAssertEqual(board.items, [[.string: Data("later".utf8)]])
    }

    func testNativePasteboardMarksTemporaryTextForClipboardHistoryExclusion() async throws {
        let board = NSPasteboard(name: NSPasteboard.Name("MemoEcho-output-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let adapter = NativeInjectionPasteboard(board: board)
        XCTAssertTrue(adapter.write("synthetic recognition result"))

        let item = try XCTUnwrap(board.pasteboardItems?.first)
        XCTAssertEqual(board.pasteboardItems?.count, 1)
        XCTAssertEqual(item.string(forType: .string), "synthetic recognition result")
        // Clipboard historians such as Maccy skip these non-user-copy types.
        XCTAssertTrue(item.types.contains(.init("org.nspasteboard.TransientType")))
        XCTAssertTrue(item.types.contains(.init("org.nspasteboard.AutoGeneratedType")))
    }

    func testNativePasteboardRestoresInitiallyEmptyClipboard() async throws {
        let board = NSPasteboard(name: NSPasteboard.Name("MemoEcho-output-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let adapter = NativeInjectionPasteboard(board: board)
        let lease = try await InjectionPasteboardLease(pasteboard: adapter)
        XCTAssertTrue(lease.write("transient"))
        lease.restore()
        let snapshotResult442 = try await adapter.snapshot()
        XCTAssertEqual(snapshotResult442, [])
        XCTAssertNil(board.string(forType: .string))
    }

    func testNativePasteboardRestoresMultipleItemsAndFormats() async throws {
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
        let snapshot = try await adapter.snapshot()
        let lease = try await InjectionPasteboardLease(pasteboard: adapter)
        XCTAssertTrue(lease.write("transient"))
        lease.restore()
        let snapshotResult466 = try await adapter.snapshot()
        XCTAssertEqual(snapshotResult466, snapshot)
        XCTAssertEqual(board.pasteboardItems?.count, 2)
    }

    func testNativePasteboardPreservesExternalWrite() async throws {
        let board = NSPasteboard(name: NSPasteboard.Name("MemoEcho-output-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let lease = try await InjectionPasteboardLease(pasteboard: NativeInjectionPasteboard(board: board))
        XCTAssertTrue(lease.write("transient"))
        board.clearContents()
        board.setString("external", forType: .string)
        lease.restore()
        XCTAssertEqual(board.string(forType: .string), "external")
    }

    func testNativeClipboardMissingFormatsAllowInjectionAndRestoreReadableContent() async throws {
        let missingTypes: [NSPasteboard.PasteboardType] = [
            .html, .rtf, .png, .fileURL,
            .init("org.nspasteboard.source"),
            .init("com.memoecho.test.private-format")
        ]
        for type in missingTypes {
            let board = NSPasteboard(name: .init("MemoEcho-output-test-\(UUID().uuidString)"))
            defer { board.releaseGlobally() }
            board.declareTypes([.string, type], owner: nil)
            XCTAssertTrue(board.setString("synthetic original", forType: .string))
            XCTAssertTrue(try XCTUnwrap(board.pasteboardItems?.first).types.contains(type))
            let driver = FakeInjectionDriver()
            driver.pasteboardOverride = NativeInjectionPasteboard(board: board)
            driver.onWait = { tick in if tick == 2 { driver.apply("synthetic output") } }
            _ = try await TextInjector(driver: driver).inject(text: "synthetic output", target: driver.current)
            XCTAssertEqual(driver.pastes, 1)
            XCTAssertEqual(driver.axWrites, 0)
            XCTAssertFalse(driver.isInjecting)
            XCTAssertEqual(board.string(forType: .string), "synthetic original")
        }
    }

    func testNativeClipboardEmptyMarkersAreReadableAndRoundTrip() async throws {
        let board = NSPasteboard(name: .init("MemoEcho-output-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString("synthetic original", forType: .string)
        let markers: [NSPasteboard.PasteboardType] = [
            .init("org.nspasteboard.TransientType"), .init("org.nspasteboard.AutoGeneratedType"),
            .init("org.nspasteboard.source"), .init("org.p0deje.Maccy")
        ]
        for type in markers { XCTAssertTrue(item.setData(Data(), forType: type)) }
        XCTAssertTrue(board.writeObjects([item]))
        let adapter = NativeInjectionPasteboard(board: board)
        let original = try await adapter.snapshot()
        for type in markers { XCTAssertEqual(original.first?[type], Data()) }
        let lease = try await InjectionPasteboardLease(pasteboard: adapter)
        XCTAssertTrue(lease.write("synthetic output"))
        lease.restore()
        let snapshotResult522 = try await adapter.snapshot()
        XCTAssertEqual(snapshotResult522, original)
    }

    func testNativeClipboardOpaquePrivateHTMLAndPNGBytesCanBeBackedUp() async throws {
        let board = NSPasteboard(name: .init("MemoEcho-output-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let item = NSPasteboardItem()
        let types: [NSPasteboard.PasteboardType] = [.html, .png, .init("com.memoecho.test.private-format")]
        let invalidPayload = Data([0xff, 0x00, 0xfe])
        for type in types { XCTAssertTrue(item.setData(invalidPayload, forType: type)) }
        XCTAssertTrue(board.writeObjects([item]))
        let snapshot = try await NativeInjectionPasteboard(board: board).snapshot()
        for type in types { XCTAssertEqual(snapshot.first?[type], invalidPayload) }
    }

    func testNativeClipboardMalformedRTFExposesUnreadableSystemDerivedTextFormats() async throws {
        let board = NSPasteboard(name: .init("MemoEcho-output-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let item = NSPasteboardItem()
        let invalidRTF = Data([0xff, 0x00, 0xfe])
        XCTAssertTrue(item.setData(invalidRTF, forType: .rtf))
        XCTAssertEqual(item.types, [.rtf])
        XCTAssertTrue(board.writeObjects([item]))
        let published = try XCTUnwrap(board.pasteboardItems?.first)
        XCTAssertEqual(published.data(forType: .rtf), invalidRTF)
        // AppKit advertises derived plain-text types even when RTF conversion fails.
        XCTAssertTrue(published.types.contains(.string))
        XCTAssertNil(published.data(forType: .string))
        let adapter = NativeInjectionPasteboard(board: board)
        let lease = try await InjectionPasteboardLease(pasteboard: adapter)
        XCTAssertTrue(lease.write("synthetic output"))
        lease.restore()
        XCTAssertEqual(board.data(forType: .rtf), invalidRTF)
    }

    func testNativeClipboardHistoryStyleNilSetDataCreatesReadableEmptyRepresentation() async throws {
        let board = NSPasteboard(name: .init("MemoEcho-output-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        XCTAssertTrue(board.setData(Data("synthetic original".utf8), forType: .string))
        XCTAssertTrue(board.setData(nil, forType: .html))
        XCTAssertTrue(board.setString("", forType: .init("org.p0deje.Maccy")))
        XCTAssertTrue(board.setString("com.memoecho.test.source", forType: .init("org.nspasteboard.source")))
        let snapshot = try await NativeInjectionPasteboard(board: board).snapshot()
        XCTAssertEqual(snapshot.first?[.html], Data())
        XCTAssertEqual(snapshot.first?[.init("org.p0deje.Maccy")], Data())
    }

    func testNativeClipboardPromisedDataProvidedOnDemandBacksUp() async throws {
        let board = NSPasteboard(name: .init("MemoEcho-output-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let provider = SyntheticClipboardDataProvider { _, item, type in
            item.setData(Data("<b>synthetic</b>".utf8), forType: type)
        }
        let item = NSPasteboardItem()
        item.setString("synthetic", forType: .string)
        XCTAssertTrue(item.setDataProvider(provider, forTypes: [.html]))
        XCTAssertTrue(board.writeObjects([item]))
        XCTAssertEqual(provider.calls, 0)
        let snapshot = try await NativeInjectionPasteboard(board: board).snapshot()
        XCTAssertEqual(provider.calls, 1)
        XCTAssertEqual(snapshot.first?[.html], Data("<b>synthetic</b>".utf8))
    }

    func testNativeClipboardUnfulfilledPromiseInSecondItemFailsWithoutChangingClipboard() async throws {
        let board = NSPasteboard(name: .init("MemoEcho-output-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let provider = SyntheticClipboardDataProvider { _, _, _ in }
        let first = NSPasteboardItem()
        first.setString("synthetic original", forType: .string)
        let second = NSPasteboardItem()
        XCTAssertTrue(second.setDataProvider(provider, forTypes: [.png]))
        XCTAssertTrue(board.writeObjects([first, second]))
        let changeCount = board.changeCount
        await assertBackupThrows({ try await NativeInjectionPasteboard(board: board).snapshot() }) { error in
            XCTAssertEqual(error as? MemoEchoError,
                           .textInjectionFailure(detail: "无法备份当前剪贴板，请手动复制文本"))
        }
        XCTAssertEqual(provider.calls, 1)
        XCTAssertEqual(board.changeCount, changeCount)
        XCTAssertEqual(board.pasteboardItems?.count, 2)
        XCTAssertEqual(board.string(forType: .string), "synthetic original")
    }

    func testNativeClipboardReplacementDuringPromisedReadPreservesNewCopy() async throws {
        let board = NSPasteboard(name: .init("MemoEcho-output-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let provider = SyntheticClipboardDataProvider { _, _, _ in
            board.clearContents()
            board.setString("synthetic newer copy", forType: .string)
        }
        let item = NSPasteboardItem()
        item.setString("synthetic original", forType: .string)
        XCTAssertTrue(item.setDataProvider(provider, forTypes: [.html]))
        XCTAssertTrue(board.writeObjects([item]))
        let changeCount = board.changeCount
        await assertBackupThrows({ try await InjectionPasteboardLease(pasteboard: NativeInjectionPasteboard(board: board)) }) { error in
            XCTAssertEqual(error as? MemoEchoError,
                           .textInjectionFailure(detail: "剪贴板正在变化，请重试"))
        }
        XCTAssertEqual(provider.calls, 1)
        XCTAssertNotEqual(board.changeCount, changeCount)
        XCTAssertEqual(board.string(forType: .string), "synthetic newer copy")
    }

    func testNativeClipboardMarkersAloneDoNotMakeMissingContentRecoverable() async throws {
        let board = NSPasteboard(name: .init("MemoEcho-output-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let provider = SyntheticClipboardDataProvider { _, _, _ in }
        let item = NSPasteboardItem()
        item.setData(Data(), forType: .init("org.nspasteboard.TransientType"))
        item.setString("synthetic source", forType: .init("org.nspasteboard.source"))
        item.setDataProvider(provider, forTypes: [.html])
        XCTAssertTrue(board.writeObjects([item]))
        let count = board.changeCount
        await assertBackupThrows({ try await InjectionPasteboardLease(pasteboard: NativeInjectionPasteboard(board: board)) })
        XCTAssertEqual(board.changeCount, count)
    }

    func testNativeClipboardEmptyContentAndPrivateFormatsRoundTrip() async throws {
        let board = NSPasteboard(name: .init("MemoEcho-output-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let first = NSPasteboardItem()
        first.setData(Data(), forType: .string)
        let second = NSPasteboardItem()
        let custom = NSPasteboard.PasteboardType("com.memoecho.test.opaque")
        second.setData(Data([0xff, 0x00]), forType: custom)
        let provider = SyntheticClipboardDataProvider { _, _, _ in }
        second.setDataProvider(provider, forTypes: [.html])
        XCTAssertTrue(board.writeObjects([first, second]))
        let adapter = NativeInjectionPasteboard(board: board)
        let lease = try await InjectionPasteboardLease(pasteboard: adapter)
        XCTAssertTrue(lease.write("synthetic output"))
        lease.restore()
        let restored = try await adapter.snapshot()
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored.first?[.string], Data())
        XCTAssertEqual(restored.last?[custom], Data([0xff, 0x00]))
    }

    func testNativePartialBackupPreservesNewCopyDuringInjection() async throws {
        let board = NSPasteboard(name: .init("MemoEcho-output-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.declareTypes([.string, .html], owner: nil)
        board.setString("synthetic original", forType: .string)
        let driver = FakeInjectionDriver()
        driver.pasteboardOverride = NativeInjectionPasteboard(board: board)
        driver.onWait = { tick in
            if tick == 2 {
                driver.apply("synthetic output")
                board.clearContents()
                board.setString("synthetic newer copy", forType: .string)
            }
        }
        _ = try await TextInjector(driver: driver).inject(text: "synthetic output", target: driver.current)
        XCTAssertEqual(driver.pastes, 1)
        XCTAssertEqual(board.string(forType: .string), "synthetic newer copy")
    }

    func testNativeClipboardRetriesFailUntilMissingDataIsReplaced() async throws {
        let board = NSPasteboard(name: .init("MemoEcho-output-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.declareTypes([.html], owner: nil)
        let adapter = NativeInjectionPasteboard(board: board)
        for _ in 0..<3 {
            await assertBackupThrows({ try await adapter.snapshot() }) { error in
                XCTAssertEqual(error as? MemoEchoError,
                               .textInjectionFailure(detail: "无法备份当前剪贴板，请手动复制文本"))
            }
        }
        board.clearContents()
        board.setString("synthetic new plain text", forType: .string)
        let snapshotResult694 = try await adapter.snapshot()
        XCTAssertEqual(snapshotResult694, [[.string: Data("synthetic new plain text".utf8)]])
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

    private func assertBackupThrows<T>(_ operation: () async throws -> T,
                                      verify: (Error) -> Void = { _ in },
                                      file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await operation()
            XCTFail("Expected backup failure", file: file, line: line)
        } catch { verify(error) }
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

/// Supplies synthetic promised data on an isolated, named pasteboard only.
private final class SyntheticClipboardDataProvider: NSObject, NSPasteboardItemDataProvider {
    var calls = 0
    let provide: (NSPasteboard?, NSPasteboardItem, NSPasteboard.PasteboardType) -> Void

    init(provide: @escaping (NSPasteboard?, NSPasteboardItem, NSPasteboard.PasteboardType) -> Void) {
        self.provide = provide
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        calls += 1
        provide(pasteboard, item, type)
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
    var snapshotError: MemoEchoError?
    var onSnapshot: (() -> Void)?
    var asyncSnapshot: (() async throws -> InjectionPasteboardSnapshot)?
    func snapshot() async throws -> InjectionPasteboardSnapshot {
        if let asyncSnapshot { return try await asyncSnapshot() }
        onSnapshot?()
        if let snapshotError { throw snapshotError }
        return items
    }
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
    var pasteboardOverride: (any InjectionPasteboard)?
    var pasteboard: any InjectionPasteboard { pasteboardOverride ?? board }
    var activations = 0
    var canMonitor = true
    let continuity = InjectionTargetContinuity()
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
    static func window(identity: String = "window") -> TextInjectionFocus {
        .init(pid: 42, bundleID: "test", identity: .init(token: identity), snapshot: nil, scope: .window)
    }
    func monitorWindow(_ target: TextInjectionFocus) -> InjectionTargetContinuity? { canMonitor ? continuity : nil }
    func activate(pid: pid_t, bundleID: String?) -> Bool { activations += 1; return canActivate }
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
