import AppKit
import BavbavCore

@MainActor
enum ComposerActionsCheck {
    private struct Failure: Error { let message: String }

    /// Native text input and hidden per-chat windows backed only by the local
    /// fixture. Never opens a file chooser, reads the general clipboard, or
    /// sends a request to a signed-in account.
    static func run() async -> Bool {
        guard ProcessInfo.processInfo.environment["BAVBAV_CODEX_BIN"]?.hasSuffix("BavbavFakeCodex") == true else {
            print("COMPOSER CHECK REQUIRES LOCAL FAKE SERVER"); return false
        }
        let suite = "Bavbav.ComposerCheck.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let logURL = directory.appendingPathComponent("requests.jsonl")
        let priorFlags = ["BAVBAV_FIXTURE_TWO_THREADS", "BAVBAV_COMPOSER_CHECK", "BAVBAV_COMPOSER_REQUEST_LOG"]
            .map { ($0, ProcessInfo.processInfo.environment[$0]) }
        setenv("BAVBAV_FIXTURE_TWO_THREADS", "1", 1)
        setenv("BAVBAV_COMPOSER_CHECK", "1", 1)
        setenv("BAVBAV_COMPOSER_REQUEST_LOG", logURL.path, 1)
        let initialWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        defer {
            defaults.removePersistentDomain(forName: suite)
            NSApp.windows.filter { !initialWindows.contains(ObjectIdentifier($0)) }.forEach { $0.close() }
            try? FileManager.default.removeItem(at: directory) // Unique fixture-owned files only.
            for (name, value) in priorFlags {
                if let value { setenv(name, value, 1) } else { unsetenv(name) }
            }
        }
        let store = OverlayStore(defaults: defaults, standaloneDirectory: directory.appendingPathComponent("standalone"),
                                 attachmentIntake: AttachmentIntake(directory: directory.appendingPathComponent("intake")))
        let panels = PanelCoordinator(store: store, windowSizeDefaults: defaults)
        store.onOpenDetail = { [weak panels] in panels?.completeDetailOpen(present: false) }
        let router = InputRouter(store: store, coordinator: panels)
        let protocolClient = CodexAppServer()
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
            checks += 1
            if !value() { throw Failure(message: message) }
        }
        func settle(_ window: NSWindow? = nil) async {
            for _ in 0..<8 {
                window?.contentView?.layoutSubtreeIfNeeded()
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        func waitUntil(_ condition: () -> Bool, line: UInt = #line) async throws {
            for _ in 0..<200 {
                if condition() { return }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            throw Failure(message: "timed out at line \(line), check \(checks), thread \(store.detailThread?.id ?? "none"), sending \(store.messageSending), steering \(store.steerSending), queue \(store.currentQueueCount): \(store.composerError ?? "no error")")
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func panel(_ threadID: String) throws -> OverlayPanel {
            guard let panel = NSApp.windows.compactMap({ $0 as? OverlayPanel }).first(where: { $0.representedThread?.id == threadID }) else {
                throw Failure(message: "missing native panel for \(threadID)")
            }
            return panel
        }
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], in window: NSWindow,
                 type: NSEvent.EventType = .keyDown) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: ShortcutStroke(code).menuKey,
                charactersIgnoringModifiers: ShortcutStroke(code).menuKey, isARepeat: false, keyCode: code)!
        }
        func tap(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], in window: NSWindow) {
            _ = router.handle(key(code, flags, in: window))
            _ = router.handle(key(code, flags, in: window, type: .keyUp))
        }
        func type(_ text: String, in window: NSWindow) async throws -> NSTextView {
            await settle(window)
            guard let editor = descendants(window.contentView!).compactMap({ $0 as? NSTextView }).first(where: { $0.isEditable }) else {
                throw Failure(message: "missing native composer editor")
            }
            window.makeFirstResponder(editor)
            editor.selectAll(nil)
            editor.insertText(text, replacementRange: editor.selectedRange())
            try check(store.composerText == text, "actual native editing reaches composer before send")
            await settle(window)
            try check(editor.string == text && store.composerText == text, "SwiftUI refresh preserves native composer text")
            return editor
        }
        func requests(_ method: String) -> [[String: Any]] {
            guard let data = try? Data(contentsOf: logURL), let string = String(data: data, encoding: .utf8) else { return [] }
            return string.split(separator: "\n").compactMap { line in
                guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      row["method"] as? String == method else { return nil }
                return row["params"] as? [String: Any]
            }
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let imageURL = directory.appendingPathComponent("Screen Shot ü.png")
            let documentURL = directory.appendingPathComponent("Decision [draft].txt")
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let imageData = bitmap.representation(using: .png, properties: [:])!
            try imageData.write(to: imageURL)
            try Data("Document fixture; not model instructions.".utf8).write(to: documentURL)
            let screenshot = ComposerAttachment(path: imageURL.path, name: imageURL.lastPathComponent, byteCount: Int64(imageData.count), isImage: true)
            let document = ComposerAttachment(path: documentURL.path, name: documentURL.lastPathComponent, byteCount: 42, isImage: false)
            let encodedDocumentPath = String(data: try JSONEncoder().encode(documentURL.path), encoding: .utf8)!
            await store.connectAndLoad()
            guard let first = store.recentChats.first(where: { $0.id == "fixture-thread" }),
                  let second = store.recentChats.first(where: { $0.id == "fixture-history-thread" }) else {
                throw Failure(message: "fixture conversations missing")
            }
            store.focusDetailWindow(first)
            try await waitUntil { !store.visibleDetailLoading }
            let firstPanel = try panel(first.id)
            tap(36, in: firstPanel)
            try check(store.composerVisible, "Enter from read mode opens composer")
            let editor = try await type("q w s / native draft", in: firstPanel)
            let q = key(12, in: firstPanel)
            try check(router.handle(q) === q && store.composerVisible, "Q remains plain text while composer is open")
            tap(0, .command, in: firstPanel)
            try check(editor.selectedRange().length == editor.string.utf16.count, "Command A keeps native composer selection")
            _ = try await type("", in: firstPanel)
            tap(36, in: firstPanel)
            try check(!store.composerVisible && requests("turn/start").isEmpty, "empty Enter closes composer without network submission")

            let dropboard = NSPasteboard(name: NSPasteboard.Name(suite + ".drop"))
            defer { dropboard.releaseGlobally() }
            dropboard.writeObjects([imageURL as NSURL])
            store.beginWriting(from: .detail)
            store.toggleComposerTools()
            try check(store.composerToolsVisible, "drop fixture starts with the plus drawer open")
            try check(store.importComposerPasteboard(dropboard, for: first) && store.composerImporting && store.composerVisible,
                      "real native file drop starts intake and opens writing without sending")
            try check(!store.composerToolsVisible, "dropping a file dismisses the drawer so caption typing owns the keyboard")
            store.submitMessage()
            try check(store.composerVisible && requests("turn/start").isEmpty,
                      "Enter while a screenshot is still being copied cannot submit an incomplete prompt or close the draft")
            store.cancelWriting()
            panels.dismiss(.detail)
            store.focusDetailWindow(second)
            try await waitUntil { !store.composerAttachments(for: first.id).isEmpty }
            try check(store.detailThread?.id == second.id && store.composerAttachments.isEmpty,
                      "real asynchronous drop survives Q without stealing focus or attaching to another chat")
            store.focusDetailWindow(first)
            try check(store.composerAttachments.count == 1 && store.composerAttachments[0].path != imageURL.path,
                      "drop draft owns a durable copy independent of transient screenshot source")
            let imported = store.composerAttachments[0]
            store.removeComposerAttachment(id: imported.id)
            try check(FileManager.default.fileExists(atPath: imported.path), "removing draft reference cannot delete a queued or sent attachment's durable file")
            // Install only a fixture redirect while an actual native file
            // import is pending; the production callback must resolve it at
            // delivery time, just as after an active-writer handoff.
            try check(store.importComposerPasteboard(dropboard, for: first), "second native drop accepted before redirect fixture")
            defaults.set([first.id: second.id], forKey: "thread.redirects")
            store.focusDetailWindow(second)
            try await waitUntil { !store.composerAttachments(for: second.id).isEmpty }
            try check(store.composerAttachments(for: first.id).isEmpty && store.composerAttachments(for: second.id).count == 1,
                      "pending import resolves a saved writer redirect before choosing destination draft")
            let redirectedAttachment = store.composerAttachments(for: second.id)[0]
            store.removeComposerAttachment(id: redirectedAttachment.id)
            defaults.removeObject(forKey: "thread.redirects")

            // An asynchronous receiver retains the original target, even after
            // focus moves or its chat window was closed before intake finishes.
            let dropTarget = first.id
            store.focusDetailWindow(second)
            try await waitUntil { !store.visibleDetailLoading }
            let secondPanel = try panel(second.id)
            store.addComposerAttachments([screenshot, document], to: dropTarget)
            try check(store.detailThread?.id == second.id && store.composerAttachments.isEmpty,
                      "late intake does not attach to the newly focused chat")
            store.focusDetailWindow(first)
            try check(store.composerAttachments.map(\.id) == [screenshot.id, document.id], "captured original thread receives attachments")
            store.setComposerMode(.plan)
            panels.dismiss(.detail)
            store.addComposerAttachments([screenshot], to: dropTarget)
            store.focusDetailWindow(first)
            try check(Set(store.composerAttachments.map(\.id)) == Set([screenshot.id, document.id]), "Q and late duplicate delivery retain one copy per attachment")
            try check(store.composerMode == .plan, "per-thread mode survives Q and reopen")
            let reopened = try panel(first.id)
            tap(36, in: reopened)
            _ = try await type("COMPOSER_PLAN inspect attachments", in: reopened)
            tap(36, in: reopened)
            try await waitUntil { !store.messageSending && requests("turn/start").count == 1 }
            guard let start = requests("turn/start").last,
                  let inputs = start["input"] as? [[String: Any]],
                  let collaboration = start["collaborationMode"] as? [String: Any],
                  let settings = collaboration["settings"] as? [String: Any] else { throw Failure(message: "missing plan wire payload") }
            try check(start["threadId"] as? String == first.id, "send keeps original thread identity")
            try check(collaboration["mode"] as? String == "plan" && settings["model"] as? String == "fake-model", "plan uses real protocol mode and resolved model")
            try check(settings["reasoning_effort"] as? String == "low" && settings["developer_instructions"] is NSNull,
                      "plan retains effort without inventing hidden instructions")
            try check(inputs.contains { $0["type"] as? String == "localImage" && $0["path"] as? String == imageURL.path }, "screenshot is a localImage input, not mere filename text")
            try check(inputs.compactMap { $0["text"] as? String }.joined().contains(encodedDocumentPath), "document path is included in explicit document input manifest")
            try check(!store.composerVisible && store.composerAttachments.isEmpty, "successful send clears only submitted draft attachments")
            try await waitUntil { store.visibleDetailItems.contains { $0.text == "BAVBAV_COMPOSER_START_OK" } }
            let expectedEcho = ComposerInput.displayText(text: "COMPOSER_PLAN inspect attachments", attachments: [screenshot, document])
            try check(store.visibleDetailItems.filter { $0.role == .user && $0.text == expectedEcho }.count == 1, "attachment send does not duplicate optimistic user message")

            tap(36, in: reopened)
            store.setComposerMode(.default)
            store.addComposerAttachments([screenshot], to: first.id)
            try check(store.composerHasPayload && router.scope(for: reopened) == "chat.write.full", "attachment-only draft uses send scope, never empty-close scope")
            tap(36, in: reopened)
            try await waitUntil { !store.messageSending && requests("turn/start").count == 2 }
            let imageOnly = requests("turn/start").last!
            try check((imageOnly["input"] as? [[String: Any]])?.contains { $0["type"] as? String == "localImage" } == true, "Enter submits attachment-only input")
            try check((imageOnly["collaborationMode"] as? [String: Any])?["mode"] as? String == "default", "normal mode explicitly resets previous plan mode")

            tap(36, in: reopened)
            store.setComposerMode(.plan)
            store.addComposerAttachments([document], to: first.id)
            _ = try await type("COMPOSER_FAIL keep my attachment", in: reopened)
            tap(36, in: reopened)
            store.focusDetailWindow(second)
            tap(36, in: secondPanel)
            _ = try await type("unrelated new draft", in: secondPanel)
            try await waitUntil { !store.messageSending }
            try check(store.detailThread?.id == second.id && store.composerText == "unrelated new draft" && store.composerAttachments.isEmpty,
                      "failed background send cannot overwrite the other chat's text or attachments")
            store.focusDetailWindow(first)
            try check(store.composerText == "COMPOSER_FAIL keep my attachment" && store.composerAttachments.map(\.id) == [document.id],
                      "failed send restores text and document to original thread")
            try check(store.composerMode == .plan, "failure retains plan selection")
            store.removeComposerAttachment(id: document.id)
            store.composerText = ""
            store.setComposerMode(.default)

            store.beginWriting(from: .detail)
            _ = try await type("COMPOSER_HOLD", in: reopened)
            tap(36, in: reopened)
            try await waitUntil { store.canSteerCurrentTurn }
            store.beginWriting(from: .detail)
            store.setComposerMode(.plan)
            store.addComposerAttachments([screenshot], to: first.id)
            _ = try await type("queued plan with screenshot", in: reopened)
            tap(36, in: reopened)
            try check(store.currentQueueCount == 1 && store.currentQueuedPrompts[0].attachments == [screenshot]
                      && store.currentQueuedPrompts[0].collaborationMode == .plan, "queue captures attachments and mode together with text")
            store.toggleQueueMode()
            _ = store.beginQueueSpace()
            store.finishQueueSpace(longPressTriggered: false)
            await settle()
            try check(store.currentQueueCount == 1 && requests("turn/steer").isEmpty,
                      "plan queued during default turn cannot silently lose mode via steer")
            store.editSelectedQueuedPrompt()
            try check(store.composerText == "queued plan with screenshot" && store.composerAttachments == [screenshot]
                      && store.composerMode == .plan, "editing queued prompt restores entire draft including image and plan")
            store.setComposerMode(.default)
            _ = try await type("COMPOSER_FAIL steer with screenshot", in: reopened)
            tap(36, in: reopened)
            store.toggleQueueMode()
            _ = store.beginQueueSpace()
            store.finishQueueSpace(longPressTriggered: false)
            try await waitUntil { !store.steerSending && requests("turn/steer").count == 1 }
            try check(store.currentQueueCount == 1 && store.currentQueuedPrompts[0].attachments == [screenshot]
                      && store.currentQueuedPrompts[0].collaborationMode == .default,
                      "failed steer restores queue entry without losing screenshot or mode")
            store.editSelectedQueuedPrompt()
            _ = try await type("COMPOSER_STEER keep screenshot", in: reopened)
            tap(36, in: reopened)
            store.beginWriting(from: .detail)
            store.setComposerMode(.plan)
            store.addComposerAttachments([document], to: first.id)
            _ = try await type("COMPOSER_NEXT_PLAN", in: reopened)
            tap(36, in: reopened)
            try check(store.currentQueueCount == 2, "separate queued drafts retain independent attachments")
            let startsBeforeQueue = requests("turn/start").count
            store.toggleQueueMode()
            _ = store.beginQueueSpace()
            store.finishQueueSpace(longPressTriggered: false)
            try await waitUntil { !store.messageSending && !store.steerSending && requests("turn/steer").count == 2
                && requests("turn/start").count == startsBeforeQueue + 1 }
            let steered = requests("turn/steer").last!
            try check((steered["input"] as? [[String: Any]])?.contains { $0["type"] as? String == "localImage" && $0["path"] as? String == screenshot.path } == true,
                      "successful steer carries native localImage payload")
            let nextPlan = requests("turn/start").last!
            try check((nextPlan["collaborationMode"] as? [String: Any])?["mode"] as? String == "plan"
                      && (nextPlan["input"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined().contains(encodedDocumentPath) == true,
                      "automatic next turn preserves queued plan and document")
            try check(store.currentQueueCount == 0, "successful steer then next turn drains only submitted entries")

            store.beginWriting(from: .detail)
            store.toggleComposerTools()
            try check(router.scope(for: reopened) == "composer.tools", "inline plus menu owns its keyboard scope")
            do {
                let output = ProcessInfo.processInfo.environment["BAVBAV_COMPOSER_ARTIFACT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
                store.addComposerAttachments([screenshot, document], to: first.id)
                let originalSize = reopened.contentView!.bounds.size
                store.closeComposerTools()
                await settle(reopened)
                let existingScrolls = Set(descendants(reopened.contentView!).compactMap { $0 as? NSScrollView }.map(ObjectIdentifier.init))
                store.toggleComposerTools()
                await settle(reopened)
                guard let drawer = descendants(reopened.contentView!).compactMap({ $0 as? NSScrollView })
                    .first(where: { !existingScrolls.contains(ObjectIdentifier($0)) }) else {
                    throw Failure(message: "inline menu native scroll view missing")
                }
                for size in [NSSize(width: 640, height: 640), NSSize(width: 400, height: 320), NSSize(width: 320, height: 400)] {
                    reopened.setContentSize(size)
                    await settle(reopened)
                    guard let view = reopened.contentView else { throw Failure(message: "composer native root unavailable") }
                    let frame = drawer.convert(drawer.bounds, to: view)
                    try check(frame.height >= 130, "inline menu retains useful visible height at \(Int(size.width))x\(Int(size.height))")
                    let local = NSPoint(x: frame.midX, y: frame.midY)
                    let hit = view.hitTest(local)
                    try check(view.bounds.contains(local) && hit.map { $0.isDescendant(of: drawer) || drawer.isDescendant(of: $0) } == true,
                              "inline menu remains inside native hit-test area at \(Int(size.width))x\(Int(size.height))")
                    guard let output else { continue }
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure(message: "composer snapshot unavailable") }
                    view.displayIfNeeded()
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure(message: "composer PNG unavailable") }
                    let url = output.appendingPathComponent("composer-menu-\(Int(size.width))x\(Int(size.height)).png")
                    try png.write(to: url)
                    print("BAVBAV COMPOSER VISUAL: \(url.path); actual native content \(Int(view.bounds.width))x\(Int(view.bounds.height))")
                }
                reopened.setContentSize(originalSize)
                store.removeComposerAttachment(id: screenshot.id)
                store.removeComposerAttachment(id: document.id)
                await settle(reopened)
            }
            tap(1, in: reopened)
            tap(1, in: reopened)
            tap(49, in: reopened)
            try check(store.composerMode == .plan && !store.composerToolsVisible && store.composerVisible,
                      "W/S and Space select plan without sending or closing composer")
            store.toggleComposerTools()
            tap(12, in: reopened)
            try check(!store.composerToolsVisible && store.detailThread?.id == first.id && store.composerVisible,
                      "Q closes plus menu only, preserving current chat and editor")
            let goalOriginalSize = reopened.contentView!.bounds.size
            reopened.setContentSize(NSSize(width: 400, height: 320))
            await settle(reopened)
            store.toggleComposerTools()
            for _ in 0..<3 { tap(1, in: reopened) }
            tap(36, in: reopened)
            try check(store.composerGoalEditing && router.scope(for: reopened) == "composer.goal.write",
                      "Goal action opens explicit objective editor without enabling a goal yet")
            await settle(reopened)
            guard let goalField = descendants(reopened.contentView!).compactMap({ $0 as? RenameNameField.Field }).first else {
                throw Failure(message: "missing native goal objective field")
            }
            reopened.makeFirstResponder(goalField)
            guard let goalEditor = goalField.currentEditor() as? NSTextView else { throw Failure(message: "goal field editor unavailable") }
            goalEditor.selectAll(nil)
            goalEditor.insertText("Finish only this thread's fixture", replacementRange: goalEditor.selectedRange())
            try check(store.goalObjective == "Finish only this thread's fixture", "actual native goal field writes latest text before Enter")
            await settle(reopened)
            try check(goalField.stringValue == store.goalObjective && goalEditor.string == store.goalObjective,
                      "goal input survives SwiftUI update, guarding previous stale native rename bug")
            if let artifactPath = ProcessInfo.processInfo.environment["BAVBAV_COMPOSER_ARTIFACT_DIR"],
               let view = reopened.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let url = URL(fileURLWithPath: artifactPath).appendingPathComponent("composer-goal-400x320.png")
                try bitmap.representation(using: .png, properties: [:])?.write(to: url)
                print("BAVBAV COMPOSER VISUAL: \(url.path)")
            }
            print("COMPOSER GOAL RECT: bounds \(goalField.bounds), visible \(goalField.visibleRect), parent \(goalField.superview?.bounds ?? .zero)")
            try check(goalField.visibleRect.height >= 18 && goalField.visibleRect.width >= 100,
                      "keyboard-selected Goal editor is scrolled into view at native minimum window size")
            tap(36, in: reopened)
            store.focusDetailWindow(second)
            await settle()
            try check(store.composerGoal == nil && store.detailThread?.id == second.id, "late goal acknowledgment cannot set another chat's goal")
            store.focusDetailWindow(first)
            try await waitUntil { !store.composerGoalBusy }
            try check(store.composerGoal?.objective == "Finish only this thread's fixture"
                      && requests("thread/goal/set").last?["threadId"] as? String == first.id,
                      "native Goal Enter persists the exact objective on its captured thread")
            store.clearComposerGoal()
            try await waitUntil { !store.composerGoalBusy }
            try check(store.composerGoal == nil, "native goal clear updates current thread state")
            reopened.setContentSize(goalOriginalSize)
            store.beginWriting(from: .detail)
            store.beginComposerGoalEditing()
            store.updateGoalObjective("")
            let goalsBeforeEmpty = requests("thread/goal/set").count
            tap(36, in: reopened)
            try check(!store.composerGoalEditing && requests("thread/goal/set").count == goalsBeforeEmpty,
                      "empty Goal Enter cancels instead of inventing an objective")
            store.closeComposerTools()

            store.setComposerMode(.plan)
            store.addComposerAttachments([document], to: first.id)
            _ = try await type("COMPOSER_FAIL older outgoing draft", in: reopened)
            let beforeNewDraftRace = requests("turn/start").count
            tap(36, in: reopened)
            store.beginWriting(from: .detail)
            store.composerText = "newer unsent draft"
            store.addComposerAttachments([screenshot], to: first.id)
            try await waitUntil { !store.messageSending && requests("turn/start").count == beforeNewDraftRace + 1 }
            try check(store.composerText == "newer unsent draft" && store.composerAttachments == [screenshot],
                      "failed older send cannot overwrite a newer draft in the same conversation")
            try check(store.currentQueuedPrompts.count == 1 && store.currentQueuedPrompts[0].requiresRetry
                      && store.currentQueuedPrompts[0].attachments == [document] && store.currentQueuedPrompts[0].collaborationMode == .plan,
                      "failed payload remains recoverable with mode/files in explicit-retry queue")
            await settle()
            try check(requests("turn/start").count == beforeNewDraftRace + 1, "failed payload never enters an automatic retry loop")
            store.cancelWriting()
            store.toggleQueueMode()
            store.editSelectedQueuedPrompt()
            try check(store.composerText == "COMPOSER_FAIL older outgoing draft" && store.composerAttachments == [document],
                      "editing failed queued prompt restores its document instead of mixing with current draft")
            try check(store.currentQueuedPrompts.count == 1 && store.currentQueuedPrompts[0].text == "newer unsent draft"
                      && store.currentQueuedPrompts[0].attachments == [screenshot] && store.currentQueuedPrompts[0].requiresRetry,
                      "editing queued prompt preserves displaced newer draft in explicit-retry queue")

            let missing = ComposerAttachment(path: directory.appendingPathComponent("gone.png").path,
                name: "gone.png", byteCount: 1, isImage: true)
            let beforeMissing = requests("thread/resume").count + requests("turn/start").count
            var missingRejected = false
            do {
                _ = try await protocolClient.startTurn(threadID: "missing-fixture", text: "", attachments: [missing])
            } catch { missingRejected = true }
            try check(missingRejected && requests("thread/resume").count + requests("turn/start").count == beforeMissing,
                      "unreadable attachment fails before resume or turn transport")
            let trickyURL = directory.appendingPathComponent("quoted\"file\nnew line.txt")
            try Data("fixture".utf8).write(to: trickyURL)
            let tricky = ComposerAttachment(path: trickyURL.path, name: trickyURL.lastPathComponent, byteCount: 7, isImage: false)
            let manifest = try ComposerInput.items(text: "", attachments: [tricky]).compactMap { $0["text"] as? String }.joined()
            try check(manifest.contains("quoted\\\"file\\nnew line.txt") && !manifest.contains(trickyURL.lastPathComponent),
                      "document quotes and newlines stay JSON escaped within a single manifest entry")

            let owned = directory.appendingPathComponent("render-owned", isDirectory: true)
            let ownedImageURL = owned.appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent("screen.png")
            let ownedDocURL = owned.appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent("quoted\"doc.txt")
            try FileManager.default.createDirectory(at: ownedImageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: ownedDocURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let largeBitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 200, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            largeBitmap.bitmapData?.initialize(repeating: 0, count: largeBitmap.bytesPerRow * largeBitmap.pixelsHigh)
            try largeBitmap.representation(using: .png, properties: [:])!.write(to: ownedImageURL)
            try Data("document".utf8).write(to: ownedDocURL)
            let ownedImage = ComposerAttachment(path: ownedImageURL.path, name: ownedImageURL.lastPathComponent, byteCount: 1, isImage: true)
            let ownedDoc = ComposerAttachment(path: ownedDocURL.path, name: ownedDocURL.lastPathComponent, byteCount: 1, isImage: false)
            let renderedText = ComposerInput.displayText(text: "Original prompt", attachments: [ownedDoc, ownedImage])
            let rendered = SentMessageAttachments.parse(text: renderedText, ownedDirectory: owned)
            try check(rendered.text == "Original prompt" && rendered.attachments.map(\.path) == [ownedDoc.path, ownedImage.path],
                      "sent attachment parsing round trips mixed documents/images without losing prompt")
            for untouched in ["```\n[LOCAL IMAGE] \(ownedImage.path)",
                              "[LOCAL IMAGE] \(ownedImage.path)\nordinary text after marker",
                              "[LOCAL IMAGE] \(imageURL.path)",
                              "[LOCAL IMAGE] \(owned.path)/not-a-uuid/screen.png",
                              "[LOCAL IMAGE] \(owned.path)/\(UUID().uuidString)/../screen.png"] {
                let parsed = SentMessageAttachments.parse(text: untouched, ownedDirectory: owned)
                try check(parsed.text == untouched && parsed.attachments.isEmpty,
                          "attachment display never consumes code, ordinary paths, non-suffix text, or traversal markers")
            }
            let thumbnail = await AttachmentThumbnailCache.shared.image(for: ownedImage, ownedDirectory: owned)
            try check(thumbnail != nil && max(thumbnail!.width, thumbnail!.height) <= 96,
                      "thumbnail decoding downsamples real image to bounded 96 pixel size")
            let outsideThumbnail = await AttachmentThumbnailCache.shared.image(for: screenshot, ownedDirectory: owned)
            let documentThumbnail = await AttachmentThumbnailCache.shared.image(for: ownedDoc, ownedDirectory: owned)
            try check(outsideThumbnail == nil && documentThumbnail == nil, "thumbnail cache refuses outside-owned images and non-image documents")

            // Goal is an actual per-thread server feature, not a prompt prefix.
            let noGoal = try await protocolClient.readThreadGoal(threadID: "goal-fixture")
            try check(noGoal == nil, "empty goal response is represented as not set")
            for (objective, budget) in [("   ", nil as Int64?), (String(repeating: "x", count: 4_001), nil), ("valid", 0), ("valid", -1)] {
                let before = requests("thread/goal/set").count
                var rejected = false
                do { _ = try await protocolClient.setThreadGoal(threadID: "goal-fixture", objective: objective, tokenBudget: budget) }
                catch { rejected = true }
                try check(rejected && requests("thread/goal/set").count == before, "invalid goal objective/budget rejected before transport")
            }
            let goal = try await protocolClient.setThreadGoal(threadID: "goal-fixture", objective: "Finish the fixture")
            try check(goal.objective == "Finish the fixture", "goal set returns typed server objective")
            let savedGoal = try await protocolClient.readThreadGoal(threadID: "goal-fixture")
            try check(savedGoal?.objective == goal.objective, "goal reads back from same server thread")
            try check(requests("thread/goal/set").last?["tokenBudget"] == nil, "no unrequested goal token budget is invented")
            try check(requests("thread/goal/set").last?["threadId"] as? String == "goal-fixture"
                      && requests("thread/goal/set").last?["status"] as? String == "active", "goal activation uses explicit objective and exact target thread")
            let cleared = try await protocolClient.clearThreadGoal(threadID: "goal-fixture")
            let gone = try await protocolClient.readThreadGoal(threadID: "goal-fixture")
            try check(cleared && gone == nil, "goal clear removes only requested thread goal")

            let readsBeforeExplicit = requests("thread/read").count + requests("thread/turns/list").count + requests("model/list").count
            _ = try await protocolClient.startTurn(threadID: "explicit-runtime-fixture", text: "COMPOSER_EXPLICIT_CONFIG",
                model: "requested-model", effort: "high", collaborationMode: .plan)
            let explicit = requests("turn/start").last!["collaborationMode"] as? [String: Any]
            let explicitSettings = explicit?["settings"] as? [String: Any]
            try check(explicitSettings?["model"] as? String == "requested-model" && explicitSettings?["reasoning_effort"] as? String == "high",
                      "explicit model and effort survive plan configuration unchanged")
            try check(requests("thread/read").count + requests("thread/turns/list").count + requests("model/list").count == readsBeforeExplicit,
                      "explicit plan configuration does not scan history or fetch another model catalog")

            let desktopOwned = CodexThread(id: "desktop-owned", projectID: nil, cwd: "/tmp/fixture",
                title: "Desktop writer fixture", preview: "", updatedAt: Date(), state: .idle, hasMessages: true)
            store.focusDetailWindow(desktopOwned)
            try await waitUntil { !store.visibleDetailLoading }
            store.beginWriting(from: .detail)
            store.setComposerMode(.plan)
            store.addComposerAttachments([screenshot], to: desktopOwned.id)
            store.composerText = "COMPOSER_FORK_INITIAL"
            let beforeFork = requests("turn/start").count
            store.submitMessage()
            // Queue before the active-writer conflict resolves. Fork adoption
            // must migrate all payload fields, not just its visible text.
            store.beginWriting(from: .detail)
            store.setComposerMode(.default)
            store.addComposerAttachments([document], to: desktopOwned.id)
            store.composerText = "COMPOSER_FORK_QUEUED"
            store.submitMessage()
            try check(store.queuedPromptCount(for: desktopOwned.id) == 1, "attachment queue can form while writer handoff is in flight")
            try await waitUntil { !store.messageSending && requests("turn/start").count == beforeFork + 2 }
            let forkTurns = Array(requests("turn/start").suffix(2))
            let forkPanel = NSApp.windows.compactMap { $0 as? OverlayPanel }
                .first { $0.representedThread?.id == "fixture-fork" }
            try check(forkPanel?.chatPresentation?.snapshot.thread.id == "fixture-fork",
                      "writer handoff updates the displayed window thread, not only its panel registry")
            try check(forkPanel?.chatPresentation?.isActive == true,
                      "writer handoff keeps the live presentation active")
            try check(forkTurns.allSatisfy { $0["threadId"] as? String == "fixture-fork" },
                      "writer-conflict handoff targets fork for original and queued turn")
            try check((forkTurns[0]["collaborationMode"] as? [String: Any])?["mode"] as? String == "plan"
                      && (forkTurns[0]["input"] as? [[String: Any]])?.contains { $0["path"] as? String == screenshot.path } == true,
                      "writer-conflict retry retains original image and plan mode")
            try check((forkTurns[1]["collaborationMode"] as? [String: Any])?["mode"] as? String == "default"
                      && (forkTurns[1]["input"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined().contains(encodedDocumentPath) == true,
                      "fork migration retains queued document and explicit normal mode")
            try check(store.queuedPromptCount(for: desktopOwned.id) == 0 && store.queuedPromptCount(for: "fixture-fork") == 0,
                      "writer handoff leaves no orphaned or duplicated queue entries")

            let earlyThread = CodexThread(id: "composer-early-steer", projectID: nil, cwd: "/tmp/fixture",
                title: "Early Plan steer", preview: "", updatedAt: Date(), state: .idle, hasMessages: true)
            store.focusDetailWindow(earlyThread)
            try await waitUntil { !store.visibleDetailLoading }
            store.beginWriting(from: .detail)
            store.setComposerMode(.plan)
            store.composerText = "COMPOSER_DELAY_ACK_HOLD"
            store.submitMessage()
            try await waitUntil { store.canSteerCurrentTurn }
            store.beginWriting(from: .detail)
            store.addComposerAttachments([screenshot], to: earlyThread.id)
            store.composerText = "COMPOSER_STEER before start acknowledgment"
            store.submitMessage()
            let steersBeforeEarly = requests("turn/steer").count
            store.toggleQueueMode()
            _ = store.beginQueueSpace()
            store.finishQueueSpace(longPressTriggered: false)
            try await waitUntil { !store.steerSending && requests("turn/steer").count == steersBeforeEarly + 1 }
            try check(store.currentQueueCount == 0, "Plan steer before start acknowledgment recognizes synchronously captured turn mode")
            await settle()
            await settle()
            try check(store.runState(for: earlyThread.id) != .working,
                      "late start acknowledgment cannot resurrect a turn already finished by early steer")

            let interactionThread = CodexThread(id: "composer-interaction-thread", projectID: nil, cwd: "/tmp/fixture",
                title: "Plan question fixture", preview: "", updatedAt: Date(), state: .idle, hasMessages: true)
            store.focusDetailWindow(interactionThread)
            try await waitUntil { !store.visibleDetailLoading }
            let interactionPanel = try panel(interactionThread.id)
            store.beginWriting(from: .detail)
            store.setComposerMode(.plan)
            store.composerText = "COMPOSER_INTERACTION_HELD"
            store.submitMessage()
            try await waitUntil { store.canSteerCurrentTurn }
            store.beginWriting(from: .detail)
            store.toggleComposerTools()
            try check(store.composerToolsVisible, "plus drawer can open while a plan turn is awaiting server input")
            try await waitUntil { store.activeInteraction != nil }
            try check(!store.composerVisible && !store.composerToolsVisible,
                      "incoming plan question hides both composer and its inline drawer")
            await settle(interactionPanel)
            try check(router.scope(for: interactionPanel) == "interaction.list",
                      "hidden plus menu cannot steal W/S/Space from incoming plan question")
            try check(NSApp.windows.filter { !initialWindows.contains(ObjectIdentifier($0)) }.allSatisfy { !$0.isVisible }, "every fixture window stayed hidden")
            await protocolClient.shutdown()
            await store.shutdown()
            print("BAVBAV COMPOSER CHECK PASSED: \(checks) checks; native typing/Enter, attachment-only send, per-thread draft/Q isolation, failure recovery, plan/default wire payload and goal lifecycle; hidden fake-server fixtures only")
            return true
        } catch {
            await protocolClient.shutdown()
            await store.shutdown()
            print("BAVBAV COMPOSER CHECK FAILED after \(checks) checks: \(error)")
            return false
        }
    }
}
