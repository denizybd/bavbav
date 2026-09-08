import AppKit
import BavbavCore
import SwiftUI

@MainActor
enum JournalCheck {
    private struct Failure: Error { let message: String }
    static func run(live: Bool = false) async -> Bool {
        guard live || ProcessInfo.processInfo.environment["BAVBAV_CODEX_BIN"]?.hasSuffix("BavbavFakeCodex") == true else {
            print("JOURNAL CHECK REQUIRES LOCAL FAKE SERVER"); return false
        }
        let suite = "Bavbav.JournalCheck.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let originalWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        defer {
            defaults.removePersistentDomain(forName: suite)
            NSApp.windows.filter { !originalWindows.contains(ObjectIdentifier($0)) }.forEach { $0.close() }
            try? FileManager.default.removeItem(at: directory) // Only this unique check directory.
        }
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ description: String) throws {
            checks += 1
            if !condition() { throw Failure(message: description) }
        }
        func settle(_ predicate: () -> Bool) async {
            for _ in 0..<160 {
                if predicate() { return }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
        }
        let date = JournalRules.date("2026-09-07")!
        let thread = CodexThread(id: "journal-source", projectID: nil, cwd: "/tmp/fixture", title: "Seyahat",
                                 preview: "", updatedAt: date, state: .idle, hasMessages: true)
        let personal = CodexMessage(id: "u1", role: .user, text: "Geçenlerde Mısır'a gitmiştim.", timestamp: date)
        let candidate = JournalCandidate(summary: "Mısır seyahati yapıldı.", kind: .event, eventKey: "Mısır seyahati",
                                         sources: [JournalSource(messageID: "u1", quote: personal.text)])
        var job = JournalJob(thread: thread, turnID: "t1", channel: "ChatGPT", capturedAt: date)
        job.messages = [personal]; job.ready = true
        do {
            let notes = JournalRules.accepted([candidate], job: job, existing: [])
            try check(notes.count == 1 && notes[0].eventDay == nil && notes[0].recordedDay == "2026-09-07", "vague travel date stays unknown")
            try check(notes[0].sources.first?.quote == personal.text && notes[0].thread.id == thread.id, "source evidence/thread retained")
            try check(JournalRules.accepted([candidate, candidate], job: job, existing: []).count == 1, "duplicate candidates in same response")
            try check(JournalRules.accepted([candidate], job: job, existing: notes).isEmpty, "repeat event suppressed")
            var deleted = notes[0]; deleted.deleted = true
            try check(JournalRules.accepted([candidate], job: job, existing: [deleted]).isEmpty, "deleted event not recreated")
            let falseSource = JournalCandidate(summary: "Yanlış", kind: .event, eventKey: "wrong",
                                               sources: [JournalSource(messageID: "missing", quote: personal.text)])
            try check(JournalRules.accepted([falseSource], job: job, existing: []).isEmpty, "unknown message ID rejected")
            let falseQuote = JournalCandidate(summary: "Yanlış", kind: .event, eventKey: "wrong",
                                              sources: [JournalSource(messageID: "u1", quote: "Ben Fransa'ya gittim")])
            try check(JournalRules.accepted([falseQuote], job: job, existing: []).isEmpty, "fabricated quote rejected")
            let low = JournalCandidate(summary: candidate.summary, kind: .event, eventKey: "travel", confidence: 0.7, sources: candidate.sources)
            try check(JournalRules.accepted([low], job: job, existing: []).isEmpty, "low confidence excluded")
            let inventedDay = JournalCandidate(summary: candidate.summary, kind: .event, eventKey: "travel",
                eventDay: "2026-09-01", dateQuote: "Geçenlerde", sources: candidate.sources)
            try check(JournalRules.accepted([inventedDay], job: job, existing: []).first?.eventDay == nil, "model cannot invent precise day")

            for (text, day) in [("Dün Mısır'a gittim.", "2026-09-06"), ("Bugün Mısır'a gittim.", "2026-09-07"),
                                ("2026-09-02 tarihinde Mısır'a gittim.", "2026-09-02"),
                                ("2 Eylül 2026 tarihinde Mısır'a gittim.", "2026-09-02"),
                                ("2 Mayıs 2026 tarihinde Mısır'a gittim.", "2026-05-02"),
                                ("02.09.2026 tarihinde Mısır'a gittim.", "2026-09-02")] {
                var dated = job; dated.messages = [CodexMessage(id: "u1", role: .user, text: text, timestamp: date)]
                let c = JournalCandidate(summary: candidate.summary, kind: .event, eventKey: "travel", eventDay: day,
                                         dateQuote: text, sources: [JournalSource(messageID: "u1", quote: text)])
                try check(JournalRules.accepted([c], job: dated, existing: []).first?.eventDay == day, "verified date: \(text)")
            }
            let futureText = "Yarın Mısır'a gideceğim."
            var futureJob = job; futureJob.messages = [CodexMessage(id: "u1", role: .user, text: futureText, timestamp: date)]
            let plan = JournalCandidate(summary: "Mısır seyahati planlandı.", kind: .plan, eventKey: "travel",
                                        eventDay: "2026-09-08", dateQuote: "Yarın",
                                        sources: [JournalSource(messageID: "u1", quote: futureText)])
            try check(JournalRules.accepted([plan], job: futureJob, existing: []).first?.kind == .plan, "plan remains distinct from occurred event")
            let planNotes = JournalRules.accepted([plan], job: futureJob, existing: notes)
            try check(planNotes.first?.eventDay == "2026-09-08", "future plan date preserved")
            var assistantOnly = job
            assistantOnly.messages = [CodexMessage(id: "u1", role: .agent, text: personal.text)]
            try check(JournalRules.accepted([candidate], job: assistantOnly, existing: []).isEmpty, "assistant cannot create user biography")
            var contextual = job
            let proposal = CodexMessage(id: "proposal", role: .agent, text: "Proje arayüzünü Swift ile yapabiliriz.", timestamp: date)
            let acceptance = CodexMessage(id: "acceptance", role: .user, text: "Tamam, Swift seçimini onaylıyorum.", timestamp: date)
            contextual.context = [proposal]; contextual.messages = [acceptance]
            let decision = JournalCandidate(summary: "Proje arayüzü için Swift seçildi.", kind: .decision, eventKey: "arayuz swift",
                sources: [JournalSource(messageID: "proposal", quote: proposal.text), JournalSource(messageID: "acceptance", quote: acceptance.text)])
            try check(JournalRules.accepted([decision], job: contextual, existing: []).count == 1, "new acceptance can cite previous proposal")
            contextual.messages = []
            try check(JournalRules.accepted([decision], job: contextual, existing: []).isEmpty, "old context alone cannot generate a note")
            for invalid in ["2026-02-30", "2026-13-01", "26-09-07", "", "today"] {
                try check(JournalRules.date(invalid) == nil, "invalid date rejected: \(invalid)")
            }
            try check(JournalRules.date("2024-02-29") != nil && JournalRules.date("2025-02-29") == nil, "leap years validated")
            let prompt = try JournalRules.prompt(job: job, existing: notes)
            try check(prompt.contains("2026-09-07T") && prompt.contains("timezone"), "ISO source timestamp and timezone sent to extractor")
            try check(prompt.contains("JOURNAL_INPUT_JSON") && JournalRules.instructions.contains("untrusted"), "conversation/instruction boundary")
            var huge = job
            huge.messages = [CodexMessage(id: "huge", role: .user, text: String(repeating: "x", count: 90_000))]
            do { _ = try JournalRules.prompt(job: huge, existing: []); throw Failure(message: "oversized prompt accepted") }
            catch JournalError.contextTooLarge { checks += 1 }
            let schema = JournalRules.schema
            try check(schema["additionalProperties"] as? Bool == false, "strict extraction schema")

            let service = JournalService(directory: directory)
            service.extract = { _, _ in [candidate] }
            await service.start()
            service.observe(thread: thread, turnID: "t1", channel: "ChatGPT", message: personal)
            service.observe(thread: thread, turnID: "t1", channel: "ChatGPT", message: personal)
            try check(service.state.jobs.first?.messages.count == 1, "started/completed echo deduplicated")
            try check(service.notes.isEmpty, "in-progress turns not extracted")
            service.finish(threadID: thread.id, turnID: "t1", succeeded: true)
            await settle { !service.working && service.pendingCount == 0 }
            try check(service.notes.count == 1, "completed turn automatically records note")
            service.observe(thread: thread, turnID: "context-next", channel: "ChatGPT")
            try check(service.state.jobs.first?.context.first?.id == personal.id, "next turn inherits bounded recent context")
            service.finish(threadID: thread.id, turnID: "context-next", succeeded: true)
            await settle { !service.working && service.pendingCount == 0 }
            service.observe(thread: thread, turnID: "t1", channel: "ChatGPT", message: personal)
            try check(service.pendingCount == 0, "completed turn cannot be replayed")
            await service.flush()
            let reopened = JournalService(directory: directory)
            reopened.extract = { _, _ in throw Failure(message: "completed turn rerun after restart") }
            await reopened.start()
            try check(reopened.notes == service.notes && reopened.pendingCount == 0, "restart preserves notes and processed ledger")
            try check(reopened.edit(id: notes[0].id, summary: "Mısır gezisi.", day: "2026-09-03"), "manual edit accepted")
            try check(!reopened.edit(id: notes[0].id, summary: "", day: nil), "empty edit rejected")
            try check(!reopened.edit(id: notes[0].id, summary: "Valid", day: "2026-02-30"), "invalid edit date rejected")
            try check(reopened.notes.first?.edited == true, "manual edit marked")
            reopened.delete(id: notes[0].id)
            try check(reopened.notes.isEmpty && reopened.state.notes.first?.deleted == true, "delete leaves dedup tombstone")
            reopened.undoDelete()
            try check(reopened.notes.count == 1, "undo deletion")
            reopened.toggleEnabled()
            reopened.observe(thread: thread, turnID: "paused", channel: "CODEX", message: personal)
            try check(reopened.pendingCount == 0 && !reopened.state.enabled, "pause prevents new captures")
            await reopened.stop()
            await service.stop()
            let saved = try await JournalRepository(directory: directory).load()
            try check(saved.notes.first?.summary == "Mısır gezisi." && !saved.enabled, "edit and pause persist atomically")
            let permissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("journal.json").path)
            try check((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o600, "journal file is owner-only")

            let pendingDir = directory.appendingPathComponent("pending")
            var pendingState = JournalState()
            var pendingJob = job; pendingJob.ready = false
            pendingState.jobs = [pendingJob]
            try await JournalRepository(directory: pendingDir).save(pendingState, revision: 1)
            let recovery = JournalService(directory: pendingDir)
            recovery.recoverTurn = { _, _ in (job.messages, true) }
            recovery.extract = { _, _ in [candidate] }
            await recovery.start()
            await settle { recovery.notes.count == 1 && recovery.pendingCount == 0 }
            try check(recovery.notes.count == 1, "pending turn recovered after restart without opening chat")
            await recovery.stop()

            let failing = JournalService(activeInMemory: true)
            failing.extract = { _, _ in throw Failure(message: "offline fixture") }
            await failing.start()
            failing.observe(thread: thread, turnID: "failure", channel: "CODEX", message: personal)
            failing.finish(threadID: thread.id, turnID: "failure", succeeded: true)
            await settle { failing.error != nil && !failing.working }
            try check(failing.pendingCount == 1 && failing.notes.isEmpty, "offline/invalid response preserves outbox")
            try check(failing.state.jobs.first?.attempts == 1 && failing.state.jobs.first!.nextAttempt > Date(), "bounded retry backoff")
            failing.extract = { _, _ in [candidate] }
            failing.retry()
            await settle { failing.notes.count == 1 }
            try check(failing.pendingCount == 0, "manual retry recovers failed extraction")
            await failing.stop()

            let staleRepo = JournalRepository(directory: nil)
            var newer = JournalState(); newer.enabled = false
            try await staleRepo.save(newer, revision: 2)
            try await staleRepo.save(JournalState(), revision: 1)
            let latest = try await staleRepo.load()
            try check(!latest.enabled, "stale asynchronous save cannot overwrite newer state")
            let corruptDir = directory.appendingPathComponent("corrupt")
            try FileManager.default.createDirectory(at: corruptDir, withIntermediateDirectories: true)
            let corruptURL = corruptDir.appendingPathComponent("journal.json")
            try Data("not-json".utf8).write(to: corruptURL)
            let corrupt = JournalService(directory: corruptDir)
            await corrupt.start()
            corrupt.toggleEnabled()
            await corrupt.flush()
            try check(corrupt.error != nil && (try? String(contentsOf: corruptURL, encoding: .utf8)) == "not-json", "corrupt storage is not overwritten")

            let cappedDir = directory.appendingPathComponent("capped")
            var cappedState = JournalState()
            cappedState.jobs = [job]; cappedState.usageDay = JournalRules.day(Date())
            cappedState.requestsToday = JournalService.dailyRequestLimit
            try await JournalRepository(directory: cappedDir).save(cappedState, revision: 1)
            let capped = JournalService(directory: cappedDir)
            var capInvocations = 0
            capped.extract = { _, _ in capInvocations += 1; return [candidate] }
            await capped.start()
            capped.pulse()
            try check(capInvocations == 0 && capped.pendingCount == 1 && !capped.working, "daily limit defers jobs without dropping them")
            await capped.stop()

            let uiService = JournalService(activeInMemory: true)
            uiService.extract = { _, _ in [candidate] }
            await uiService.start()
            uiService.observe(thread: thread, turnID: "ui", channel: "ChatGPT", message: personal)
            uiService.finish(threadID: thread.id, turnID: "ui", succeeded: true)
            await settle { uiService.notes.count == 1 }
            let store = OverlayStore(defaults: defaults, journal: uiService)
            let panels = PanelCoordinator(store: store, windowSizeDefaults: defaults)
            let router = InputRouter(store: store, coordinator: panels)
            let window = panels.journalWindow.window, nav = panels.journalWindow.navigation
            nav.selectedDate = date
            func key(_ code: UInt16, flags: NSEvent.ModifierFlags = [], repeats: Bool = false) -> NSEvent {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                                isARepeat: repeats, keyCode: code)!
            }
            try check(window.level == .normal && !window.isFloatingPanel, "calendar is an ordinary macOS window")
            try check(window.contentView is CornerResizeContainer && window.minSize.width == 360, "corner resizing and focus ring container")
            try check(AppPreferences.shortcuts.contains(where: { $0.keys == "⌘5" }), "calendar shortcut appears in settings")
            try check(router.handle(key(49)) == nil && nav.route == .day, "Space enters selected day")
            _ = router.handle(key(49))
            try check(nav.route == .note && nav.selected != nil, "Space enters note")
            var openedSource: String?
            uiService.onOpenSource = { openedSource = $0.id }
            _ = router.handle(key(49))
            try check(openedSource == thread.id, "Space opens original source chat without browser")
            _ = router.handle(key(14))
            try check(nav.editing, "E opens note editor")
            try check(router.handle(key(12)) != nil && nav.editing, "Q types normally while editing")
            try check(router.handle(key(13)) != nil, "W types normally while editing")
            _ = router.handle(key(47, flags: .command))
            try check(!nav.editing, "Cmd-period cancels edit")
            _ = router.handle(key(51))
            try check(nav.confirmingDelete && uiService.notes.count == 1, "delete asks for inline confirmation")
            _ = router.handle(key(12))
            try check(!nav.confirmingDelete && uiService.notes.count == 1, "Q cancels delete")
            _ = router.handle(key(12))
            try check(nav.route == .day, "Q note -> day")
            _ = router.handle(key(12))
            try check(nav.route == .month, "Q day -> month")
            let before = nav.day
            _ = router.handle(key(1)); _ = router.handle(key(13))
            try check(nav.day == before, "W/S day navigation")
            _ = router.handle(key(2)); _ = router.handle(key(0))
            try check(nav.day == before, "A/D month navigation")
            try check(nav.monthCells.compactMap { $0 }.count == 30, "September grid includes 30 days")
            nav.selectedDate = JournalRules.date("2024-02-29")!
            try check(nav.monthCells.compactMap { $0 }.count == 29, "leap-month calendar layout")
            try check(router.handle(key(48, flags: .command)) != nil, "calendar does not block Cmd-Tab")
            panels.appPreferences.setTransparency(100)
            try check(window.alphaValue == 1 && !window.ignoresMouseEvents, "full transparency preserves text/input")
            try check(!panels.hasVisibleWindows, "UI checks never open or activate windows")
            if let snapshotPath = ProcessInfo.processInfo.environment["BAVBAV_JOURNAL_SNAPSHOT_DIR"] {
                let output = URL(fileURLWithPath: snapshotPath, isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                panels.appPreferences.setTransparency(0)
                uiService.sourceConnected = true
                nav.selectedDate = date
                for route in [JournalRoute.month, .day, .note] {
                    nav.route = route; nav.selectedID = uiService.notes.first?.id
                    for _ in 0..<10 {
                        window.contentView?.layoutSubtreeIfNeeded()
                        try? await Task.sleep(nanoseconds: 20_000_000)
                    }
                    if let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        var headerInk = 0
                        for x in (bitmap.pixelsWide * 3 / 4)..<bitmap.pixelsWide {
                            for y in 0..<min(100, bitmap.pixelsHigh) {
                                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                                   color.greenComponent > color.redComponent * 1.5 && color.greenComponent > 0.4 { headerInk += 1 }
                            }
                        }
                        try check(headerInk > 10, "calendar route content never draws over fixed header: \(route)")
                        try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("journal-\(route).png"))
                    }
                }
            }
            await uiService.stop()

            // Verify capture sits above the active-window guards for both channels.
            let background = JournalService(activeInMemory: true)
            background.extract = { _, _ in [candidate] }
            let backgroundStore = OverlayStore(defaults: defaults, journal: background)
            await backgroundStore.connectAndLoad()
            guard let fixtureThread = backgroundStore.recentChats.first else { throw Failure(message: "fixture thread missing") }
            backgroundStore.handleServerEvent(.turnStarted(threadID: fixtureThread.id, turnID: "background"))
            backgroundStore.handleServerEvent(.itemCompleted(threadID: fixtureThread.id, turnID: "background", message: personal))
            backgroundStore.handleServerEvent(.turnCompleted(threadID: fixtureThread.id, turnID: "background", status: "completed", error: nil))
            await settle { background.notes.count == 1 }
            try check(backgroundStore.detailThread == nil && background.notes.first?.channel == "CODEX", "closed project chat still produces notes")
            await backgroundStore.shutdown()

            if !live {
                let worker = CodexAppServer(journalWorker: true)
                let parsed = try await worker.extractJournal(prompt: prompt, cwd: directory.path)
                await worker.shutdown()
                try check(parsed.count == 1, "real JSON-RPC fixture validates ephemeral/read-only/strict-schema settings")
            } else {
                let worker = CodexAppServer(journalWorker: true)
                let parsed: [JournalCandidate]
                do { parsed = try await worker.extractJournal(prompt: prompt, cwd: directory.path) }
                catch { await worker.shutdown(); throw error }
                await worker.shutdown()
                let accepted = JournalRules.accepted(parsed, job: job, existing: [])
                try check(accepted.count == 1 && accepted[0].eventDay == nil && accepted[0].kind == .event,
                          "live model extracts synthetic travel fact without inventing a date")
            }
            print("BAVBAV JOURNAL CHECK PASSED: \(checks) checks; dates/evidence/dedup, durable outbox/recovery, edits/delete/undo, keyboard/native UI, background capture; \(live ? "live ephemeral extraction" : "fake server only")")
            return true
        } catch {
            fputs("BAVBAV JOURNAL CHECK FAILED after \(checks) checks: \(error)\n", stderr)
            return false
        }
    }

    /// Explicit opt-in: synthetic messages only, no real history reads/writes.
    static func runLive() async -> Bool {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Bavbav.JournalLive.\(UUID().uuidString)", isDirectory: true)
        let worker = CodexAppServer(journalWorker: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let now = JournalRules.date("2026-09-07")!
            let thread = CodexThread(id: "synthetic-journal-check", projectID: nil, cwd: directory.path,
                                     title: "Yapay takvim testi", preview: "", updatedAt: now, state: .idle, hasMessages: true)
            var job = JournalJob(thread: thread, turnID: "synthetic", channel: "ChatGPT", capturedAt: now)
            job.messages = [
                CodexMessage(id: "travel", role: .user, text: "Geçenlerde Mısır'a gittim. Güzel bir seyahatti.", timestamp: now),
                CodexMessage(id: "decision", role: .user, text: "Bavbav projesinde web yerine yerel Swift arayüzü kullanmaya kesin karar verdim.", timestamp: now),
                CodexMessage(id: "suggestion", role: .agent, text: "İstersen veritabanını PostgreSQL'e taşıyabiliriz; bu sadece bir öneri.", timestamp: now)
            ]
            let output = try await worker.extractJournal(prompt: JournalRules.prompt(job: job, existing: []), cwd: directory.path)
            await worker.shutdown()
            let notes = JournalRules.accepted(output, job: job, existing: [])
            guard notes.contains(where: { $0.kind == .event && $0.eventDay == nil }),
                  notes.contains(where: { $0.kind == .decision }),
                  !notes.contains(where: { $0.summary.localizedCaseInsensitiveContains("PostgreSQL") }) else {
                throw Failure(message: "live extraction date/decision/proposal assertions failed: \(notes.map(\.summary))")
            }
            print("BAVBAV JOURNAL LIVE CHECK PASSED: synthetic travel + decision extracted, vague date preserved, unaccepted proposal excluded; ephemeral read-only thread, no user chat writes")
            return true
        } catch {
            await worker.shutdown()
            fputs("BAVBAV JOURNAL LIVE CHECK FAILED: \(error)\n", stderr)
            return false
        }
    }
}
