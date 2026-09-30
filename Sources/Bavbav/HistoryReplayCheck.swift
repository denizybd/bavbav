import AppKit
import BavbavCore
import SwiftUI

/// Explicit, read-only diagnosis of a selected real conversation. No turn,
/// resume, fork, user-default change, or foreground activation is performed.
@MainActor
enum HistoryReplayCheck {
    static func run(threadID: String) async -> Bool {
        let client = CodexAppServer()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 650, height: 640),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        do {
            _ = try await client.connect()
            let conversation = try await client.readThread(id: threadID)
            let activity = try await client.readThreadActivity(id: threadID)
            await client.shutdown()
            let items = ChatTimeline.visible(activity: activity, conversation: conversation, commandsVisible: false)
            guard let last = items.last else { throw NSError(domain: "Empty history", code: 1) }
            let scroll = ChatScrollController()
            let root = NSHostingView(rootView: ChatTranscriptView(items: items, scroll: scroll))
            panel.contentView = root
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            for _ in 0..<80 {
                root.layoutSubtreeIfNeeded()
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            let expected = RichMessageRenderer.render(last.text, fontSize: 12, width: 550, markdown: true).text.string
            let nativeScroll = descendants(root).compactMap { $0 as? NSScrollView }.first
            let lastVisible = descendants(root).compactMap { $0 as? RichMessageTextView }.contains { text in
                guard let clip = nativeScroll?.contentView else { return false }
                return text.string == expected && clip.bounds.intersects(text.convert(text.bounds, to: clip))
            }
            guard !panel.isVisible, scroll.isAtBottom, lastVisible else {
                throw NSError(domain: "History replay: latest native message is not visible", code: 2)
            }
            print("BAVBAV HISTORY REPLAY PASSED: \(conversation.count) conversation rows, \(items.count) visible rows; actual last message rendered at bottom in hidden native window; read-only")
            return true
        } catch {
            await client.shutdown()
            print("BAVBAV HISTORY REPLAY FAILED: \(error)")
            return false
        }
    }
}
