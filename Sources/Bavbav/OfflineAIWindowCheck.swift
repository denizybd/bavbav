import AppKit
import BavbavCore
import BavbavOffline

/// Real host/store/native-view paths against a local RPC server and a bounded
/// in-memory worker. It never starts the real runtime, loads a model, contacts
/// an account, uses the general clipboard, or presents a foreground window.
@MainActor
enum OfflineAIWindowCheck {
    private struct Failure: Error { let message: String }

    private actor FixtureWorker: OfflineWorker {
        private var requests: [OfflineWorkRequest] = []
        private var active = 0
        private var maximumActive = 0
        private var held = Set<String>()

        func run(request: OfflineWorkRequest,
                 progress: @escaping @Sendable (OfflineProgressReceipt) async throws -> Void) async throws -> OfflineWorkResult {
            try Task.checkCancellation()
            requests.append(request); active += 1; maximumActive = max(maximumActive, active)
            defer { active -= 1; held.remove(request.id) }
            try await progress(OfflineProgressReceipt(kind: "fixture_read", summary: "Yerel araç makbuzu kaydedildi",
                                                       details: "Sadece sentetik fixture; gerçek dosya veya model okunmadı."))
            if request.objective.contains("[HOLD]") {
                held.insert(request.id)
                while held.contains(request.id) { try await Task.sleep(nanoseconds: 20_000_000) }
            }
            try Task.checkCancellation()
            return OfflineWorkResult(summary: "Yerel fixture tamamlandı", output: "Yerel fixture sonucu: \(request.objective)")
        }

        func release() { held.removeAll() }
        func snapshot() -> (requests: [OfflineWorkRequest], active: Int, maximumActive: Int) {
            (requests, active, maximumActive)
        }
    }

    static func run() async -> Bool {
        guard ProcessInfo.processInfo.environment["BAVBAV_CODEX_BIN"]?.hasSuffix("BavbavFakeCodex") == true else {
            print("OFFLINE UI CHECK REQUIRES LOCAL FAKE SERVER"); return false
        }
        let suite = "Bavbav.OfflineUI.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let tasksURL = directory.appendingPathComponent("Tasks", isDirectory: true)
        let logURL = directory.appendingPathComponent("requests.jsonl")
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().path
        let flags = ["BAVBAV_FIXTURE_TWO_THREADS", "BAVBAV_SIDE_CHAT_CHECK", "BAVBAV_SIDE_CHAT_REQUEST_LOG"]
        let previousFlags = flags.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        setenv("BAVBAV_FIXTURE_TWO_THREADS", "1", 1)
        setenv("BAVBAV_SIDE_CHAT_CHECK", "1", 1)
        setenv("BAVBAV_SIDE_CHAT_REQUEST_LOG", logURL.path, 1)
        defaults.set(true, forKey: "offline.enabled")
        defaults.set(true, forKey: "offline.automatic")
        let initialWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let worker = FixtureWorker()
        let service = OfflineAIService(defaults: defaults, tasksURL: tasksURL, repositoryPath: sourceRoot,
                                       worker: worker, diagnostic: true)
        let preferences = AppPreferences(defaults: defaults)
        let controller = OfflineAIWindowController(service: service, preferences: preferences)
        let window = controller.window
        let store = OverlayStore(defaults: defaults, standaloneDirectory: directory.appendingPathComponent("Standalone", isDirectory: true))
        let panels = PanelCoordinator(store: store, windowSizeDefaults: defaults)
        store.onOpenDetail = { [weak panels] in panels?.completeDetailOpen(present: false) }
        store.attachOfflineAI(service)
        var assertions = 0
        var report: [String: Any] = ["success": false, "renderKind": "hidden-native-AppKit-SwiftUI-view",
            "physicalUserInteraction": false, "productionDataUsed": false, "remoteNetworkUsed": false,
            "realRuntimeStarted": false, "modelLoaded": false, "generalClipboardUsed": false,
            "closeTest": "native close action; no foreground key injection",
            "hostPID": Int(ProcessInfo.processInfo.processIdentifier)]
        defer {
            controller.shutdown()
            NSApp.windows.filter { !initialWindows.contains(ObjectIdentifier($0)) }.forEach { $0.close() }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory) // This unique fixture-owned directory only.
            for (name, value) in previousFlags {
                if let value { setenv(name, value, 1) } else { unsetenv(name) }
            }
        }
        func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
            assertions += 1
            if !value() { throw Failure(message: message) }
        }
        func waitUntil(_ condition: () -> Bool, line: UInt = #line) async throws {
            for _ in 0..<250 {
                if condition() { return }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            throw Failure(message: "timeout at \(line): \(service.error ?? store.composerError ?? service.status)")
        }
        func argument(_ name: String) -> String? {
            guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
            return CommandLine.arguments[index + 1]
        }
        func writeReport() throws {
            guard let path = argument("--offline-ui-report") else { return }
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        func requests(_ method: String) -> [[String: Any]] {
            guard let data = try? Data(contentsOf: logURL), let text = String(data: data, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap {
                guard let row = try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any],
                      row["method"] as? String == method else { return nil }
                return row
            }
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func settle() async {
            for _ in 0..<10 {
                window.contentView?.layoutSubtreeIfNeeded()
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            await service.start()
            service.setDiagnosticNetwork(offline: true)
            try check(service.enabled && service.automatic && service.runtimeReady && service.shouldAutomaticallyRoute,
                      "diagnostic offline route ready without starting the real runtime")
            try check(!window.isVisible && window.level == .normal && window.styleMask.contains(.titled)
                      && window.styleMask.contains(.resizable) && window.styleMask.contains(.closable),
                      "ordinary hidden native window, normal stacking and resize")
            try check(window.appearance?.name == .darkAqua && window.isOpaque && window.alphaValue == 1,
                      "dark zero-transparency appearance keeps the whole native window opaque")
            guard let container = window.contentView as? CornerResizeContainer else {
                throw Failure(message: "native corner-resize container missing")
            }
            let ring = descendants(container).compactMap { $0 as? WindowFocusRing }.first
            try check(ring != nil && descendants(container).filter { $0 is CornerResizeHandle }.count == 4,
                      "shared thin focus ring and four corner resize handles are present")
            try check(ring?.hitTest(.zero) == nil, "decorative focus ring cannot intercept scrolling or typing")
            await store.connectAndLoad()
            guard let first = store.recentChats.first(where: { $0.id == "fixture-thread" }),
                  let other = store.recentChats.first(where: { $0.id == "fixture-history-thread" }) else {
                throw Failure(message: "fake source catalog missing")
            }
            store.focusDetailWindow(first)
            try await waitUntil { !store.detailLoading && !store.detailActivityLoading && !store.visibleDetailItems.isEmpty }
            service.setSource(thread: first, messages: store.visibleDetailItems)
            service.objective = "İlk kaynağın yerel panel taslağı"
            service.workspacePath = directory.path
            service.setSource(thread: other, messages: [])
            try check(service.objective.isEmpty && service.sourceThreadID == other.id,
                      "opening local panel from another source never moves the previous source's draft")
            service.objective = "İkinci kaynağın yerel panel taslağı"
            service.setSource(thread: first, messages: store.visibleDetailItems)
            try check(service.objective == "İlk kaynağın yerel panel taslağı" && service.workspacePath == directory.path,
                      "returning to source restores its own panel objective and explicit workspace")
            service.setSource(thread: other, messages: [])
            try check(service.objective == "İkinci kaynağın yerel panel taslağı",
                      "each source retains an independent local panel draft")
            service.objective = ""
            service.setSource(thread: first, messages: store.visibleDetailItems)
            service.objective = ""; service.workspacePath = first.cwd
            let originalHistory = store.visibleDetailItems.map(\.id)
            let text = "Çevrimdışı yerel fixture görevi"
            store.beginWriting(from: .detail); store.composerText = text
            store.submitMessage(); store.submitMessage()
            try await waitUntil { service.jobs.count == 1 && service.jobs.first?.phase == .completed && !store.offlineSubmitting }
            guard let firstJob = service.jobs.first else { throw Failure(message: "local durable job missing") }
            let firstSnapshot = await worker.snapshot()
            try check(firstSnapshot.requests.count == 1 && firstSnapshot.maximumActive == 1,
                      "duplicate Enter creates one task and one fake worker execution")
            try check(firstJob.request.sourceThreadID == first.id && firstJob.request.workspacePath == first.cwd,
                      "source identity and workspace remain exact")
            try check(store.detailThread?.id == first.id && !store.composerVisible && store.composerText.isEmpty,
                      "accepted offline submission clears only the captured source composer")
            try check(store.visibleDetailItems.filter { $0.id.hasPrefix("offline-local-\(firstJob.id)") }.count == 2,
                      "one local user/answer pair appears through the real chat timeline")
            try check(Set(originalHistory).isSubset(of: Set(store.visibleDetailItems.map(\.id))),
                      "preexisting cloud history remains intact beside the local pair")
            try check(requests("turn/start").isEmpty && requests("turn/interrupt").isEmpty,
                      "offline route performs no cloud model or interrupt RPC")
            let stateURL = tasksURL.appendingPathComponent("tasks.json")
            let persisted = try String(contentsOf: stateURL, encoding: .utf8)
            try check(persisted.contains(firstJob.id) && persisted.contains(text), "accepted local task is durably checkpointed")
            let stateAttributes = try FileManager.default.attributesOfItem(atPath: stateURL.path)
            try check((stateAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                      "durable task snapshot is private to the user")

            // Switch synchronously while enqueue awaits its durable actor write.
            // The source draft must be consumed even though another chat is now active.
            let otherDraftDuringSubmission = "Diğer pencerede korunacak taslak"
            store.focusDetailWindow(other)
            try await waitUntil { !store.detailLoading && !store.detailActivityLoading }
            store.beginWriting(from: .detail); store.composerText = otherDraftDuringSubmission
            store.focusDetailWindow(first)
            try await waitUntil { !store.detailLoading && !store.detailActivityLoading }
            let switchedText = "Gönderirken başka pencereye geçilen yerel görev"
            let countBeforeSwitch = service.jobs.count
            let executionsBeforeSwitch = await worker.snapshot().requests.count
            store.beginWriting(from: .detail); store.composerText = switchedText
            store.submitMessage()
            store.focusDetailWindow(other) // No await before changing the active composer.
            try check(store.detailThread?.id == other.id && store.composerText == otherDraftDuringSubmission,
                      "switch during local enqueue restores the other chat's draft immediately")
            try await waitUntil {
                service.jobs.count == countBeforeSwitch + 1 && !store.offlineSubmitting
                    && service.jobs.contains { $0.request.objective == switchedText && $0.phase == .completed }
            }
            try check((defaults.string(forKey: "draft.\(first.id)") ?? "").isEmpty
                      && defaults.string(forKey: "draft.\(other.id)") == otherDraftDuringSubmission,
                      "accepted source draft is compare-and-swap cleared while the other draft stays intact")
            store.focusDetailWindow(first)
            try await waitUntil { !store.detailLoading && !store.detailActivityLoading }
            try check(store.composerText.isEmpty, "reopening accepted local source never restores an already-submitted prompt")
            let acceptedLocalJobCount = service.jobs.count
            store.beginWriting(from: .detail); store.submitMessage() // Empty Enter must not submit the old prompt again.
            await Task.yield()
            let snapshotAfterSwitch = await worker.snapshot()
            try check(service.jobs.count == acceptedLocalJobCount
                      && snapshotAfterSwitch.requests.count == executionsBeforeSwitch + 1,
                      "reopening and empty Enter create no duplicate local task or execution")

            store.beginWriting(from: .detail); store.composerText = "Bu ekli mesaj korunmalı"
            let attachment = ComposerAttachment(path: directory.appendingPathComponent("image.png").path,
                                                name: "image.png", byteCount: 0, isImage: true)
            store.addComposerAttachments([attachment], to: first.id)
            store.submitMessage()
            try check(store.composerAttachments == [attachment] && store.composerText == "Bu ekli mesaj korunmalı"
                      && store.composerError != nil && service.jobs.count == acceptedLocalJobCount,
                      "unsupported image attachment is rejected explicitly without losing draft or silently submitting")
            store.removeComposerAttachment(id: attachment.id)
            store.setComposerMode(.plan); store.submitMessage()
            try check(store.composerMode == .plan && service.jobs.count == acceptedLocalJobCount && !store.composerText.isEmpty,
                      "Plan/Goal semantics are never silently downgraded into a plain offline message")
            store.setComposerMode(.default); store.composerText = ""

            store.handleServerEvent(.turnStarted(threadID: first.id, turnID: "fixture-inflight"))
            do {
                _ = try await service.enqueue(text: "Must not race an active cloud turn", threadID: first.id, cwd: first.cwd)
                throw Failure(message: "active cloud turn was allowed to overlap local execution")
            } catch is Failure { throw Failure(message: "active cloud turn was allowed to overlap local execution") }
            catch { assertions += 1 }
            let held = try await service.enqueue(text: "Cloud outcome remains unknown", threadID: first.id,
                                                cwd: first.cwd, disposition: .outcomeUnknown, deduplicationKey: "held-cloud-receipt")
            try check(held.phase == .awaitingCloudResolution, "ambiguous cloud submission is held, not replayed")
            store.handleServerEvent(.turnCompleted(threadID: first.id, turnID: "later-unrelated-turn", status: "completed", error: nil))
            await service.refreshJobs()
            try check(service.jobs.first(where: { $0.id == held.id })?.phase == .awaitingCloudResolution,
                      "unrelated later cloud completion never resolves the held task")
            let heldSnapshot = await worker.snapshot()
            try check(heldSnapshot.requests.count == snapshotAfterSwitch.requests.count, "unknown cloud task has never entered the local worker")
            // Finish the actual tracked synthetic turn before testing composer
            // handoff; the unrelated event above must not clear its lease.
            store.handleServerEvent(.turnCompleted(threadID: first.id, turnID: "fixture-inflight", status: "interrupted", error: nil))
            try await waitUntil { service.canReadSource?(first.id) == true && !store.detailLoading && !store.detailActivityLoading }
            // Explicitly cancel this deliberately unbound monitoring task so it
            // cannot block the independent later background-work checks.
            service.selectedID = held.id; service.cancelSelected()
            try await waitUntil { service.jobs.first(where: { $0.id == held.id })?.phase == .cancelled }

            let jobsBeforeCloudIntent = service.jobs.count
            let exactIntentID = "cloud-intent-host-\(UUID().uuidString)"
            let exactTurnID = "fixture-exact-cloud-\(UUID().uuidString)"
            let intent = try await service.checkpointCloud(id: exactIntentID, text: "Exact cloud turn monitoring only",
                                                          threadID: first.id, cwd: first.cwd, messages: [])
            try check(intent == exactIntentID && service.jobs.first(where: { $0.id == exactIntentID })?.phase == .awaitingCloudResolution,
                      "cloud submission intent is durable before any model RPC")
            await service.bindCloudCheckpoint(id: intent, threadID: first.id, turnID: exactTurnID)
            service.observeCloudCompletion(threadID: first.id, turnID: "different-turn", status: "completed")
            await Task.yield(); await service.refreshJobs()
            try check(service.jobs.first(where: { $0.id == exactIntentID })?.request.sourceTurnID == exactTurnID
                      && service.jobs.first(where: { $0.id == exactIntentID })?.phase == .awaitingCloudResolution,
                      "host binds exact turn identity and refuses unrelated completion")
            service.observeCloudCompletion(threadID: first.id, turnID: exactTurnID, status: "completed")
            try await waitUntil { !service.jobs.contains { $0.id == exactIntentID } }
            let snapshotAfterCloudMonitor = await worker.snapshot()
            try check(service.jobs.count == jobsBeforeCloudIntent
                      && snapshotAfterCloudMonitor.requests.count == snapshotAfterSwitch.requests.count,
                      "exact successful cloud completion removes only its monitor without local replay")

            service.selectedID = firstJob.id
            store.beginWriting(from: .detail); store.composerText = "Mevcut kaynak taslağı korunmalı"
            service.handoffSelected()
            try await waitUntil { service.error != nil }
            try check(store.composerText == "Mevcut kaynak taslağı korunmalı"
                      && service.jobs.first(where: { $0.id == firstJob.id })?.phase == .completed,
                      "handoff refuses to overwrite an existing source draft")
            store.composerText = ""
            store.focusDetailWindow(other)
            try await waitUntil { !store.detailLoading && !store.detailActivityLoading }
            store.beginWriting(from: .detail); store.composerText = "Diğer sohbetin bağımsız taslağı"
            service.handoffSelected()
            try await waitUntil { service.jobs.first(where: { $0.id == firstJob.id })?.phase == .handedBack }
            try check(service.error == nil, "successful handoff clears the earlier actionable draft-conflict error")
            try check(store.detailThread?.id == first.id && store.composerVisible && store.composerText.contains(text),
                      "accepted handoff opens only the original source composer with its verified report")
            try check(defaults.string(forKey: "draft.\(other.id)") == "Diğer sohbetin bağımsız taslağı",
                      "handoff preserves the other chat's independent composer")
            try check(requests("turn/start").isEmpty, "handoff fills a draft only; no cloud message is auto-sent")
            store.focusDetailWindow(other)
            try check(!store.visibleDetailItems.contains { $0.id.hasPrefix("offline-local-\(firstJob.id)") },
                      "local task messages never leak into a different conversation")

            let background = try await service.enqueue(text: "[HOLD] Pencere kapansa da devam", threadID: first.id, cwd: first.cwd)
            try await waitUntil { service.jobs.first(where: { $0.id == background.id })?.phase == .running }
            try check(store.runState(for: first.id) == .working && store.runningChatCount == 1,
                      "local work marks its existing source chat working and counts one chat, not a separate agent")
            window.close()
            try await Task.sleep(nanoseconds: 80_000_000)
            await service.refreshJobs()
            try check(!window.isVisible && service.jobs.first(where: { $0.id == background.id })?.phase == .running,
                      "native window close is presentation-only and does not cancel background execution")
            await worker.release()
            try await waitUntil { service.jobs.first(where: { $0.id == background.id })?.phase == .completed }
            try check(store.runState(for: first.id) == .idle && store.runningChatCount == 0,
                      "local completion clears source activity and the chat counter without phantom work")

            let paused = try await service.enqueue(text: "[HOLD] Eklenti kapatılınca duraklat", threadID: first.id, cwd: first.cwd)
            try await waitUntil { service.jobs.first(where: { $0.id == paused.id })?.phase == .running }
            service.enabled = false
            try await waitUntil { service.jobs.first(where: { $0.id == paused.id })?.phase == .paused && !service.runtimeReady }
            for _ in 0..<100 {
                if await worker.snapshot().active == 0 { break }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            let stopped = await worker.snapshot()
            try check(stopped.active == 0 && stopped.maximumActive == 1,
                      "disabling cancels the active worker, preserves a paused record, and never overlaps models")
            service.enabled = true
            try await waitUntil { service.runtimeReady }
            try await Task.sleep(nanoseconds: 80_000_000)
            try check(service.error == nil && service.status.contains("hazır") && !service.status.contains("kapalı"),
                      "re-enabled diagnostic extension reports ready rather than retaining disabled/error UI")
            try check(service.jobs.first(where: { $0.id == paused.id })?.phase == .paused,
                      "re-enabling never automatically replays an interrupted task")
            service.selectedID = background.id
            await settle()
            ring?.setFocused(true) // Synthetic focus paint only, not OS activation.
            await settle()
            if let path = argument("--offline-render") {
                guard let view = window.contentView,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    throw Failure(message: "native offline view has no bitmap representation")
                }
                view.displayIfNeeded(); view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw Failure(message: "native offline PNG encoding failed")
                }
                try png.write(to: URL(fileURLWithPath: path), options: .atomic)
                report["renderWidth"] = bitmap.pixelsWide; report["renderHeight"] = bitmap.pixelsHigh
                report["renderBytes"] = png.count; report["focusPaint"] = "fixture-forced thin green ring; window never activated"
            }
            try check(NSApp.windows.filter { !initialWindows.contains(ObjectIdentifier($0)) }.allSatisfy { !$0.isVisible },
                      "all native views remain hidden throughout the regression")
            try check(requests("turn/start").isEmpty && requests("turn/interrupt").isEmpty,
                      "entire fixture sends no cloud turn, interrupt, API key or production payload")
            report["assertions"] = assertions; report["sourceThreadID"] = first.id
            report["localTaskCount"] = service.jobs.count; report["fakeWorkerExecutions"] = stopped.requests.count
            report["maximumParallelWorkers"] = stopped.maximumActive
            report["cloudTurnStartRPCCount"] = requests("turn/start").count
            report["heldCloudTaskExecuted"] = stopped.requests.contains { $0.id == held.id }
            report["windowVisible"] = window.isVisible; report["success"] = true
            await service.shutdown(); await store.shutdown()
            try writeReport()
            print("BAVBAV OFFLINE UI CHECK PASSED: \(assertions) checks; hidden native dark window, source/draft isolation, durable local routing, duplicate suppression, held cloud ambiguity, safe handoff, presentation-only close, pause/cancel; fake worker/server only")
            return true
        } catch {
            await worker.release()
            await service.shutdown(); await store.shutdown()
            report["assertions"] = assertions; report["error"] = String(describing: error)
            try? writeReport()
            print("BAVBAV OFFLINE UI CHECK FAILED: \(error)")
            return false
        }
    }
}
