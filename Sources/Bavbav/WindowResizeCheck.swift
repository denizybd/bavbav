import AppKit
import BavbavCore

@MainActor
enum WindowResizeCheck {
    private struct Failure: Error { let message: String }

    /// Hidden AppKit windows and an isolated preferences suite: no foreground
    /// activation, global mouse injection, network calls or real chat writes.
    static func run() -> Bool {
        let suiteName = "dev.deniz.bavbav.resize-check.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw Failure(message: message) }
        }
        do {
            let screen = NSRect(x: -1440, y: -100, width: 1440, height: 900)
            let original = NSRect(x: -1140, y: 150, width: 500, height: 350)
            let minimum = NSSize(width: 280, height: 220)
            for corner in ResizeCorner.allCases {
                let grown = corner.frame(from: original,
                    delta: NSPoint(x: corner.movesLeft ? -80 : 80, y: corner.movesBottom ? -60 : 60),
                    minimum: minimum, within: screen)
                try check(grown.size == NSSize(width: 580, height: 410), "growth: \(corner)")
                try check((corner.movesLeft ? grown.maxX == original.maxX : grown.minX == original.minX)
                       && (corner.movesBottom ? grown.maxY == original.maxY : grown.minY == original.minY),
                          "opposite corner moved: \(corner)")
                let shrunk = corner.frame(from: original,
                    delta: NSPoint(x: corner.movesLeft ? 2000 : -2000, y: corner.movesBottom ? 2000 : -2000),
                    minimum: minimum, within: screen)
                try check(shrunk.size == minimum, "minimum: \(corner)")
                let clamped = corner.frame(from: original,
                    delta: NSPoint(x: corner.movesLeft ? -2000 : 2000, y: corner.movesBottom ? -2000 : 2000),
                    minimum: minimum, within: screen)
                try check(screen.contains(clamped), "screen bounds: \(corner)")
            }
            let tiny = NSRect(x: 0, y: 0, width: 200, height: 150)
            try check(ResizeCorner.topRight.frame(from: tiny, delta: .zero, minimum: minimum, within: tiny) == tiny,
                      "small screen must take priority over minimum")

            let panel = OverlayPanel(kind: .detail, contentRect: NSRect(x: 100, y: 100, width: 500, height: 350))
            defer { panel.close() }
            panel.minSize = NSSize(width: 400, height: 320)
            let content = NSTextView(frame: .zero)
            content.string = "Resize without changing message selection"
            panel.contentView = content
            guard let container = panel.contentView as? CornerResizeContainer else { throw Failure(message: "container missing") }
            container.layoutSubtreeIfNeeded()
            guard let ring = container.subviews.compactMap({ $0 as? WindowFocusRing }).first else {
                throw Failure(message: "focus ring missing")
            }
            try check(!ring.focused, "hidden window must not appear focused")
            try check(ring.frame == container.bounds && ring.hitTest(.zero) == nil,
                      "focus ring fills frame without intercepting input")
            ring.setFocused(true)
            try check(ring.focused, "focus ring enables")
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: panel)
            try check(!ring.focused, "window focus loss clears ring")
            ring.setFocused(true)
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
            try check(!ring.focused, "switching apps clears focus ring")
            for focused in [true, false] {
                ring.setFocused(focused)
                guard let bitmap = ring.bitmapImageRepForCachingDisplay(in: ring.bounds) else {
                    throw Failure(message: "focus ring bitmap missing")
                }
                ring.cacheDisplay(in: ring.bounds, to: bitmap)
                var greenPixels = 0
                for x in 0..<bitmap.pixelsWide {
                    for y in 0..<min(5, bitmap.pixelsHigh) {
                        if let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                           c.alphaComponent > 0.1, c.greenComponent > c.redComponent * 1.5 { greenPixels += 1 }
                    }
                }
                try check(focused ? greenPixels > 20 : greenPixels == 0, "green outline rendered only when focused")
            }
            try check(!panel.styleMask.contains(.resizable), "native edge resizing must stay disabled")
            let handles = container.subviews.compactMap { $0 as? CornerResizeHandle }
            try check(handles.count == 4, "four corner handles required")
            for handle in handles {
                try check(container.hitTest(NSPoint(x: handle.frame.midX, y: handle.frame.midY)) === handle,
                          "corner hit testing: \(handle.corner)")
                try check(!handle.mouseDownCanMoveWindow && handle.acceptsFirstMouse(for: nil), "inactive-window corner dragging")
            }
            for point in [NSPoint(x: 250, y: 1), NSPoint(x: 250, y: 349),
                          NSPoint(x: 1, y: 175), NSPoint(x: 499, y: 175), NSPoint(x: 250, y: 175)] {
                try check(!(container.hitTest(point) is CornerResizeHandle), "edge/content swallowed by resize handle")
            }

            let visible = NSScreen.main!.visibleFrame
            panel.setFrame(NSRect(x: visible.minX + 60, y: visible.minY + 60, width: 500, height: 350), display: false)
            let initial = panel.frame
            let startPoint = NSPoint(x: initial.maxX - 5, y: initial.minY + 5)
            func mouse(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: panel.convertPoint(fromScreen: point), modifierFlags: [],
                                   timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                                   eventNumber: 1, clickCount: 1, pressure: 1)!
            }
            var commits = 0
            panel.onUserResize = { _ in commits += 1 }
            let handle = handles.first { $0.corner == .bottomRight }!
            handle.mouseDown(with: mouse(.leftMouseDown, at: startPoint))
            // Focusing another chat may replace its content during the drag.
            let replacement = NSTextView(frame: .zero)
            panel.contentView = replacement
            try check(panel.contentView === container && handle.superview === container, "content swap broke in-flight drag")
            let endPoint = NSPoint(x: startPoint.x + 40, y: startPoint.y - 30)
            handle.mouseDragged(with: mouse(.leftMouseDragged, at: endPoint))
            container.layoutSubtreeIfNeeded()
            try check(panel.frame == NSRect(x: initial.minX, y: initial.minY - 30, width: 540, height: 380), "native mouse drag frame")
            try check(replacement.frame == container.bounds, "content did not follow resized window")
            try check(commits == 0, "persisted during drag")
            handle.mouseUp(with: mouse(.leftMouseUp, at: endPoint))
            try check(commits == 1, "resize must commit once")
            handle.mouseDown(with: mouse(.leftMouseDown, at: endPoint))
            handle.mouseUp(with: mouse(.leftMouseUp, at: endPoint))
            try check(commits == 1, "click without drag must not persist")
            panel.contentView = nil
            try check(panel.contentView == nil && handle.window == nil, "closing did not release content wrapper")

            let existingIDs = Set(NSApp.windows.map(ObjectIdentifier.init))
            let store = OverlayStore()
            let coordinator = PanelCoordinator(store: store, windowSizeDefaults: defaults)
            let controlPanels = NSApp.windows.compactMap { $0 as? OverlayPanel }
                .filter { !existingIDs.contains(ObjectIdentifier($0)) }
            try check(controlPanels.count == 5, "coordinator windows missing")
            defer { controlPanels.forEach { $0.close() } }
            for target in controlPanels where target.overlayKind != .detail {
                target.setContentSize(NSSize(width: 500, height: 400))
                target.onUserResize?(target)
                target.setContentSize(NSSize(width: 510, height: 410))
            }
            coordinator.positionPanels()
            for target in controlPanels where target.overlayKind != .detail {
                try check(target.frame.size == NSSize(width: 500, height: 400), "saved size: \(target.overlayKind)")
                target.contentView?.layoutSubtreeIfNeeded()
                try check(target.contentView?.frame.size == target.frame.size, "hosted content size: \(target.overlayKind)")
            }
            let chat = controlPanels.first { $0.overlayKind == .chatgpt }!
            defaults.set([700.0, 450.0], forKey: "window-size.chat.expanded")
            store.onChatGPTLayoutChanged?(true)
            try check(chat.frame.size == NSSize(width: 700, height: 450) && chat.minSize.width == 480, "expanded CHAT size")
            store.onChatGPTLayoutChanged?(false)
            try check(chat.frame.size == NSSize(width: 500, height: 400) && chat.minSize.width == 280, "compact CHAT size kept separately")
            for (id, width) in [("resize-thread-a", 550.0), ("resize-thread-b", 600.0)] {
                defaults.set([width, 420.0], forKey: "window-size.detail.\(id)")
                let thread = CodexThread(id: id, projectID: nil, cwd: "/tmp", title: "Resize fixture",
                                         preview: "", updatedAt: Date(), state: .idle, hasMessages: false)
                store.onWillOpenDetail?(thread, .centered)
                let detail = NSApp.windows.compactMap { $0 as? OverlayPanel }.first { $0.representedThread?.id == id }
                try check(detail?.frame.size == NSSize(width: width, height: 420), "per-chat saved size: \(id)")
                try check(detail?.onUserResize != nil, "extra chat lacks resize persistence")
            }
            defaults.set([-20.0, 0.0], forKey: "window-size.projects")
            coordinator.positionPanels()
            try check(controlPanels.first { $0.overlayKind == .projects }?.frame.size == NSSize(width: 382, height: 438),
                      "invalid preference fallback")
            try check(coordinator.allWindowsUseNormalLevel, "window stacking changed")
            print("BAVBAV RESIZE CHECK PASSED: focus ring rendering/focus loss/input passthrough; four corners, fixed opposite anchor, minimum/screen bounds, hit tests, native drag, content swap, single commit, saved panel/chat sizes, CHAT modes")
            return true
        } catch {
            fputs("BAVBAV RESIZE CHECK FAILED: \((error as? Failure)?.message ?? error.localizedDescription)\n", stderr)
            return false
        }
    }
}
