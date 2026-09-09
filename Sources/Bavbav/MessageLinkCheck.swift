import AppKit
import SwiftUI
import BavbavCore

@MainActor
enum MessageLinkCheck {
    static func run() async -> Bool {
        var failures: [String] = []
        var checks = 0
        func expect(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures.append(message) }
        }
        let message = CodexMessage(id: "link-check", role: .agent,
                                  text: "[Web](https://example.com) [Dosya](</tmp/test file.swift:12>)")
        let host = NSHostingView(rootView: AttachmentDropRegion(onDrop: { _ in false }) {
            ChatTranscriptView(items: [message])
        })
        let window = OverlayPanel(kind: .detail, contentRect: NSRect(x: 0, y: 0, width: 600, height: 160))
        window.contentView = host
        defer { window.close() }
        for _ in 0..<12 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        func findText(_ view: NSView) -> RichMessageTextView? {
            if let text = view as? RichMessageTextView { return text }
            return view.subviews.compactMap { findText($0) }.first
        }
        guard let text = findText(host), let layout = text.layoutManager, let container = text.textContainer else {
            print("LINK CHECK FAILED: hosted message missing"); return false
        }
        layout.ensureLayout(for: container)
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: container)
        let point = NSPoint(x: rect.midX + text.textContainerOrigin.x, y: rect.midY + text.textContainerOrigin.y)
        let hit = window.contentView?.hitTest(text.convert(point, to: window.contentView?.superview))
        expect(hit === text, "actual transcript/drop/resize hierarchy delivers clicks to message")
        expect(text.acceptsFirstMouse(for: nil), "inactive-window first click is accepted")
        expect(!text.mouseDownCanMoveWindow, "link click cannot start background window dragging")
        var opened: [URL] = []
        text.openLink = { opened.append($0) }
        let location = text.convert(point, to: nil)
        func mouse(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        NSApp.postEvent(mouse(.leftMouseUp), atStart: true)
        text.mouseDown(with: mouse(.leftMouseDown))
        expect(opened == [URL(string: "https://example.com")!], "native single click dispatches web URL exactly once")
        expect(text.link(at: point) == opened.first, "context hit resolves same target as native click")
        expect(text.link(at: NSPoint(x: text.bounds.maxX - 2, y: point.y)) == nil,
               "blank space after link is inert")
        expect(text.link(at: NSPoint(x: -1, y: -1)) == nil, "outside message is inert")
        let menu = text.menu(for: mouse(.rightMouseDown))
        menu?.update()
        expect(menu?.items.prefix(2).map(\.title) == ["Bağlantıyı aç", "Bağlantıyı kopyala"],
               "right-click exposes explicit open and copy actions")
        expect(menu?.items.prefix(2).allSatisfy(\.isEnabled) == true, "context actions pass native menu validation")
        if let item = menu?.items.first, let action = item.action {
            expect(NSApp.sendAction(action, to: item.target, from: item), "context open action routes to text view")
            expect(opened.count == 2 && opened.last == opened.first, "context action opens clicked URL")
        }
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { pasteboard.clearContents(); pasteboard.writeObjects(saved) }
        if let item = menu?.items.dropFirst().first, let action = item.action {
            _ = NSApp.sendAction(action, to: item.target, from: item)
            expect(pasteboard.string(forType: .string) == "https://example.com", "context copy preserves target")
        }
        text.selectAll(nil)
        text.copy(nil)
        expect(text.selectedRange() == NSRange(location: 0, length: text.string.utf16.count), "whole-message selection is preserved")
        expect(pasteboard.string(forType: .string) == text.rendered?.copyText(in: text.selectedRange()),
               "whole-message copy is preserved")
        text.setSelectedRange(NSRange(location: 0, length: 0))
        let file = URL(fileURLWithPath: "/tmp/test file.swift")
        for raw in ["/tmp/test%20file.swift:12", "/tmp/test file.swift:12:4", "/tmp/test file.swift#L12",
                    "file:///tmp/test%20file.swift:12", "file:///tmp/test%20file.swift#L12"] {
            expect(MessageLinkPolicy.destination(raw) == file, "local location normalizes: \(raw)")
        }
        for raw in ["javascript:alert(1)", "file://remote/tmp/test", "file:///tmp/%00test", "data:text/html,test"] {
            let before = opened.count
            _ = text.textView(text, clickedOnLink: raw, at: 0)
            expect(opened.count == before, "unsafe delegate destination blocked: \(raw)")
        }
        // File URLs arriving as either NSString or NSURL use the same policy.
        for value: Any in [file, file.absoluteString] {
            _ = text.textView(text, clickedOnLink: value, at: 0)
            expect(opened.last == file, "local links dispatch through the same controlled opener")
        }
        let fileRange = (text.string as NSString).range(of: "Dosya")
        let fileGlyph = layout.glyphRange(forCharacterRange: fileRange, actualCharacterRange: nil)
        let fileRect = layout.boundingRect(forGlyphRange: fileGlyph, in: container)
        let filePoint = NSPoint(x: fileRect.midX + text.textContainerOrigin.x, y: fileRect.midY + text.textContainerOrigin.y)
        let fileEvent = NSEvent.mouseEvent(with: .rightMouseDown, location: text.convert(filePoint, to: nil), modifierFlags: [],
                                          timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: 1)!
        let fileMenu = text.menu(for: fileEvent)
        expect(fileMenu?.items.prefix(2).map(\.title) == ["Finder’da göster", "Dosya yolunu kopyala"],
               "file context menu is reveal-only")
        if let item = fileMenu?.items.dropFirst().first, let action = item.action {
            _ = NSApp.sendAction(action, to: item.target, from: item)
            expect(pasteboard.string(forType: .string) == file.path, "file copy removes location suffix and decodes spaces")
        }
        if failures.isEmpty { print("BAVBAV LINK CHECK PASSED: \(checks) assertions; hidden native click, context menu and URL policy") }
        else { failures.forEach { print("LINK CHECK FAILED: \($0)") } }
        return failures.isEmpty
    }
}
