import AppKit
import BavbavCore

@MainActor
enum InteractionPerformanceCheck {
    private struct Failure: Error { let message: String }

    /// Real AppKit/SwiftUI view trees, hidden throughout. The account, live app,
    /// user defaults, clipboard and foreground/key-window ownership are untouched.
    static func run() async -> Bool {
        guard ProcessInfo.processInfo.environment["BAVBAV_CODEX_BIN"]?.hasSuffix("BavbavFakeCodex") == true else {
            print("PERFORMANCE CHECK REQUIRES LOCAL FAKE SERVER")
            return false
        }
        let suite = "Bavbav.PerformanceCheck.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let initialWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        defer { NSApp.windows.filter { !initialWindows.contains(ObjectIdentifier($0)) }.forEach { $0.close() } }
        let store = OverlayStore(defaults: defaults)
        let coordinator = PanelCoordinator(store: store, windowSizeDefaults: defaults)
        store.onOpenDetail = { [weak coordinator] in coordinator?.completeDetailOpen(present: false) }
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            checks += 1
            if try !condition() { throw Failure(message: message) }
        }
        func settle(_ root: NSView? = nil) async {
            for _ in 0..<15 {
                root?.layoutSubtreeIfNeeded()
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        func loadHistory() async throws {
            for _ in 0..<150 {
                if store.visibleDetailItems.count == 120 && !store.detailLoading && !store.detailActivityLoading { return }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            throw Failure(message: "fixture history did not load: \(store.visibleDetailItems.count); \(store.composerError ?? "")")
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func window(_ thread: CodexThread) throws -> OverlayPanel {
            guard let panel = NSApp.windows.compactMap({ $0 as? OverlayPanel }).first(where: { $0.representedThread?.id == thread.id }) else {
                throw Failure(message: "missing panel for \(thread.id)")
            }
            return panel
        }
        func scrollView(_ panel: OverlayPanel) throws -> NSScrollView {
            guard let root = panel.contentView, let scroll = descendants(root).compactMap({ $0 as? NSScrollView }).first else {
                throw Failure(message: "transcript scroll view missing")
            }
            return scroll
        }
        do {
            await store.connectAndLoad()
            let first = CodexThread(id: "fixture-thread", projectID: nil, cwd: "/tmp/fixture",
                                    title: "First long history", preview: "", updatedAt: Date(), state: .idle, hasMessages: true)
            let second = CodexThread(id: "fixture-history-thread", projectID: nil, cwd: "/tmp/fixture",
                                     title: "Second long history", preview: "", updatedAt: Date(), state: .idle, hasMessages: true)
            store.focusDetailWindow(first)
            try await loadHistory()
            let firstPanel = try window(first)
            await settle(firstPanel.contentView)
            let firstRoot = firstPanel.contentView!
            let firstScroll = try scrollView(firstPanel)
            guard let firstPresentation = firstPanel.chatPresentation else { throw Failure(message: "presentation missing") }
            try check(firstPresentation.scroll.isAtBottom, "new window opens at bottom")
            firstPresentation.scroll.userWillScroll()
            firstScroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, firstPresentation.scroll.bottomOffset - 600)))
            firstPresentation.scroll.userDidScroll()
            await settle(firstRoot)
            let readingOffset = firstScroll.contentView.bounds.minY
            guard let message = descendants(firstRoot).compactMap({ $0 as? RichMessageTextView }).first(where: {
                firstScroll.contentView.bounds.intersects($0.convert($0.bounds, to: firstScroll.contentView))
            }) else { throw Failure(message: "no visible native message to select") }
            firstPanel.makeFirstResponder(message)
            message.setSelectedRange(NSRange(location: 0, length: min(8, message.string.utf16.count)))
            let selection = message.selectedRange()

            coordinator.completeDetailOpen(present: false)
            store.focusDetailWindow(first)
            await settle(firstRoot)
            try check(firstPanel.contentView === firstRoot && (try scrollView(firstPanel)) === firstScroll,
                      "same chat focus preserves native root and scroll view")
            try check(message.selectedRange() == selection, "same chat focus preserves text selection")
            try check(abs(firstScroll.contentView.bounds.minY - readingOffset) < 1, "same chat focus preserves reading offset")

            store.focusDetailWindow(second)
            try await loadHistory()
            let secondPanel = try window(second)
            await settle(secondPanel.contentView)
            let secondScroll = try scrollView(secondPanel)
            try check(!firstPresentation.isActive, "previous chat freezes without replacing transcript")
            try check(firstPanel.contentView === firstRoot && (try scrollView(firstPanel)) === firstScroll,
                      "deactivation preserves native transcript identity")
            try check(message.selectedRange() == selection, "deactivation preserves native message selection")

            let started = Date()
            for index in 0..<100 {
                let target = index.isMultiple(of: 2) ? first : second
                store.focusDetailWindow(target)
                try check(store.visibleDetailItems.count == 120 && !store.visibleDetailLoading,
                          "rapid switch restores history synchronously: \(index)")
                try check(store.visibleDetailItems.allSatisfy { $0.id.hasPrefix(target.id + "-message-") },
                          "rapid switch never shows other chat history: \(index)")
            }
            let switchDuration = Date().timeIntervalSince(started)
            store.focusDetailWindow(first)
            try await loadHistory()
            await settle(firstRoot)
            try check(coordinator.openDetailWindowCount == 2, "100 switches do not create more windows")
            try check((try scrollView(firstPanel)) === firstScroll && (try scrollView(secondPanel)) === secondScroll,
                      "100 switches reuse both native scroll views")
            try check(abs(firstScroll.contentView.bounds.minY - readingOffset) < 1,
                      "switching away and back preserves exact reading offset")
            try check(!firstPresentation.scroll.followingBottom && message.selectedRange() == selection,
                      "selection and manual reading mode survive rapid switching")

            // Also let SwiftUI actually render each intermediate active/inactive
            // state; a synchronous burst alone can hide reconstruction bugs.
            for index in 0..<10 {
                store.focusDetailWindow(second)
                await settle(secondPanel.contentView)
                store.focusDetailWindow(first)
                await settle(firstRoot)
                try check((try scrollView(firstPanel)) === firstScroll && (try scrollView(secondPanel)) === secondScroll,
                          "rendered switch keeps native transcript identity: \(index)")
                try check(abs(firstScroll.contentView.bounds.minY - readingOffset) < 1 && message.selectedRange() == selection,
                          "rendered switch keeps reading and selection: \(index)")
            }

            _ = store.visibleDetailItems
            let builds = store.timelineBuildCount
            for _ in 0..<10_000 { _ = store.visibleDetailItems; _ = store.visibleDetailLoading }
            try check(store.timelineBuildCount == builds, "20,000 unchanged getters reuse one merged timeline")
            store.composerText = "draft only"
            _ = store.visibleDetailItems
            try check(store.timelineBuildCount == builds, "typing does not rebuild history")
            store.toggleDetailActivity()
            _ = store.visibleDetailItems
            try check(store.timelineBuildCount > builds, "command visibility invalidates timeline cache")
            store.composerText = ""
            store.beginWriting(from: .detail)
            await settle(firstRoot)
            try check((try scrollView(firstPanel)) === firstScroll, "Enter opens composer without recreating transcript")
            store.submitMessage() // Empty Enter: close composer; no send.
            await settle(firstRoot)
            try check(!store.composerVisible && (try scrollView(firstPanel)) === firstScroll,
                      "empty Enter closes composer without recreating transcript")

            let focusToken = store.composerFocusToken
            store.selectRecent(id: first.id)
            store.beginWriting(from: .recents)
            await settle(firstRoot)
            try check(store.composerVisible && store.composerFocusToken > focusToken,
                      "history refresh does not cancel explicit Enter-to-type focus")
            store.submitMessage()

            let handoff = DeferredWindowFocus()
            var current: NSWindow? = firstPanel
            var activations: [String] = []
            handoff.request(firstPanel, isCurrent: { $0 === current }) { activations.append("first") }
            current = secondPanel
            handoff.request(secondPanel, isCurrent: { $0 === current }) { activations.append("second") }
            await settle()
            try check(activations == ["second"], "only latest deferred key-window change activates a chat")
            handoff.request(firstPanel, isCurrent: { $0 === current }) { activations.append("stale") }
            current = nil
            await settle()
            try check(activations == ["second"], "late callback cannot steal focus back from another window/app")
            handoff.request(secondPanel, isCurrent: { _ in true }) { activations.append("cancelled") }
            handoff.cancel()
            await settle()
            try check(activations == ["second"], "closing/replacing target cancels deferred focus")
            handoff.request(firstPanel) { activations.append("hidden") }
            await settle()
            try check(activations == ["second"], "production focus guard rejects a hidden non-key window")

            store.focusDetailWindow(second)
            weak var releasedPresentation: ChatWindowPresentation?
            weak var releasedScroll: ChatScrollController?
            releasedPresentation = secondPanel.chatPresentation
            releasedScroll = secondPanel.chatPresentation?.scroll
            coordinator.dismiss(.detail)
            await settle()
            try check(secondPanel.chatPresentation == nil && secondPanel.contentView == nil,
                      "Q releases closed window UI and snapshot")
            try check(releasedPresentation == nil && releasedScroll == nil, "closed presentation and controller deallocate")
            try check(coordinator.openDetailWindowCount == 1 && store.detailThread?.id == first.id,
                      "Q preserves other open chat")
            store.focusDetailWindow(second)
            try await loadHistory()
            let reopened = try window(second)
            await settle(reopened.contentView)
            try check(reopened.chatPresentation?.scroll.followingBottom == true && reopened.chatPresentation?.scroll.isAtBottom == true,
                      "fresh opening after Q starts at latest message")

            // Exercise Q during actual fake-server work, not just idle history.
            store.beginWriting(from: .detail)
            store.composerText = "STEER_BASE"
            store.submitMessage()
            for _ in 0..<100 where !store.canSteerCurrentTurn {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            try check(store.canSteerCurrentTurn, "background fixture starts a running turn")
            coordinator.dismiss(.detail)
            try check(store.runState(for: second.id) == .working && reopened.contentView == nil,
                      "Q frees UI without stopping running Codex work")
            store.focusDetailWindow(second)
            for _ in 0..<100 where !store.visibleDetailItems.contains(where: { $0.text == "STEER_BASE" }) {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            try check(store.canSteerCurrentTurn && store.visibleDetailItems.contains { $0.text == "STEER_BASE" },
                      "reopening restores working state and new history")
            store.beginWriting(from: .detail)
            store.composerText = "STEER_FOLLOWUP"
            store.submitMessage()
            store.toggleQueueMode()
            try check(store.beginQueueSpace(), "queue action targets reopened working conversation")
            store.finishQueueSpace(longPressTriggered: false)
            coordinator.dismiss(.detail)
            for _ in 0..<150 where store.messageSending {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            try check(!store.messageSending && store.detailThread?.id == first.id,
                      "hidden work completes without switching the user's current chat")
            store.focusDetailWindow(second)
            for _ in 0..<150 where !store.visibleDetailItems.contains(where: { $0.text == "BAVBAV_STEER_OK" }) {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            try check(store.visibleDetailItems.contains { $0.text == "BAVBAV_STEER_OK" },
                      "completed background reply survives close/reopen and cache invalidation")
            try check(NSApp.windows.filter { !initialWindows.contains(ObjectIdentifier($0)) }.allSatisfy { !$0.isVisible },
                      "all test windows remained hidden")
            await store.shutdown()
            print("BAVBAV PERFORMANCE CHECK PASSED: \(checks) checks; 100 cached switches in \(String(format: "%.3f", switchDuration))s; native identity/selection/scroll preservation, focus races, cache, Q release; hidden fixtures only")
            return true
        } catch {
            await store.shutdown()
            print("BAVBAV PERFORMANCE CHECK FAILED after \(checks) checks: \(error)")
            return false
        }
    }
}
