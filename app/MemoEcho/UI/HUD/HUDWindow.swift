import AppKit
import SwiftUI

/// 悬浮 HUD 窗口 — 透明面板，承载胶囊条 SwiftUI 内容
final class HUDWindow: NSPanel {
    private var selectedScreenID: NSNumber?
    var onScreenChanged: (() -> Void)?
    var onInteractionHover: ((Bool) -> Void)?
    private var interactionSize: NSSize?
    // NSEvent tokens are created/used on the main actor; deinit only removes registrations.
    nonisolated(unsafe) private var localMouseMonitor: Any?
    nonisolated(unsafe) private var globalMouseMonitor: Any?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var presentationScreen: NSScreen? {
        NSScreen.screens.first { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber == selectedScreenID }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    var availableWidth: CGFloat { presentationScreen?.visibleFrame.width ?? 1440 }

    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(origin: .zero, size: HUDLayout.windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        self.contentView = contentView
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        // 默认不拦截鼠标事件，录音态由 controller 动态切换
        ignoresMouseEvents = true
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged),
                                              name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    deinit {
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
    }

    /// Only the painted rounded rectangle accepts clicks; transparent panel padding passes through.
    func setInteractionRegion(_ size: NSSize?) {
        interactionSize = size
        if size != nil, localMouseMonitor == nil {
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
                MainActor.assumeIsolated { self?.updatePointerInteraction() }
                return event
            }
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePointerInteraction() }
            }
        } else if size == nil {
            if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
            if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
            localMouseMonitor = nil
            globalMouseMonitor = nil
        }
        updatePointerInteraction()
    }

    private func updatePointerInteraction() {
        let inside: Bool
        if let size = interactionSize {
            let point = NSPoint(x: NSEvent.mouseLocation.x - frame.minX, y: NSEvent.mouseLocation.y - frame.minY)
            inside = Self.isInsideCapsule(point, panelSize: frame.size, capsuleSize: size)
        } else { inside = false }
        ignoresMouseEvents = !inside
        onInteractionHover?(inside)
    }

    static func isInsideCapsule(_ point: NSPoint, panelSize: NSSize, capsuleSize: NSSize) -> Bool {
        let rect = NSRect(x: (panelSize.width - capsuleSize.width) / 2, y: HUDLayout.panelPadding.height,
                          width: capsuleSize.width, height: capsuleSize.height)
        let radius = min(17, capsuleSize.height / 2)
        return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).contains(point)
    }

    @objc private func screenParametersChanged() {
        selectedScreenID = presentationScreen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        onScreenChanged?()
    }

    /// Select once for a presentation/session; resizes never follow the mouse.
    func positionOnActiveScreen() {
        let screen = Self.screenContainingMouse() ?? NSScreen.main ?? NSScreen.screens.first
        selectedScreenID = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        resize(to: frame.size)
    }

    func resize(to size: NSSize) {
        guard let screen = presentationScreen else { return }
        let safeSize = NSSize(width: min(size.width, screen.visibleFrame.width),
                              height: min(size.height, screen.visibleFrame.height))
        setFrame(NSRect(origin: Self.frameOrigin(windowSize: safeSize, screenFrame: screen.frame,
                                                visibleFrame: screen.visibleFrame), size: safeSize), display: true)
        updatePointerInteraction()
    }

    static func frameOrigin(
        windowSize: NSSize,
        screenFrame: NSRect,
        visibleFrame: NSRect
    ) -> NSPoint {
        let x = visibleFrame.midX - windowSize.width / 2
        let desiredY = screenFrame.minY + HUDLayout.baseBottomMargin + bottomReservedHeight(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        )

        return NSPoint(x: max(visibleFrame.minX, x),
                       y: max(visibleFrame.minY, min(desiredY, visibleFrame.maxY - windowSize.height)))
    }

    static func bottomReservedHeight(screenFrame: NSRect, visibleFrame: NSRect) -> CGFloat {
        max(0, visibleFrame.minY - screenFrame.minY)
    }

    /// 查找光标所在屏幕
    private static func screenContainingMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { screen in
            screen.frame.contains(mouseLocation)
        }
    }
}
