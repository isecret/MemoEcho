import AppKit
import SwiftUI

/// The single owner of settings window height. SwiftUI only reports form sizes.
@MainActor
final class SettingsWindowLayout {
    private(set) var selectedTab: SettingsTab = .general
    private var sizes: [SettingsTab: NSSize] = [:]
    private weak var window: NSWindow?
    private var pendingResize: DispatchWorkItem?
    private var revision = 0

    var contentSize: NSSize { sizes[selectedTab] ?? selectedTab.defaultContentSize }

    static func makeHostingController<Content: View>(rootView: Content) -> NSHostingController<Content> {
        let controller = NSHostingController(rootView: rootView)
        // Default min/max/intrinsic sizing competes with the measured window frame.
        controller.sizingOptions = []
        return controller
    }

    func attach(_ window: NSWindow) {
        self.window = window
        window.title = selectedTab.title
        if let size = sizes[selectedTab] { measure(.init(tab: selectedTab, size: size)) }
    }

    func select(_ tab: SettingsTab) {
        guard selectedTab != tab else { return }
        selectedTab = tab
        revision += 1
        pendingResize?.cancel()
        pendingResize = nil
        window?.title = tab.title
        // Wait for a measurement carrying this tab's identity, even for equal heights.
    }

    func measure(_ measurement: SettingsPageMeasurement) {
        guard measurement.tab == selectedTab,
              measurement.size.width.isFinite, measurement.size.height.isFinite,
              measurement.size.width > 0, measurement.size.height > 0 else { return }
        let size = NSSize(width: ceil(measurement.size.width), height: ceil(measurement.size.height))
        sizes[measurement.tab] = size
        revision += 1
        let measuredRevision = revision
        pendingResize?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.revision == measuredRevision,
                  self.selectedTab == measurement.tab, let window = self.window else { return }
            self.pendingResize = nil
            let oldFrame = window.frame
            let frameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
            guard abs(oldFrame.width - frameSize.width) > 0.5
                    || abs(oldFrame.height - frameSize.height) > 0.5 else { return }
            let frame = NSRect(x: oldFrame.minX, y: oldFrame.maxY - frameSize.height,
                               width: frameSize.width, height: frameSize.height)
            // Resize atomically: animated setFrame can re-enter layout with old bounds.
            window.setFrame(frame, display: true, animate: false)
        }
        pendingResize = item
        DispatchQueue.main.async(execute: item)
    }
}
