import AppKit
import BavbavCore

@MainActor
enum CommandVisibilityCheck {
    private struct Failure: Error { let message: String }

    static func run() async -> Bool {
        guard ProcessInfo.processInfo.environment["BAVBAV_CODEX_BIN"]?.hasSuffix("BavbavFakeCodex") == true else {
            print("COMMANDS CHECK REQUIRES LOCAL FAKE SERVER")
            return false
        }
        let suite = "Bavbav.CommandVisibilityCheck.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
            checks += 1
            if !value() { throw Failure(message: message) }
        }
        func settle(_ condition: () -> Bool) async {
            for _ in 0..<100 {
                if condition() { return }
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
        }
        let store = OverlayStore(defaults: defaults)
        let coordinator = PanelCoordinator(store: store)
        // No foreground windows, account calls, or real messages in this check.
        store.onWillOpenDetail = nil
        store.onOpenDetail = nil
        let router = InputRouter(store: store, coordinator: coordinator)
        let panel = OverlayPanel(kind: .detail, contentRect: NSRect(x: 0, y: 0, width: 640, height: 420))
        panel.isReleasedWhenClosed = false
        let other = OverlayPanel(kind: .projects, contentRect: .zero)
        other.isReleasedWhenClosed = false
        defer {
            store.clearCurrentDetail(threadID: store.detailThread?.id ?? "")
            panel.orderOut(nil)
            other.orderOut(nil)
        }
        func key(_ modifiers: NSEvent.ModifierFlags, repeated: Bool = false,
                 type: NSEvent.EventType = .keyDown, window: NSWindow? = nil) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
                             windowNumber: (window ?? panel).windowNumber, context: nil,
                             characters: "\t", charactersIgnoringModifiers: "\t",
                             isARepeat: repeated, keyCode: 48)!
        }
        do {
            await store.connectAndLoad()
            let thread = CodexThread(id: "fixture-thread", projectID: nil, cwd: "/tmp/fixture",
                                     title: "Fixture", preview: "", updatedAt: Date(), state: .idle, hasMessages: true)
            panel.representedThread = thread
            defaults.set(true, forKey: "trace.\(thread.id)") // Legacy TRACE cannot override the new default.
            store.focusDetailWindow(thread)
            await settle { store.visibleDetailItems.count == 4 }
            try check(!store.detailShowsActivity, "commands default off")
            try check(store.visibleDetailItems.map(\.kind) == [.user, .reasoning, .collaboration, .agent],
                      "history preserves messages, reasoning, subagents and order: \(store.visibleDetailItems.map { $0.kind.rawValue }); \(store.composerError ?? "no error") / \(store.interactionError ?? "no activity error")")
            try check(!store.detailActivityItems.contains { $0.kind == .command }, "hidden command output released")
            store.composerText = "Unsent draft W A S D"
            store.beginWriting(from: .detail)
            try check(store.composerVisible, "writing fixture opened")
            try check(router.handle(key(.shift)) == nil && store.detailShowsActivity, "Shift Tab enables commands while writing")
            await settle { store.visibleDetailItems.count == 5 }
            try check(store.visibleDetailItems.map(\.kind) == [.user, .reasoning, .command, .collaboration, .agent],
                      "commands inserted in original timeline, not separate view")
            try check(store.composerVisible && store.composerText == "Unsent draft W A S D", "toggle preserves composer/draft")
            try check(router.handle(key(.shift, repeated: true)) == nil && store.detailShowsActivity, "held shortcut toggles only once")
            try check(router.handle(key(.shift, type: .keyUp)) == nil && store.detailShowsActivity, "key release does not toggle")
            for modifiers: NSEvent.ModifierFlags in [[], .command, [.command, .shift], [.control, .shift], [.option, .shift]] {
                let event = key(modifiers)
                try check(router.handle(event) === event && store.detailShowsActivity, "Tab variants remain native")
            }
            let unrelated = key(.shift, window: other)
            try check(router.handle(unrelated) === unrelated && store.detailShowsActivity, "other windows do not toggle chat")
            try check(router.handle(key(.shift)) == nil && !store.detailShowsActivity, "second Shift Tab hides commands")
            try check(store.visibleDetailItems.count == 4, "nontechnical history remains")
            try check(!store.detailActivityItems.contains { $0.kind == .command }, "toggle off releases technical rows")
            store.clearCurrentDetail(threadID: thread.id)
            store.focusDetailWindow(thread)
            await settle { store.visibleDetailItems.count == 4 }
            try check(!store.detailShowsActivity, "closed/reopened thread remembers off")
            _ = router.handle(key(.shift))
            let second = CodexThread(id: "fixture-second", projectID: nil, cwd: "/tmp/fixture",
                                     title: "Second", preview: "", updatedAt: Date(), state: .idle, hasMessages: true)
            store.focusDetailWindow(second)
            try check(!store.detailShowsActivity, "another chat defaults off independently")
            // An event in the first chat must target it even before async focus catches up.
            _ = router.handle(key(.shift))
            try check(store.detailThread?.id == thread.id && !store.detailShowsActivity, "shortcut targets actual event window")
            _ = router.handle(key(.shift))
            store.clearCurrentDetail(threadID: thread.id)
            store.focusDetailWindow(thread)
            try check(store.detailShowsActivity, "closed/reopened thread remembers on")
            store.toggleDetailActivity()
            store.beginWriting(from: .detail)
            store.composerText = "VISIBILITY_LIVE"
            store.submitMessage()
            await settle { store.visibleDetailItems.contains { $0.id == "live-answer" } }
            try check(store.visibleDetailItems.contains { $0.id == "live-reason" && $0.text == "Live thought" },
                      "reasoning streams with commands off")
            try check(store.visibleDetailItems.contains { $0.id == "live-subagent" }, "subagent streams with commands off")
            try check(store.visibleDetailItems.filter { $0.text == "VISIBILITY_LIVE" }.count == 1,
                      "live user echo never duplicates optimistic prompt")
            try check(store.detailRunState == .working && store.detailOperation == "COMMAND",
                      "current operation remains visible independently of technical rows")
            try check(!store.detailActivityItems.contains { $0.kind == .command }, "hidden streamed output not retained")
            let user = CodexMessage(id: "user", role: .user, text: "Same text")
            let repeatUser = CodexMessage(id: "user2", role: .user, text: "Same text")
            let old = CodexMessage(id: "reply", role: .agent, text: "Partial")
            let latest = CodexMessage(id: "reply", role: .agent, text: "Complete")
            let merged = ChatTimeline.visible(activity: [user, old, old], conversation: [user, latest, repeatUser], commandsVisible: false)
            try check(merged.map(\.id) == ["user", "reply", "user2"] && merged[1].text == "Complete",
                      "stable IDs deduplicate; latest deltas win; intentional identical sends remain")
            try check(!panel.isVisible && !other.isVisible, "checks never show windows")
            print("BAVBAV COMMANDS CHECK PASSED: \(checks) checks; history filtering, Shift Tab, typing, persistence, window isolation, live reasoning/subagents/status, deduplication; fake server only")
            return true
        } catch {
            print("BAVBAV COMMANDS CHECK FAILED: \(error)")
            return false
        }
    }
}
