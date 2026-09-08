import AppKit

@MainActor
protocol CornerResizeCommitHandler: AnyObject {
    func cornerResizeDidFinish()
}

enum ResizeCorner: CaseIterable {
    case bottomLeft, bottomRight, topLeft, topRight

    var movesLeft: Bool { self == .bottomLeft || self == .topLeft }
    var movesBottom: Bool { self == .bottomLeft || self == .bottomRight }

    /// Keep the opposite corner fixed and stay inside the current screen.
    func frame(from original: NSRect, delta: NSPoint, minimum: NSSize, within screen: NSRect) -> NSRect {
        let anchorX = movesLeft ? original.maxX : original.minX
        let anchorY = movesBottom ? original.maxY : original.minY
        let availableWidth = max(1, min(screen.width, movesLeft ? anchorX - screen.minX : screen.maxX - anchorX))
        let availableHeight = max(1, min(screen.height, movesBottom ? anchorY - screen.minY : screen.maxY - anchorY))
        let width = min(availableWidth, max(min(minimum.width, availableWidth),
            original.width + (movesLeft ? -delta.x : delta.x)))
        let height = min(availableHeight, max(min(minimum.height, availableHeight),
            original.height + (movesBottom ? -delta.y : delta.y)))
        return NSRect(x: movesLeft ? anchorX - width : anchorX,
                      y: movesBottom ? anchorY - height : anchorY, width: width, height: height)
    }
}

/// Only the four corner subviews intercept events; edges and content retain
/// their ordinary selection, scrolling, typing and window-dragging behavior.
final class CornerResizeContainer: NSView {
    private var hostedContent: NSView?
    private let handles = ResizeCorner.allCases.map { CornerResizeHandle(corner: $0) }
    private let focusRing = WindowFocusRing()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        handles.forEach { addSubview($0) }
        addSubview(focusRing)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self)
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                center.addObserver(self, selector: #selector(refreshFocus), name: name, object: window)
            }
            for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
                center.addObserver(self, selector: #selector(refreshFocus), name: name, object: NSApp)
            }
        }
        refreshFocus()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func refreshFocus() {
        focusRing.setFocused(window?.isKeyWindow == true && NSApp.isActive)
    }

    func setContent(_ content: NSView) {
        hostedContent?.removeFromSuperview()
        hostedContent = content
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content, positioned: .below, relativeTo: handles.first)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        hostedContent?.frame = bounds
        focusRing.frame = bounds
        let hitSize: CGFloat = 12
        for handle in handles {
            handle.frame = NSRect(x: handle.corner.movesLeft ? 0 : bounds.width - hitSize,
                                  y: handle.corner.movesBottom ? 0 : bounds.height - hitSize,
                                  width: hitSize, height: hitSize)
        }
    }
}

/// Decorative overlay: never intercept clicks, resize handles, or text selection.
/// Lives outside the SwiftUI backdrop so it remains crisp at 100% transparency.
final class WindowFocusRing: NSView {
    private(set) var focused = false
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setFocused(_ focused: Bool) {
        guard self.focused != focused else { return }
        self.focused = focused
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard focused else { return }
        NSColor(calibratedRed: 0.314, green: 0.886, blue: 0.722, alpha: 1).setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.8, dy: 0.8), xRadius: 8, yRadius: 8)
        path.lineWidth = 0.8
        path.stroke()
    }
}

final class CornerResizeHandle: NSView {
    let corner: ResizeCorner
    private var dragStart: (point: NSPoint, frame: NSRect, screen: NSRect)?

    init(corner: ResizeCorner) {
        self.corner = corner
        super.init(frame: .zero)
        setAccessibilityLabel("Pencereyi boyutlandır")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
        let cursor = corner.movesLeft == corner.movesBottom ? Self.risingCursor : Self.fallingCursor
        addCursorRect(bounds, cursor: cursor)
    }

    private static let risingCursor = diagonalCursor(mirrored: false)
    private static let fallingCursor = diagonalCursor(mirrored: true)

    private static func diagonalCursor(mirrored: Bool) -> NSCursor {
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                NSPoint(x: mirrored ? 24 - x : x, y: y)
            }
            let path = NSBezierPath()
            path.move(to: point(6, 6)); path.line(to: point(18, 18))
            path.move(to: point(6, 12)); path.line(to: point(6, 6)); path.line(to: point(12, 6))
            path.move(to: point(12, 18)); path.line(to: point(18, 18)); path.line(to: point(18, 12))
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.white.setStroke()
            path.lineWidth = 3.5
            path.stroke()
            NSColor.black.setStroke()
            path.lineWidth = 1.5
            path.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        // Match the coordinator's reopening margin so a screen-edge resize
        // does not shrink by another 14 points when the panel is reopened.
        let screen = (window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame)
            .insetBy(dx: 14, dy: 14)
        dragStart = (window.convertPoint(toScreen: event.locationInWindow), window.frame,
                     screen)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let start = dragStart else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        let frame = corner.frame(from: start.frame,
                                 delta: NSPoint(x: point.x - start.point.x, y: point.y - start.point.y),
                                 minimum: window.minSize, within: start.screen)
        window.setFrame(frame, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        guard let panel = window, let start = dragStart,
              panel.frame.size != start.frame.size else { return }
        // Persist once per completed gesture, never for each mouse movement.
        (panel as? CornerResizeCommitHandler)?.cornerResizeDidFinish()
    }
}
