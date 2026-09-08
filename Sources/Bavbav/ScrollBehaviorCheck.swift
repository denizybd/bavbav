import AppKit
import BavbavCore
import SwiftUI

@MainActor
enum ScrollBehaviorCheck {
    private struct Failure: Error { let message: String }
    private final class Document: NSView { override var isFlipped: Bool { true } }
    private final class TranscriptFixture: ObservableObject {
        @Published var items: [CodexMessage] = []
    }
    private struct FixtureView: View {
        @ObservedObject var fixture: TranscriptFixture
        let scroll: ChatScrollController
        var body: some View { ChatTranscriptView(items: fixture.items, scroll: scroll) }
    }

    /// Hidden native and SwiftUI windows only. No account, send, focus change,
    /// global key/mouse injection or changes to the user's preferences.
    static func run() async -> Bool {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            checks += 1
            if !condition() { throw Failure(message: message) }
        }
        func settle(_ root: NSView? = nil) async {
            // Pump actual SwiftUI/AppKit layout through multiple display turns.
            for _ in 0..<12 {
                root?.layoutSubtreeIfNeeded()
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        let suite = "dev.deniz.bavbav.scroll-check.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let initialWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        defer { NSApp.windows.filter { !initialWindows.contains(ObjectIdentifier($0)) }.forEach { $0.close() } }
        do {
            func nativeFixture() -> (OverlayPanel, NSScrollView, Document, ChatScrollController) {
                let panel = OverlayPanel(kind: .detail, contentRect: NSRect(x: 0, y: 0, width: 500, height: 300))
                let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
                scroll.autoresizingMask = [.width, .height]
                let document = Document(frame: NSRect(x: 0, y: 0, width: 500, height: 3_000))
                scroll.documentView = document
                panel.contentView = scroll
                panel.contentView?.layoutSubtreeIfNeeded()
                let controller = ChatScrollController()
                controller.attach(scroll)
                return (panel, scroll, document, controller)
            }
            let (panel, native, document, controller) = nativeFixture()
            await settle()
            try check(controller.isAtBottom && controller.followingBottom, "initial long history starts at bottom")
            try check(!controller.awayFromBottom && native.contentView.bounds.minY > 2_000, "initial arrow hidden, actual offset moved")

            // AppKit's live-scroll lifetime includes pauses with fingers still
            // down; a timer cannot infer that this gesture has ended.
            NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: native)
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: native)
            await settle()
            try check(!controller.followingBottom, "a paused live gesture must not re-enable automatic scrolling")
            let beforePause = native.contentView.bounds.minY
            native.contentView.scroll(to: NSPoint(x: 0, y: beforePause - 8))
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: native)
            await settle()
            try check(abs(native.contentView.bounds.minY - (beforePause - 8)) < 1,
                      "resuming a paused native gesture must not snap back")
            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: native)
            controller.jumpToBottom()
            await settle()

            for height in [5_000.0, 5_700.0, 9_000.0] {
                document.setFrameSize(NSSize(width: 500, height: height))
                await settle()
                try check(controller.isAtBottom, "late history/streaming layout follows bottom: \(height)")
            }
            native.setFrameSize(NSSize(width: 460, height: 220))
            await settle()
            try check(controller.isAtBottom, "viewport/composer resize keeps latest text visible")

            // Trackpad deltas commonly start smaller than the old 24pt bottom
            // threshold. Streaming/layout must never fight this gesture.
            let gestureBottom = controller.bottomOffset
            controller.userWillScroll()
            for retreat in [0.0, 2.0, 5.0, 12.0, 23.0] {
                native.contentView.scroll(to: NSPoint(x: 0, y: gestureBottom - retreat))
                controller.userDidScroll()
                controller.contentChanged()
                try? await Task.sleep(nanoseconds: 25_000_000)
                try check(!controller.followingBottom, "gesture retains ownership even near bottom: \(retreat)")
                try check(abs(native.contentView.bounds.minY - (gestureBottom - retreat)) < 0.5,
                          "small/momentum scroll is not snapped back: \(retreat)")
            }
            await settle()
            try check(!controller.followingBottom && controller.awayFromBottom, "small retreat stays unpinned after gesture ends")
            controller.userWillScroll()
            native.contentView.scroll(to: NSPoint(x: 0, y: controller.bottomOffset))
            controller.userDidScroll()
            await settle()
            try check(controller.followingBottom && !controller.awayFromBottom, "intentional return to bottom resumes following after gesture")
            var redundantPublications = 0
            let observation = controller.$awayFromBottom.dropFirst().sink { _ in redundantPublications += 1 }
            for _ in 0..<100 { controller.correctAfterLayout() }
            try check(redundantPublications == 0, "unchanged scroll geometry does not invalidate SwiftUI")
            observation.cancel()

            NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: native)
            native.contentView.scroll(to: NSPoint(x: 0, y: 1_200))
            native.reflectScrolledClipView(native.contentView)
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: native)
            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: native)
            let readingOffset = native.contentView.bounds.minY
            try check(!controller.followingBottom && controller.awayFromBottom, "scroll up reveals jump button")
            document.setFrameSize(NSSize(width: 460, height: 12_000))
            controller.contentChanged()
            await settle()
            try check(native.contentView.bounds.minY == readingOffset, "new text must not interrupt reading older messages")
            controller.jumpToBottom()
            await settle()
            try check(controller.isAtBottom && !controller.awayFromBottom, "one jump resumes follow and hides button")

            let (otherPanel, otherScroll, _, otherController) = nativeFixture()
            await settle()
            func scrollUp(_ target: ChatScrollController, _ view: NSScrollView) {
                target.userWillScroll()
                view.contentView.scroll(to: .zero)
                view.reflectScrolledClipView(view.contentView)
                target.userDidScroll()
            }
            scrollUp(controller, native)
            scrollUp(otherController, otherScroll)
            NotificationCenter.default.post(name: .chatJumpToBottom, object: panel)
            await settle()
            try check(controller.isAtBottom && otherController.awayFromBottom, "jump targets only the chosen chat window")

            let store = OverlayStore(defaults: defaults)
            let panels = PanelCoordinator(store: store, windowSizeDefaults: defaults)
            let router = InputRouter(store: store, coordinator: panels)
            func key(_ code: UInt16, flags: NSEvent.ModifierFlags = [], target: NSWindow? = nil, repeatKey: Bool = false) -> NSEvent {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                windowNumber: (target ?? panel).windowNumber, context: nil,
                                characters: code == 11 ? "b" : "", charactersIgnoringModifiers: code == 11 ? "b" : "",
                                isARepeat: repeatKey, keyCode: code)!
            }
            for code: UInt16 in [11, 119] {
                scrollUp(controller, native)
                try check(router.handle(key(code)) == nil, "B/End read shortcut consumed: \(code)")
                await settle()
                try check(controller.isAtBottom, "B/End jumps to bottom: \(code)")
            }
            scrollUp(controller, native)
            try check(router.handle(key(119, flags: .function)) == nil, "Fn-right (End) accepted")
            await settle()
            try check(controller.isAtBottom, "Fn-right reached bottom")
            scrollUp(controller, native)
            _ = router.handle(key(11, repeatKey: true))
            await settle()
            try check(controller.awayFromBottom, "held B does not repeat navigation")
            for flags: NSEvent.ModifierFlags in [.command, .control, .option, .shift] {
                _ = router.handle(key(11, flags: flags))
                await settle()
                try check(controller.awayFromBottom, "modified B must not jump: \(flags.rawValue)")
            }
            let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 50))
            document.addSubview(editor)
            panel.makeFirstResponder(editor)
            for code: UInt16 in [11, 119] {
                try check(router.handle(key(code)) != nil, "editing preserves B/End: \(code)")
            }
            await settle()
            try check(controller.awayFromBottom, "typing must not jump")
            editor.isEditable = false
            try check(router.handle(key(11)) == nil, "selected read-only message supports B")
            await settle()
            try check(controller.isAtBottom, "read-only selection permits jump")

            let projectPanel = OverlayPanel(kind: .projects, contentRect: NSRect(x: 0, y: 0, width: 300, height: 200))
            try check(router.handle(key(11, target: projectPanel)) != nil, "B is not intercepted in non-chat windows")

            controller.detach()
            native.contentView.scroll(to: .zero)
            NotificationCenter.default.post(name: .chatJumpToBottom, object: panel)
            await settle()
            try check(native.contentView.bounds.minY == 0, "detached transcript stops observing window")
            let reopened = ChatScrollController()
            reopened.attach(native)
            await settle()
            try check(reopened.isAtBottom && reopened.followingBottom, "reopen starts at bottom even after reading at top")

            // Exercise the real LazyVStack, rich text sizing and AppKit probe,
            // not just a synthetic NSScrollView/document-height fixture.
            let fixture = TranscriptFixture()
            let realController = ChatScrollController()
            let hosted = NSHostingView(rootView: FixtureView(fixture: fixture, scroll: realController))
            let realPanel = OverlayPanel(kind: .detail, contentRect: NSRect(x: 0, y: 0, width: 640, height: 500))
            realPanel.contentView = hosted
            await settle(realPanel.contentView)
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            guard let realScroll = descendants(hosted).compactMap({ $0 as? NSScrollView }).first else {
                throw Failure(message: "SwiftUI transcript did not create its native scroll view")
            }
            func message(_ index: Int) -> CodexMessage {
                let content = index % 3 == 0 ? "## Başlık\n- Bir\n- İki\n\n```swift\nlet value = \(index)\n```" : String(repeating: "Sohbet satırı \(index). ", count: 5 + index % 13)
                return CodexMessage(id: "scroll-\(index)", role: index % 2 == 0 ? .user : .agent, text: content)
            }
            fixture.items = (0..<120).map(message)
            await settle(realPanel.contentView)
            try check(realScroll.contentView.bounds.minY > 1_000, "real late-loaded history scrolled away from first message")
            try check(realController.isAtBottom, "real lazy rich transcript opens at latest message")
            func lastTextIsVisible(_ needle: String) -> Bool {
                descendants(hosted).compactMap { $0 as? NSTextView }.contains {
                    $0.string.contains(needle) && realScroll.contentView.bounds.intersects($0.convert($0.bounds, to: realScroll.contentView))
                }
            }
            try check(lastTextIsVisible("Sohbet satırı 119"), "last message is actually laid out in the viewport")
            let previousBottom = realScroll.contentView.bounds.minY
            fixture.items[119] = CodexMessage(id: "scroll-119", role: .agent, text: String(repeating: "Streaming response\n", count: 80))
            await settle(realPanel.contentView)
            try check(realController.isAtBottom && realScroll.contentView.bounds.minY > previousBottom,
                      "same-ID streamed text follows final line after rich layout")
            try check(lastTextIsVisible("Streaming response"), "streaming final message is visible, not just an estimated lazy offset")
            realPanel.setContentSize(NSSize(width: 450, height: 320))
            await settle(realPanel.contentView)
            try check(realController.isAtBottom, "real narrower/shorter window remains pinned")
            scrollUp(realController, realScroll)
            let realReadingOffset = realScroll.contentView.bounds.minY
            fixture.items.append(message(120))
            await settle(realPanel.contentView)
            try check(realController.awayFromBottom && abs(realScroll.contentView.bounds.minY - realReadingOffset) < 1,
                      "real incoming message preserves reading position")
            NotificationCenter.default.post(name: .chatJumpToBottom, object: realPanel)
            await settle(realPanel.contentView)
            try check(realController.isAtBottom && !realController.awayFromBottom, "real window jump reaches last message")
            fixture.items.append(CodexMessage(id: "math-last", role: .agent, text: #"Son denklem: \[\int_0^1 x^2\,dx=\frac{1}{3}\]"#))
            await settle(realPanel.contentView)
            try check(realController.isAtBottom && lastTextIsVisible("Son denklem"), "last math attachment appears after its final layout")

            // Incremental travel must preserve the actual on-screen text, not
            // merely the raw clip offset (lazy layout can change document height).
            fixture.items = (0..<160).map { index in
                CodexMessage(id: "travel-\(index)", role: .agent,
                    text: "Travel message \(index)\n" + String(repeating: "Variable height history \(index).\n", count: 1 + (index * 37) % 70))
            }
            await settle(realPanel.contentView)
            realController.jumpToBottom()
            await settle(realPanel.contentView)
            for step in 0..<70 {
                let visible = descendants(hosted).compactMap { $0 as? RichMessageTextView }.filter {
                    let area = realScroll.contentView.bounds.intersection($0.convert($0.bounds, to: realScroll.contentView))
                    return !area.isNull && area.height > 100
                }
                guard let anchor = visible.first else { throw Failure(message: "no readable anchor at travel step \(step)") }
                let text = anchor.string
                realController.userWillScroll()
                let target = max(0, realScroll.contentView.bounds.minY - 60)
                realScroll.contentView.scroll(to: NSPoint(x: 0, y: target))
                realScroll.reflectScrolledClipView(realScroll.contentView)
                realController.userDidScroll()
                let expectedY = anchor.convert(anchor.bounds, to: nil).minY
                for _ in 0..<4 {
                    realPanel.contentView?.layoutSubtreeIfNeeded()
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                guard let after = descendants(hosted).compactMap({ $0 as? RichMessageTextView }).first(where: { $0.string == text }) else {
                    throw Failure(message: "visible anchor disappeared while scrolling: \(step)")
                }
                let drift = after.convert(after.bounds, to: nil).minY - expectedY
                try check(abs(drift) < 2, "incremental scroll keeps visible text stable, step \(step), drift \(drift)pt")
            }
            fixture.items = [message(1)]
            await settle(realPanel.contentView)
            try check(realController.isAtBottom && !realController.awayFromBottom, "short history has no unnecessary jump button")
            weak var released: ChatScrollController?
            do {
                let temporary = ChatScrollController()
                temporary.attach(NSScrollView()) // No document yet: no broad observers.
                temporary.attach(realScroll)
                released = temporary
            }
            await settle()
            try check(released == nil, "closing a transcript releases controller and local event monitor")
            try check([panel, otherPanel, realPanel].allSatisfy { !$0.isVisible }, "checks never displayed chat windows")
            print("BAVBAV SCROLL CHECK PASSED: \(checks) checks; initial/late history, streaming, resize, read position, B/End, window isolation, actual SwiftUI layout")
            return true
        } catch {
            fputs("BAVBAV SCROLL CHECK FAILED after \(checks) checks: \(error)\n", stderr)
            return false
        }
    }
}
