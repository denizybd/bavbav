import AppKit
import BavbavCore

@MainActor
enum RenameCheck {
    private struct Failure: Error { let message: String }
    private final class EditingProbe: NSTextView {
        var copies = 0
        var pastes = 0
        override func copy(_ sender: Any?) { copies += 1 }
        override func pasteAsPlainText(_ sender: Any?) { pastes += 1 }
    }

    static func run() async -> Bool {
        guard ProcessInfo.processInfo.environment["BAVBAV_CODEX_BIN"]?.hasSuffix("BavbavFakeCodex") == true else {
            print("RENAME CHECK REQUIRES LOCAL FAKE SERVER"); return false
        }
        setenv("BAVBAV_FIXTURE_TWO_THREADS", "1", 1)
        let suite = "Bavbav.RenameCheck.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let initialWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        defer {
            defaults.removePersistentDomain(forName: suite)
            NSApp.windows.filter { !initialWindows.contains(ObjectIdentifier($0)) }.forEach { $0.close() }
        }
        let store = OverlayStore(defaults: defaults, standaloneDirectory: URL(fileURLWithPath: "/tmp/rename-standalone"))
        let panels = PanelCoordinator(store: store, windowSizeDefaults: defaults)
        store.onOpenDetail = { [weak panels] in panels?.completeDetailOpen(present: false) }
        let router = InputRouter(store: store, coordinator: panels)
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            checks += 1
            if !condition() { throw Failure(message: message) }
        }
        func waitUntil(_ condition: () -> Bool) async throws {
            for _ in 0..<150 {
                if condition() { return }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            throw Failure(message: "timed out: \(store.renameError ?? store.composerError ?? "")")
        }
        func frame(_ panel: NSWindow) async {
            for _ in 0..<8 {
                panel.contentView?.layoutSubtreeIfNeeded()
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        func panel(_ kind: OverlayKind, threadID: String? = nil) throws -> OverlayPanel {
            guard let value = NSApp.windows.compactMap({ $0 as? OverlayPanel }).first(where: {
                $0.overlayKind == kind && (threadID == nil || $0.representedThread?.id == threadID)
            }) else { throw Failure(message: "missing native panel") }
            return value
        }
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], in window: NSWindow,
                 type: NSEvent.EventType = .keyDown, repeated: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: ShortcutStroke(code).menuKey,
                charactersIgnoringModifiers: ShortcutStroke(code).menuKey, isARepeat: repeated, keyCode: code)!
        }
        func tap(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], in window: NSWindow) {
            _ = router.handle(key(code, flags, in: window))
            _ = router.handle(key(code, flags, in: window, type: .keyUp))
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        do {
            await store.connectAndLoad()
            let projects = try panel(.projects), recents = try panel(.recents), standalone = try panel(.chatgpt)
            guard let project = store.projects.first(where: { $0.path == "/tmp/fixture" }),
                  let thread = store.recentChats.first(where: { $0.id == "fixture-thread" }),
                  let other = store.recentChats.first(where: { $0.id == "fixture-history-thread" }),
                  let standaloneThread = store.standaloneChats.first else { throw Failure(message: "fixture catalog missing") }
            store.selectLeft(id: project.id)
            tap(49, .option, in: projects)
            try check(store.renameTarget?.id == project.id && store.renameName == project.name,
                      "Option Space in projects prefills selected project's name")
            await frame(projects)
            try check(descendants(projects.contentView!).contains { ($0 as? RenameNameField.Field)?.stringValue == project.name },
                      "real native rename field is rendered")
            try check(!store.leftIsReordering && !store.leftCreationActive, "rename does not arm Space reorder/create")
            for code: UInt16 in [12, 13, 1, 49] {
                let event = key(code, in: projects)
                try check(router.handle(event) === event, "Q/W/S/Space remain ordinary name text: \(code)")
            }
            let editor = EditingProbe(frame: .zero)
            editor.string = "name q w s"
            projects.contentView?.addSubview(editor)
            projects.makeFirstResponder(editor)
            tap(0, .command, in: projects)
            tap(8, .command, in: projects)
            tap(9, .command, in: projects)
            try check(editor.selectedRange().length == editor.string.utf16.count && editor.copies == 1 && editor.pastes == 1,
                      "native Command A/C/V are routed while renaming; actual clipboard untouched")
            projects.makeFirstResponder(nil)
            editor.removeFromSuperview()
            store.renameName = "   "
            tap(36, in: projects)
            try check(store.renameTarget == nil && store.projects.contains { $0.id == project.id && $0.name == project.name },
                      "empty Enter cancels without renaming")
            tap(49, .option, in: projects)
            store.renameName = "Taslak"
            tap(47, .command, in: projects)
            try check(store.renameTarget == nil, "Command period explicitly cancels")
            tap(49, .option, in: projects)
            store.renameName = "İsim / görünen ad"
            tap(76, in: projects)
            try check(store.projects.contains { $0.id == project.id && $0.name == "İsim / görünen ad" && $0.path == project.path },
                      "keypad Enter changes project display name, never its folder path/identity")
            await store.refresh()
            try check(store.projects.contains { $0.id == project.id && $0.name == "İsim / görünen ad" }, "project alias survives refresh")
            let reloaded = OverlayStore(defaults: defaults, standaloneDirectory: URL(fileURLWithPath: "/tmp/rename-standalone"))
            await reloaded.connectAndLoad()
            try check(reloaded.projects.contains { $0.path == project.path && $0.name == "İsim / görünen ad" },
                      "project alias survives a new store/session")
            await reloaded.shutdown()

            store.selectLeft(id: project.id)
            store.activateSelection(.projects)
            try await waitUntil { store.projectChats.contains { $0.id == thread.id } }
            store.selectLeft(id: thread.id)
            store.focusDetailWindow(thread)
            try await waitUntil { !store.visibleDetailLoading }
            let detail = try panel(.detail, threadID: thread.id)
            let root = detail.contentView
            let order = store.recentChats.map(\.id)
            tap(49, .option, in: projects)
            try check(store.renameTarget?.scope == "projects.chats", "inside a project renames the selected chat")
            store.renameName = "Yorum (3) · yeni"
            tap(36, in: projects)
            tap(36, in: projects) // A second Enter cannot submit twice.
            try await waitUntil { !store.renameSubmitting }
            try check(store.renameTarget == nil && store.projectChats.contains { $0.id == thread.id && $0.title == "Yorum (3) · yeni" },
                      "project chat rename saved")
            try check(store.recentChats.contains { $0.id == thread.id && $0.title == "Yorum (3) · yeni" }, "recent list reflects same renamed chat")
            try check(store.detailThread?.title == "Yorum (3) · yeni" && detail.representedThread?.title == "Yorum (3) · yeni",
                      "active open chat updates title")
            try check(detail.contentView === root && store.recentChats.map(\.id) == order,
                      "rename preserves hosting view and list order")
            await store.refresh()
            try check(store.projectChats.contains { $0.id == thread.id && $0.title == "Yorum (3) · yeni" }, "server catalog retains renamed title")

            store.focusDetailWindow(other)
            store.selectRecent(id: thread.id)
            tap(49, .option, in: recents)
            store.renameName = "Son sohbet adı"
            store.selectRecent(id: other.id) // Selection changes cannot retarget an in-progress edit.
            tap(36, in: recents)
            try await waitUntil { !store.renameSubmitting }
            try check(detail.chatPresentation?.snapshot.thread.title == "Son sohbet adı" && detail.contentView === root,
                      "inactive open chat title updates without rebuilding transcript")
            try check(store.recentChats.contains { $0.id == other.id && $0.title == other.title }, "rename target is immutable when selection changes")

            store.selectRecent(id: thread.id)
            tap(49, .option, in: recents)
            store.renameName = "RENAME_FAIL"
            tap(36, in: recents)
            try await waitUntil { !store.renameSubmitting }
            try check(store.renameError != nil && store.renameName == "RENAME_FAIL" && store.renameTarget != nil,
                      "server failure retains edit text and exposes error")
            try check(store.recentChats.contains { $0.id == thread.id && $0.title == "Son sohbet adı" }, "failed save leaves old title intact")
            store.renameName = "Geç yanıt yarışı"
            let refresh = Task { await store.refresh() }
            try? await Task.sleep(nanoseconds: 50_000_000)
            tap(36, in: recents)
            try await waitUntil { !store.renameSubmitting }
            await refresh.value
            try check(store.recentChats.contains { $0.id == thread.id && $0.title == "Geç yanıt yarışı" },
                      "older in-flight catalog response cannot undo successful rename")

            store.selectChatGPT(id: OverlayStore.chatGPTLauncherID)
            tap(49, .option, in: standalone)
            try check(store.renameTarget == nil && !store.standaloneCreating, "CHAT launcher is not a renameable conversation")
            store.selectChatGPT(id: standaloneThread.id)
            tap(49, .option, in: standalone)
            try check(store.renameTarget?.scope == "standalone.list", "Command 3 saved chats support rename")
            store.renameName = "Günlük sohbet"
            tap(36, in: standalone)
            try await waitUntil { !store.renameSubmitting }
            await store.refresh()
            try check(store.standaloneChats.contains { $0.id == standaloneThread.id && $0.title == "Günlük sohbet" },
                      "standalone name persists in server catalog")
            try check(!store.recentChats.contains { $0.id == standaloneThread.id }, "rename preserves standalone/project isolation")

            let bindings = panels.appPreferences.keyBindings
            try check(bindings.set("standalone.list.rename.key", .init(strokes: [.init(15, .option)])), "rename shortcut is individually configurable")
            tap(49, .option, in: standalone)
            try check(store.renameTarget == nil, "remapped old Option Space no longer starts rename")
            tap(15, .option, in: standalone)
            try check(store.renameTarget?.id == standaloneThread.id, "custom rename shortcut works")
            try check(bindings.set("rename.standalone.list.full.commitRename.key", .init(strokes: [.init(36, .command)])), "rename save is independently configurable")
            store.renameName = "Kaydetme tuşu"
            tap(36, in: standalone)
            try check(store.renameTarget != nil && !store.renameSubmitting, "plain Enter cannot bypass remapped save")
            tap(36, .command, in: standalone)
            try await waitUntil { !store.renameSubmitting }
            try check(store.renameTarget == nil, "custom save key commits")
            store.selectRecent(id: thread.id)
            _ = router.handle(key(49, .option, in: recents))
            store.renameName = "keep draft"
            _ = router.handle(key(49, .option, in: recents, repeated: true))
            try check(store.renameName == "keep draft" && !store.recentIsReordering, "held Option Space cannot reset draft or reorder")
            _ = router.handle(key(49, in: recents, type: .keyUp))
            store.cancelRename()
            let chat = try panel(.detail, threadID: other.id)
            store.beginWriting(from: .detail)
            let ordinary = key(49, .option, in: chat)
            try check(router.handle(ordinary) === ordinary && store.renameTarget == nil, "Option Space stays native while composing a chat")
            try check(NSApp.windows.filter { !initialWindows.contains(ObjectIdentifier($0)) }.allSatisfy { !$0.isVisible },
                      "all QA windows remained hidden")
            await store.shutdown()
            print("BAVBAV RENAME CHECK PASSED: \(checks) checks; project/inside-project/recent/standalone, save/cancel/error, durable names, stale refresh, live/frozen titles, configurable shortcuts, native editing; fake server only")
            return true
        } catch {
            await store.shutdown()
            print("BAVBAV RENAME CHECK FAILED after \(checks) checks: \(error)")
            return false
        }
    }
}
