import AppKit

/// A visual second cursor, not a second independent macOS input seat. This
/// window never becomes key/main, activates an app, or intercepts mouse input.
@MainActor public final class CompanionDesktopCursorOverlay: CompanionDesktopCursorDisplaying {
    private var panel: CursorPanel?
    public init() {}
    public func show(at point: CGPoint) {
        let window: CursorPanel
        if let panel { window = panel }
        else {
            window = CursorPanel(contentRect: NSRect(x: 0, y: 0, width: 36, height: 44),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
            window.ignoresMouseEvents = true; window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false; window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            window.contentView = CursorView(frame: NSRect(x: 0, y: 0, width: 36, height: 44))
            window.setAccessibilityElement(false)
            panel = window
        }
        // AppKit global origin is bottom-left of primary screen, Quartz is top-left.
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        window.setFrameOrigin(NSPoint(x: point.x - 5, y: primaryHeight - point.y - 39))
        window.orderFrontRegardless()
    }
    public func hide() { panel?.orderOut(nil) }
}

private final class CursorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
private final class CursorView: NSView {
    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 5, y: 5)); path.line(to: NSPoint(x: 5, y: 31))
        path.line(to: NSPoint(x: 12, y: 25)); path.line(to: NSPoint(x: 17, y: 37))
        path.line(to: NSPoint(x: 23, y: 34)); path.line(to: NSPoint(x: 18, y: 23))
        path.line(to: NSPoint(x: 28, y: 22)); path.close()
        NSColor(calibratedRed: 0.314, green: 0.886, blue: 0.722, alpha: 1).setFill(); path.fill()
        NSColor(calibratedWhite: 0.03, alpha: 1).setStroke(); path.lineWidth = 1.6; path.stroke()
    }
}
