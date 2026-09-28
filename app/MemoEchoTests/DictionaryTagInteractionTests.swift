import AppKit
import SwiftUI
import XCTest
@testable import MemoEcho

@MainActor
final class DictionaryTagInteractionTests: XCTestCase {
    func testSingleClickSelectsWithoutWaitingForDoubleClickTimeout() async throws {
        let fixture = Fixture()
        defer { fixture.window.close() }
        await fixture.ready()
        await fixture.click(at: NSPoint(x: 15, y: fixture.host.bounds.midY))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fixture.selections, 1, "Highlight must not wait for the double-click interval")
        XCTAssertEqual(fixture.edits, 0)
        XCTAssertEqual(fixture.deletions, 0)
    }

    func testDoubleClickStillEditsAfterImmediateSelection() async throws {
        let fixture = Fixture()
        defer { fixture.window.close() }
        await fixture.ready()
        let point = NSPoint(x: 15, y: fixture.host.bounds.midY)
        await fixture.click(at: point)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(fixture.selections, 1)
        await fixture.click(at: point, count: 2)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fixture.edits, 1)
        XCTAssertEqual(fixture.deletions, 0)
    }

    func testDeleteButtonDoesNotTriggerSelectionOrEditor() async throws {
        let fixture = Fixture()
        defer { fixture.window.close() }
        await fixture.ready()
        await fixture.click(at: NSPoint(x: fixture.host.bounds.maxX - 14, y: fixture.host.bounds.midY))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fixture.deletions, 1)
        XCTAssertEqual(fixture.selections, 0)
        XCTAssertEqual(fixture.edits, 0)
    }

    func testKeyboardNavigationScrollsOnlyEnoughToKeepTagsOutsideFade() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DictionaryScroll-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersonalDictionaryStore(directoryURL: directory)
        for index in 0..<60 {
            try store.addEntry(.init(term: String(format: "滚动验证词条%02d", index)))
        }
        let host = NSHostingView(rootView: PersonalDictionarySettingsView(dictionaryStore: store))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 520, height: 420),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setContentSize(host.fittingSize)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        func settle() async {
            for _ in 0..<4 {
                host.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { descendants($0) }
        }
        await settle()
        let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first)
        let document = try XCTUnwrap(scroll.documentView)
        // These native text hit targets share the full tag's vertical bounds.
        let tags = descendants(document)
            .filter { String(reflecting: type(of: $0)).hasSuffix(".ClickView") }
            .sorted {
                let a = $0.convert($0.bounds, to: document)
                let b = $1.convert($1.bounds, to: document)
                return abs(a.minY - b.minY) > 1 ? a.minY < b.minY : a.minX < b.minX
            }
        XCTAssertEqual(tags.count, 60)
        guard let first = tags.first else { return }
        let point = first.convert(NSPoint(x: 15, y: first.bounds.midY), to: nil)
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            NSApp.sendEvent(event)
            await settle()
        }

        var scrollChanges = 0
        var stationaryMoves = 0
        for (indices, keyCode, character) in [
            (Array(1..<60), UInt16(124), "\u{F703}"),
            (Array((0..<59).reversed()), UInt16(123), "\u{F702}")
        ] {
            for index in indices {
                let before = scroll.contentView.bounds.minY
                let frame = tags[index].convert(tags[index].bounds, to: document)
                let visibleTop = before + 12
                let visibleBottom = before + scroll.contentView.bounds.height - 12
                let expected: CGFloat
                if frame.minY < visibleTop - 0.5 {
                    expected = frame.minY - 12
                } else if frame.maxY > visibleBottom + 0.5 {
                    expected = frame.maxY - scroll.contentView.bounds.height + 12
                } else {
                    expected = before
                }
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: character,
                    charactersIgnoringModifiers: character, isARepeat: false, keyCode: keyCode))
                NSApp.sendEvent(event)
                await settle()
                let after = scroll.contentView.bounds.minY
                XCTAssertEqual(after, expected, accuracy: 1, "Target \(index), key \(keyCode)")
                XCTAssertGreaterThanOrEqual(frame.minY - after, 11)
                XCTAssertLessThanOrEqual(frame.maxY - after, scroll.contentView.bounds.height - 11)
                if abs(expected - before) > 1 { scrollChanges += 1 }
                else { stationaryMoves += 1 }
            }
        }
        XCTAssertGreaterThan(scrollChanges, 0, "Keyboard events must actually advance selection and scroll")
        XCTAssertGreaterThan(stationaryMoves, 0, "Visible tags must not cause scrolling")
    }

    @MainActor private final class Fixture {
        var selections = 0
        var edits = 0
        var deletions = 0
        var host: NSHostingView<DictionaryTagView>!
        let window: NSWindow

        init() {
            window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 150, height: 30),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            host = NSHostingView(rootView: DictionaryTagView(
                term: "MemoEcho", isAutoLearned: false, isSelected: false,
                onSelect: { [weak self] in self?.selections += 1 },
                onEdit: { [weak self] in self?.edits += 1 },
                onDelete: { [weak self] in self?.deletions += 1 }
            ))
            window.contentView = host
            window.setContentSize(host.fittingSize)
            window.makeKeyAndOrderFront(nil)
        }

        func ready() async {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
        }

        func click(at point: NSPoint, count: Int = 1) async {
            let point = host.convert(point, to: nil)
            for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil,
                                              eventNumber: count, clickCount: count, pressure: 1)!
                NSApp.sendEvent(event)
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }
}
