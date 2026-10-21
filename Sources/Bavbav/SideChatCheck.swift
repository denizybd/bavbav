import AppKit
import BavbavCore

@MainActor
enum SideChatCheck {
    private struct Failure: Error { let message: String }

    /// Real store/controller paths against a local RPC fixture. No account
    /// prompt, browser, microphone, general clipboard, or visible window.
    static func run() async -> Bool {
        guard ProcessInfo.processInfo.environment["BAVBAV_CODEX_BIN"]?.hasSuffix("BavbavFakeCodex") == true else {
            print("SIDE CHAT CHECK REQUIRES LOCAL FAKE SERVER"); return false
        }
        let suite = "Bavbav.SideChatCheck.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let neutralDirectory = directory.appendingPathComponent("standalone", isDirectory: true)
        let logURL = directory.appendingPathComponent("requests.jsonl")
        let flags = ["BAVBAV_FIXTURE_TWO_THREADS", "BAVBAV_SIDE_CHAT_CHECK", "BAVBAV_SIDE_CHAT_REQUEST_LOG"]
        let previousFlags = flags.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        setenv("BAVBAV_FIXTURE_TWO_THREADS", "1", 1)
        setenv("BAVBAV_SIDE_CHAT_CHECK", "1", 1)
        setenv("BAVBAV_SIDE_CHAT_REQUEST_LOG", logURL.path, 1)
        defaults.set(["fixture-standalone"], forKey: "chat.standalone-ids")
        let overrides = ThreadRuntimeOverrides(model: "source-model", effort: "high")
        defaults.set(try? JSONEncoder().encode(overrides), forKey: "runtime.overrides.fixture-thread")
        let initialWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        defer {
            NSApp.windows.filter { !initialWindows.contains(ObjectIdentifier($0)) }.forEach { $0.close() }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory) // Unique fixture-owned directory only.
            for (name, value) in previousFlags {
                if let value { setenv(name, value, 1) } else { unsetenv(name) }
            }
        }
        let store = OverlayStore(defaults: defaults, standaloneDirectory: neutralDirectory)
        let panels = PanelCoordinator(store: store, windowSizeDefaults: defaults)
        store.onOpenDetail = { [weak panels] in panels?.completeDetailOpen(present: false) }
        let router = InputRouter(store: store, coordinator: panels)
        var checks = 0
        var report: [String: Any] = ["success": false, "renderKind": "hidden-native-AppKit-SwiftUI-view",
            "productionDataUsed": false, "remoteNetworkUsed": false, "mediaRequested": false,
            "physicalUserInteraction": false, "generalClipboardUsed": false,
            "hostPID": Int(ProcessInfo.processInfo.processIdentifier)]
        func argument(_ name: String) -> String? {
            guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
            return CommandLine.arguments[index + 1]
        }
        func writeReport() throws {
            guard let path = argument("--side-chat-report") else { return }
            let bytes = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try bytes.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
            checks += 1
            if !value() { throw Failure(message: message) }
        }
        func waitUntil(_ condition: () -> Bool, line: UInt = #line) async throws {
            for _ in 0..<200 {
                if condition() { return }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            throw Failure(message: "timeout at \(line): \(store.composerError ?? "")")
        }
        func panel(_ id: String) throws -> OverlayPanel {
            guard let result = NSApp.windows.compactMap({ $0 as? OverlayPanel }).first(where: { $0.representedThread?.id == id }) else {
                throw Failure(message: "missing real native window for \(id)")
            }
            return result
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func settle(_ window: NSWindow) async {
            for _ in 0..<12 {
                window.contentView?.layoutSubtreeIfNeeded()
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        func requests(_ method: String) -> [[String: Any]] {
            guard let data = try? Data(contentsOf: logURL), let text = String(data: data, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap {
                guard let row = try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any],
                      row["method"] as? String == method else { return nil }
                return row["params"] as? [String: Any]
            }
        }
        func source(id: String, title: String = "Fixture", cwd: String = "/tmp/fixture") -> CodexThread {
            CodexThread(id: id, projectID: nil, cwd: cwd, title: title, preview: "fixture",
                        updatedAt: Date(), state: .idle, hasMessages: true)
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            await store.connectAndLoad()
            guard let first = store.recentChats.first(where: { $0.id == "fixture-thread" }),
                  let other = store.recentChats.first(where: { $0.id == "fixture-history-thread" }) else {
                throw Failure(message: "fixture source catalog missing")
            }
            store.focusDetailWindow(first)
            try await waitUntil { !store.detailLoading && !store.detailActivityLoading && !store.visibleDetailItems.isEmpty }
            let firstPanel = try panel(first.id)
            let firstRoot = firstPanel.contentView
            let history = store.visibleDetailItems.map(\.id)
            store.beginWriting(from: .detail)
            store.composerText = "Bu kaynak sohbetin gönderilmemiş taslağı"
            let sourceDraft = store.composerText
            let attachment = ComposerAttachment(path: directory.appendingPathComponent("draft.txt").path,
                                                name: "draft.txt", byteCount: 0, isImage: false)
            store.addComposerAttachments([attachment], to: first.id)
            store.setComposerMode(.plan)
            store.updateGoalObjective("Only the source owns this unfinished goal")
            let extrasBefore = defaults.data(forKey: "composer.extras.\(first.id)")
            let goalBefore = defaults.string(forKey: "composer.goal-draft.\(first.id)")
            store.handleServerEvent(.turnStarted(threadID: first.id, turnID: "source-working-turn"))
            // Queue a separate prompt without sending any model turn.
            store.composerText = "Kaynakta sırada bekleyen mesaj"
            store.submitMessage()
            store.beginWriting(from: .detail)
            store.composerText = sourceDraft
            store.addComposerAttachments([attachment], to: first.id)
            let sourceQueue = store.currentQueuedPrompts
            let sourceExtras = defaults.data(forKey: "composer.extras.\(first.id)")

            let operation = Task { await store.openSideChat(from: first) }
            try await waitUntil { store.sideChatCreatingIDs.contains(first.id) }
            let duplicate = await store.openSideChat(from: first)
            try check(duplicate == nil, "duplicate async fork suppressed for the same source")
            guard let branch = await operation.value else { throw Failure(message: store.sideChatError(for: first.id) ?? "fork missing") }
            try await waitUntil { !store.detailLoading && !store.detailActivityLoading && !store.visibleDetailItems.isEmpty }
            let branchPanel = try panel(branch.id)
            try check(branch.id != first.id && branch.id == "side-fork-1", "new persistent server branch identity")
            try check(branchPanel !== firstPanel && branchPanel.contentView !== firstRoot, "separate actual native chat window and transcript")
            try check(firstPanel.representedThread?.id == first.id && firstPanel.contentView === firstRoot,
                      "source native window and hosting identity remain unchanged")
            try check(firstPanel.chatPresentation?.snapshot.thread.id == first.id && firstPanel.chatPresentation?.snapshot.items.map(\.id) == history,
                      "source history frozen in its own snapshot, not replaced with the fork")
            try check(store.visibleDetailItems.map(\.id) == history, "server fork history independently loaded")
            try check(branch.cwd == first.cwd && branch.projectID == first.projectID && !store.isStandalone(branch),
                      "project membership and working directory preserved")
            try check(!store.composerVisible && store.composerText.isEmpty && store.composerAttachments.isEmpty,
                      "branch opens read-only with an independent empty draft")
            try check(store.composerMode == .default && store.currentQueuedPrompts.isEmpty,
                      "source plan mode and queue not moved to branch")
            try check(store.activeOverrides == overrides, "effective source model and effort preserved independently")
            try check(store.runState(for: first.id) == .working && store.runState(for: branch.id) == .idle,
                      "running source continues; fork not falsely marked running")
            try check(defaults.dictionary(forKey: "thread.redirects")?[first.id] == nil, "no source redirect or destructive writer-recovery migration")
            try check(defaults.string(forKey: "draft.\(first.id)") == sourceDraft && defaults.data(forKey: "composer.extras.\(first.id)") == sourceExtras,
                      "source draft and attachments retained")
            try check(defaults.string(forKey: "composer.goal-draft.\(first.id)") == goalBefore
                      && defaults.string(forKey: "composer.goal-draft.\(branch.id)") == nil,
                      "source goal draft retained and never cloned as an active goal")
            try check(store.queuedPromptsByThreadID[first.id] == sourceQueue && !sourceQueue.isEmpty,
                      "source queued prompt remains owned by source")
            try check(requests("turn/start").isEmpty && requests("turn/interrupt").isEmpty,
                      "fork does not send or interrupt a real turn")
            let forkRequests = requests("thread/fork")
            try check(forkRequests.count == 1 && forkRequests[0]["threadId"] as? String == first.id
                      && forkRequests[0]["model"] as? String == "source-model"
                      && forkRequests[0]["ephemeral"] as? Bool == false,
                      "one actual persistent fork RPC from the captured source")
            try check(store.recentChats.contains { $0.id == first.id } && store.recentChats.contains { $0.id == branch.id },
                      "source and fork both retained in catalogs")
            store.beginWriting(from: .detail)
            store.composerText = "Independent branch draft"
            store.focusDetailWindow(first)
            try check(store.composerText == sourceDraft && store.composerAttachments == [attachment] && store.composerMode == .plan,
                      "reopening source restores its own draft, attachment and mode")
            store.focusDetailWindow(branch)
            try check(store.composerText == "Independent branch draft", "branch draft independently restored")

            store.focusDetailWindow(other)
            store.beginWriting(from: .detail)
            store.composerText = "Another window's draft"
            let inactiveBranch = await store.openSideChat(from: first)
            try check(inactiveBranch?.id == "side-fork-2" && requests("thread/fork").last?["threadId"] as? String == first.id,
                      "inactive-window action forks the displayed source, not global active chat")
            try check(defaults.string(forKey: "draft.\(other.id)") == "Another window's draft", "other active window's draft preserved during async fork")

            let standalone = source(id: "fixture-standalone", title: "Serbest sohbet", cwd: neutralDirectory.path)
            store.focusDetailWindow(standalone)
            let standaloneBranch = await store.openSideChat(from: standalone)
            guard let standaloneBranch else { throw Failure(message: "standalone fork missing") }
            try check(store.isStandalone(standaloneBranch) && standaloneBranch.cwd == neutralDirectory.path && standaloneBranch.projectID == nil,
                      "standalone branch remains outside project chats")
            try check((defaults.stringArray(forKey: "chat.standalone-ids") ?? []).contains(standalone.id)
                      && (defaults.stringArray(forKey: "chat.standalone-ids") ?? []).contains(standaloneBranch.id),
                      "both standalone identities durably classified")
            await store.refresh()
            try check(store.standaloneChats.contains { $0.id == standaloneBranch.id }, "standalone fork survives catalog refresh")
            let reloaded = OverlayStore(defaults: defaults, standaloneDirectory: neutralDirectory)
            try check(reloaded.isStandalone(standaloneBranch), "standalone branch classification survives new store")
            await reloaded.shutdown()

            let failed = await store.openSideChat(from: source(id: "side-fail"))
            try check(failed == nil && store.sideChatError(for: "side-fail") != nil && !store.sideChatCreatingIDs.contains("side-fail"),
                      "fork failure exposes error and clears duplicate guard")
            let same = await store.openSideChat(from: source(id: "side-same"))
            try check(same == nil && store.sideChatError(for: "side-same") != nil, "same-ID response never replaces source as fake fork")
            let nameFailed = await store.openSideChat(from: source(id: "side-name-fail", title: "SIDE_NAME_FAIL"))
            try check(nameFailed != nil && store.sideChatError(for: "side-name-fail")?.contains("adı kaydedilemedi") == true,
                      "rename failure retains already-created durable branch and reports partial failure")

            store.beginRename(thread: first)
            try check(store.renameTarget?.id == first.id && store.detailThread?.id == first.id && store.renameTarget?.scope == "chat.read",
                      "header rename targets exact displayed source, including inactive window")
            store.renameName = "Kaynak başlık · yeni"
            store.commitRename()
            try await waitUntil { !store.renameSubmitting }
            try check(store.detailThread?.title == "Kaynak başlık · yeni" && firstPanel.representedThread?.title == "Kaynak başlık · yeni",
                      "header rename saves server title and updates original native window")
            try check(branchPanel.representedThread?.title == branch.title, "renaming source leaves branch title alone")

            // A composer can remain open underneath the search bar. Search's
            // native Return must never fall through to chat.write.full/send.
            store.focusDetailWindow(branch)
            try await waitUntil { !store.detailLoading && !store.detailActivityLoading }
            store.beginWriting(from: .detail)
            store.composerText = "Do not send this draft when searching"
            let searchDraft = store.composerText
            await settle(branchPanel)
            NotificationCenter.default.post(name: .chatFindInConversation, object: branchPanel)
            await settle(branchPanel)
            guard let field = branchPanel.contentView.flatMap({ descendants($0).compactMap { $0 as? ChatSearchField.Field }.first }) else {
                throw Failure(message: "Cmd+F notification did not create the actual native search field")
            }
            try check(!descendants(firstPanel.contentView!).contains { $0 is ChatSearchField.Field },
                      "find notification opens only its originating native window")
            branchPanel.makeFirstResponder(field)
            guard let editor = field.currentEditor() as? NSTextView else { throw Failure(message: "search field has no native editor") }
            editor.selectAll(nil)
            editor.insertText("Answer", replacementRange: editor.selectedRange())
            await settle(branchPanel)
            try check(field.stringValue == "Answer" && ChatSearchField.isEditing(in: branchPanel),
                      "actual native search typing is recognized independently of the composer")
            try check(router.scope(for: branchPanel) == "text.other", "search scope wins over the visible nonempty composer")
            let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: branchPanel.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 36)!
            try check(router.handle(enter) === enter, "Return remains owned by the native search field, not submitMessage")
            editor.keyDown(with: enter)
            await settle(branchPanel)
            try check(store.composerText == searchDraft && store.composerVisible && store.currentQueuedPrompts.isEmpty,
                      "native search Return leaves the visible composer draft unsent and unchanged")
            try check(branchPanel.chatPresentation?.scroll.followingBottom == false,
                      "search actually navigates a loaded message without enabling bottom auto-follow")
            report["sourceThreadID"] = first.id
            report["branchThreadID"] = branch.id
            report["openNativeChatWindows"] = panels.openDetailWindowCount
            report["sourceWindowRetained"] = firstPanel.contentView === firstRoot
            report["windowVisible"] = branchPanel.isVisible
            report["searchFieldType"] = String(describing: type(of: field))
            report["searchQuery"] = field.stringValue
            report["searchOwnsReturn"] = router.scope(for: branchPanel) == "text.other"
            report["composerDraftPreserved"] = store.composerText == searchDraft
            report["forkRPCCount"] = requests("thread/fork").count
            report["turnStartRPCCount"] = requests("turn/start").count
            report["interruptRPCCount"] = requests("turn/interrupt").count
            report["windowWidth"] = Double(branchPanel.frame.width)
            report["windowHeight"] = Double(branchPanel.frame.height)
            if let path = argument("--side-chat-render") {
                guard let view = branchPanel.contentView else { throw Failure(message: "native chat content missing for render") }
                view.appearance = NSAppearance(named: .darkAqua)
                await settle(branchPanel)
                view.displayIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    throw Failure(message: "native chat view bitmap unavailable")
                }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw Failure(message: "native chat view PNG encoding failed")
                }
                try png.write(to: URL(fileURLWithPath: path), options: .atomic)
                report["renderWritten"] = true
                report["renderWidth"] = bitmap.pixelsWide
                report["renderHeight"] = bitmap.pixelsHigh
                report["renderBytes"] = png.count
                report["menuRenderScope"] = "header ellipsis trigger only; native popup deliberately not presented"
            }
            branchPanel.makeFirstResponder(nil)
            try check(!panels.hasVisibleWindows && NSApp.windows.filter { !initialWindows.contains(ObjectIdentifier($0)) }.allSatisfy { !$0.isVisible },
                      "entire regression stays hidden; no foreground disruption")
            try check(requests("turn/start").isEmpty && extrasBefore != nil, "no accidental model request throughout side-chat and menu flow")
            await store.shutdown()
            report["assertions"] = checks
            report["success"] = true
            try writeReport()
            print("BAVBAV SIDE CHAT CHECK PASSED: \(checks) checks; persistent RPC fork/history, separate hidden native windows, source draft/queue/attachments/goal/runtime, inactive targeting, standalone persistence, errors; fake server only")
            return true
        } catch {
            await store.shutdown()
            report["assertions"] = checks
            report["success"] = false
            report["error"] = String(describing: error)
            try? writeReport()
            print("BAVBAV SIDE CHAT CHECK FAILED: \(error)")
            return false
        }
    }
}
