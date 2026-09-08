import AppKit
import BavbavCore

@MainActor
enum StandaloneChatCheck {
    private struct Failure: Error { let message: String }

    static func run() async -> Bool {
        guard ProcessInfo.processInfo.environment["BAVBAV_CODEX_BIN"]?.hasSuffix("BavbavFakeCodex") == true else {
            print("STANDALONE CHECK REQUIRES LOCAL FAKE SERVER")
            return false
        }
        let suite = "Bavbav.StandaloneCheck.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory) // Only our unique empty test directory.
        }
        let store = OverlayStore(defaults: defaults, standaloneDirectory: directory)
        let panels = PanelCoordinator(store: store, windowSizeDefaults: defaults)
        store.onOpenDetail = nil // Prepare real native views, never display them.
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            checks += 1
            if !condition() { throw Failure(message: message) }
        }
        func settle(_ predicate: () -> Bool) async {
            for _ in 0..<120 {
                if predicate() { return }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
        }
        do {
            await store.connectAndLoad()
            try check(store.chatGPTMenuIDs == [OverlayStore.chatGPTLauncherID], "work chats excluded from channel menu")
            let originalProjectIDs = store.projects.map(\.id)
            let originalRecentIDs = store.recentChats.map(\.id)
            _ = store.beginSpace(.chatgpt)
            _ = store.beginSpace(.chatgpt) // Held/rapid requests must not create two threads.
            await settle { !store.standaloneCreating && store.detailThread != nil }
            guard let first = store.detailThread else { throw Failure(message: store.standaloneError ?? "chat creation failed") }
            try check(first.id == "standalone-1" && first.projectID == nil, "new thread has no project")
            try check(first.cwd == directory.path, "neutral application folder, never current project cwd")
            try check(store.channelLabel(for: first) == "CHANNEL / ChatGPT", "native ChatGPT channel header")
            try check(store.detailHost == .centered && !store.composerVisible, "normal native reading window, Enter required to write")
            try check(!store.chatGPTExpanded && store.chatGPTSession.webView == nil, "no website or web session instantiated")
            try check(panels.openDetailWindowCount == 1 && !panels.hasVisibleWindows, "native panel allocated without activating user screen")
            store.beginWriting(from: .detail)
            try check(store.composerVisible, "Enter opens shared composer")
            store.composerText = "ECHO"
            store.submitMessage()
            await settle { !store.messageSending && store.visibleDetailItems.contains { $0.text == "BAVBAV_ECHO_OK" } }
            try check(store.visibleDetailItems.filter { $0.text == "ECHO" }.count == 1, "one prompt echo")
            try check(store.visibleDetailItems.filter { $0.text == "BAVBAV_ECHO_OK" }.count == 1, "one native reply")
            store.clearCurrentDetail(threadID: first.id)
            store.selectChatGPT(id: first.id)
            _ = store.beginSpace(.chatgpt)
            store.releaseSpace(.chatgpt)
            await settle { store.visibleDetailItems.contains { $0.text == "BAVBAV_ECHO_OK" } }
            try check(store.detailThread?.id == first.id && !store.composerVisible, "short Space reopens native history without composer")
            try check(store.visibleDetailItems.contains { $0.text == "BAVBAV_ECHO_OK" }, "reply survives close/reopen")
            for n in 2...4 {
                store.selectChatGPT(id: OverlayStore.chatGPTLauncherID)
                store.activateSelection(.chatgpt)
                await settle { !store.standaloneCreating && store.detailThread?.id == "standalone-\(n)" }
                try check(store.detailThread?.id == "standalone-\(n)", "launcher creates independent new page \(n)")
            }
            try check(panels.openDetailWindowCount == 4, "new page does not close previous chats")
            await store.refresh()
            try check(store.projects.map(\.id) == originalProjectIDs, "neutral chat folder never becomes project")
            try check(store.recentChats.map(\.id) == originalRecentIDs, "work recents remain separate")
            try check(store.standaloneChats.map(\.id) == ["standalone-4", "standalone-3", "standalone-2"], "last three chats plus launcher")
            let selected = store.standaloneChats[1].id
            store.selectChatGPT(id: selected)
            _ = store.beginSpace(.chatgpt)
            store.crossLongPressThreshold(.chatgpt)
            store.navigate(.chatgpt, delta: -1)
            store.releaseSpace(.chatgpt)
            _ = store.beginSpace(.chatgpt)
            let order = store.standaloneChats.map(\.id)
            await store.refresh()
            try check(store.standaloneChats.map(\.id) == order && order.first == selected, "long Space reorder persists")
            let restored = OverlayStore(defaults: defaults, standaloneDirectory: directory)
            try check(restored.isStandalone(first), "channel classification persists across relaunch")
            store.prepareToClose(.chatgpt)
            try check(store.detailThread != nil, "closing launcher leaves active chat intact")
            try check(store.chatGPTSession.webView == nil && !panels.hasVisibleWindows, "all checks remain native and hidden")
            print("BAVBAV STANDALONE CHECK PASSED: \(checks) checks; native creation/send/reopen, channel isolation, 3 recents/reorder, no WebKit, no foreground activation; fake server only")
            return true
        } catch {
            print("BAVBAV STANDALONE CHECK FAILED: \(error)")
            return false
        }
    }
}
