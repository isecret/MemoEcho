import AppKit
import SwiftUI
import XCTest
@testable import MemoEcho

@MainActor
final class SettingsWindowLayoutTests: XCTestCase {
    func testContentStaysAtTopWhileWindowStillHasPreviousPageHeight() async {
        let fixture = Fixture(appliesMeasurements: false)
        defer { fixture.window.close() }
        fixture.window.setContentSize(NSSize(width: 576, height: 420))
        fixture.show(.asr, height: 180)
        await settle(fixture)
        XCTAssertEqual(fixture.model.contentFrame.minY, 0, accuracy: 0.5)
        XCTAssertEqual(fixture.model.contentFrame.height, 180, accuracy: 0.5)
        XCTAssertEqual(fixture.window.contentLayoutRect.height, 420, accuracy: 0.5)
    }

    func testEqualHeightTabsStillProduceTheirOwnMeasurement() async {
        let fixture = Fixture()
        defer { fixture.window.close() }
        fixture.show(.asr, height: 180)
        await settle(fixture)
        fixture.show(.ai, height: 180)
        await settle(fixture)
        XCTAssertEqual(fixture.model.measurements.last?.tab, .ai)
        XCTAssertEqual(fixture.window.contentLayoutRect.height, 180, accuracy: 0.5)
    }

    func testLateMeasurementAndQueuedResizeCannotOverwriteCurrentTab() async {
        let layout = SettingsWindowLayout()
        let window = NSWindow(contentRect: NSRect(x: 10, y: 100, width: 576, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        layout.attach(window)
        let top = window.frame.maxY
        layout.select(.asr)
        layout.measure(.init(tab: .asr, size: CGSize(width: 576, height: 360)))
        layout.select(.ai)
        layout.measure(.init(tab: .ai, size: CGSize(width: 576, height: 210)))
        layout.measure(.init(tab: .asr, size: CGSize(width: 576, height: 480)))
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(window.contentLayoutRect.height, 210, accuracy: 0.5)
        XCTAssertEqual(window.frame.maxY, top, accuracy: 0.5)
        XCTAssertEqual(window.title, "模型")
    }

    func testRepeatedSwitchesAndAsyncContentChangesFitWindowWithoutTopGap() async {
        let fixture = Fixture()
        defer { fixture.window.close() }
        await settle(fixture)
        let top = fixture.window.frame.maxY
        for (tab, height): (SettingsTab, CGFloat) in [(.asr, 180), (.ai, 280), (.asr, 180),
                                                     (.ai, 240), (.ai, 275), (.asr, 180)] {
            fixture.show(tab, height: height)
            await settle(fixture)
            XCTAssertEqual(fixture.window.contentLayoutRect.height, height, accuracy: 0.5)
            XCTAssertEqual(fixture.model.contentFrame.minY, 0, accuracy: 0.5)
            XCTAssertEqual(fixture.window.frame.maxY, top, accuracy: 0.5)
        }
    }

    private func settle(_ fixture: Fixture) async {
        for _ in 0..<6 {
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor @Observable final class Model {
        var tab: SettingsTab = .general
        var height: CGFloat = 320
        var contentFrame = CGRect.zero
        var measurements: [SettingsPageMeasurement] = []
    }

    @MainActor private final class Fixture {
        let model = Model()
        let layout = SettingsWindowLayout()
        let window: NSWindow
        init(appliesMeasurements: Bool = true) {
            let host = SettingsWindowLayout.makeHostingController(rootView: Probe(
                model: model, onMeasure: { [model, layout] measurement in
                    model.measurements.append(measurement)
                    if appliesMeasurements { layout.measure(measurement) }
                }
            ))
            window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.toolbarStyle = .preference
            window.toolbar = NSToolbar(identifier: "SettingsWindowLayoutTests")
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 576, height: 320))
            layout.attach(window)
        }
        func show(_ tab: SettingsTab, height: CGFloat) {
            layout.select(tab)
            model.tab = tab
            model.height = height
        }
    }

    private struct Probe: View {
        let model: Model
        let onMeasure: (SettingsPageMeasurement) -> Void
        var body: some View {
            SettingsWindowContent(tab: model.tab, onMeasure: onMeasure) {
                Color.clear.frame(width: 576, height: model.height)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: ContentFrameKey.self,
                                                   value: proxy.frame(in: .named("viewport")))
                        }
                    }
            }
            .coordinateSpace(name: "viewport")
            .onPreferenceChange(ContentFrameKey.self) { model.contentFrame = $0 }
        }
    }

    private struct ContentFrameKey: PreferenceKey {
        static let defaultValue = CGRect.zero
        static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
    }
}
