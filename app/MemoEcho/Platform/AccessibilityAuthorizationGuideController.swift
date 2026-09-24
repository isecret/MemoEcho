import AppKit
import ApplicationServices
import SwiftUI

/// A small, non-activating guide over System Settings. Dropping the app does not imply authorization.
@MainActor
final class AccessibilityAuthorizationGuideController {
    private weak var originWindow: NSWindow?
    private var panel: NSPanel?
    private var placementTask: Task<Void, Never>?
    private let permissionsManager: PermissionsManager
    private let onAppDroppedIntoSettings: @MainActor () -> Void

    init(permissionsManager: PermissionsManager, onAppDroppedIntoSettings: @escaping @MainActor () -> Void) {
        self.permissionsManager = permissionsManager
        self.onAppDroppedIntoSettings = onAppDroppedIntoSettings
    }

    @discardableResult
    func present(originWindow: NSWindow?) -> Bool {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
              NSWorkspace.shared.open(url) else { return false }
        if panel != nil { dismiss() }
        self.originWindow = originWindow
        let view = AccessibilityGuideView(
            appURL: Bundle.main.bundleURL,
            onClose: { [weak self] in self?.dismiss() },
            onDragEnded: { [weak self] point, operation in
                guard let self,
                      Self.shouldDismissAfterDrop(at: point, operation: operation,
                                                  settingsFrame: Self.systemSettingsFrame(),
                                                  settingsIsFrontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                                                      == "com.apple.systempreferences") else { return }
                self.onAppDroppedIntoSettings()
                self.dismiss()
            }
        )
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: AccessibilityGuideView.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = NSHostingView(rootView: view)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        self.panel = panel

        placementTask = Task { [weak self] in
            var attempts = 0
            while let self, !Task.isCancelled, self.panel != nil {
                attempts += 1
                let settingsFrame = Self.systemSettingsFrame()
                if settingsFrame != nil || attempts >= 12 {
                    self.positionPanel(against: settingsFrame)
                    self.panel?.orderFrontRegardless()
                    return
                }
                try? await Task.sleep(for: .milliseconds(350))
            }
        }
        return true
    }

    func dismiss() {
        placementTask?.cancel()
        placementTask = nil
        panel?.close()
        panel = nil
        permissionsManager.cancelAccessibilityGuide()
        originWindow = nil
    }

    private func positionPanel(against settingsFrame: NSRect?) {
        guard let panel else { return }
        guard let screen = NSScreen.screens.first(where: { screen in
            settingsFrame.map { screen.frame.intersects($0) } ?? false
        }) ?? originWindow?.screen ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        let anchor = settingsFrame ?? originWindow?.frame ?? area
        panel.setFrameOrigin(Self.panelOrigin(for: anchor, visibleFrame: area, size: panel.frame.size))
    }

    /// Place once near the lower edge; moving System Settings later does not move the guide.
    static func panelOrigin(for anchor: NSRect, visibleFrame: NSRect, size: NSSize) -> NSPoint {
        NSPoint(
            x: min(max(anchor.midX - size.width / 2, visibleFrame.minX), visibleFrame.maxX - size.width),
            y: min(max(anchor.minY + 24, visibleFrame.minY), visibleFrame.maxY - size.height)
        )
    }

    static func shouldDismissAfterDrop(at point: NSPoint, operation: NSDragOperation,
                                       settingsFrame: NSRect?, settingsIsFrontmost: Bool = false) -> Bool {
        if let settingsFrame { return settingsFrame.contains(point) }
        return settingsIsFrontmost && operation != []
    }

    /// Window-owner metadata and bounds are sufficient; no screen contents are captured.
    private static func systemSettingsFrame() -> NSRect? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let mainTop = NSScreen.screens.first?.frame.maxY else { return nil }
        return windows.compactMap { info -> NSRect? in
            guard (info[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width > 300, rect.height > 250 else { return nil }
            return NSRect(x: rect.minX, y: mainTop - rect.maxY, width: rect.width, height: rect.height)
        }.max(by: { $0.width * $0.height < $1.width * $1.height })
    }
}

struct AccessibilityGuideView: View {
    static let size = NSSize(width: 300, height: 82)

    let appURL: URL
    let onClose: () -> Void
    var onDragEnded: (NSPoint, NSDragOperation) -> Void = { _, _ in }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            WindowDragSurface()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 14) {
                DraggableApplicationView(appURL: appURL, onDragEnded: onDragEnded)
                    .frame(width: 46, height: 46)
                    .accessibilityLabel("拖动 MemoEcho 应用")
                Text("拖入并启用辅助功能")
                    .font(.system(size: 14, weight: .semibold))
                    .overlay(WindowDragSurface())
            }
            .padding(.leading, 16)
            .padding(.trailing, 38)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            Button(action: onClose) {
                Image(systemName: "xmark").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭授权引导")
            .padding(12)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct WindowDragSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragSurfaceView { WindowDragSurfaceView() }
    func updateNSView(_ view: WindowDragSurfaceView, context: Context) {}
}

final class WindowDragSurfaceView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

private struct DraggableApplicationView: NSViewRepresentable {
    let appURL: URL
    let onDragEnded: (NSPoint, NSDragOperation) -> Void

    func makeNSView(context: Context) -> ApplicationDragSourceView {
        let view = ApplicationDragSourceView(appURL: appURL)
        view.onDragEnded = onDragEnded
        return view
    }

    func updateNSView(_ view: ApplicationDragSourceView, context: Context) {
        view.onDragEnded = onDragEnded
    }
}

final class ApplicationDragSourceView: NSView, NSDraggingSource {
    private let appURL: URL
    private let icon: NSImage
    private var mouseDownEvent: NSEvent?
    var onBeginDrag: ((NSDraggingItem, NSEvent) -> Void)?
    var onDragEnded: ((NSPoint, NSDragOperation) -> Void)?

    init(appURL: URL) {
        self.appURL = appURL
        icon = NSWorkspace.shared.icon(forFile: appURL.path)
        super.init(frame: .zero)
        toolTip = "拖动 MemoEcho 到辅助功能列表"
    }

    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        icon.draw(in: bounds.insetBy(dx: 5, dy: 5))
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mouseDownEvent, appURL.isFileURL, appURL.pathExtension == "app" else { return }
        self.mouseDownEvent = nil
        let item = NSDraggingItem(pasteboardWriter: appURL as NSURL)
        item.setDraggingFrame(bounds.insetBy(dx: 5, dy: 5), contents: icon)
        if let onBeginDrag {
            onBeginDrag(item, mouseDownEvent)
        } else {
            beginDraggingSession(with: [item], event: mouseDownEvent, source: self)
                .animatesToStartingPositionsOnCancelOrFail = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        completeDrag(at: screenPoint, operation: operation)
    }

    func completeDrag(at screenPoint: NSPoint, operation: NSDragOperation) {
        onDragEnded?(screenPoint, operation)
    }

}
