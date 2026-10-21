import AppKit
import BavbavCore
import BavbavOffline

/// Synthetic host/provider regression. No account, peer, local model or visible window is used.
@MainActor enum SharedAccountLocalCheck {
    private struct Failure: Error { let message: String }

    private actor LocalWorker: OfflineWorker {
        private var requests: [OfflineWorkRequest] = []
        private var held = Set<String>()
        private var active = 0
        private var maximumActive = 0
        func run(request: OfflineWorkRequest,
                 progress: @escaping @Sendable (OfflineProgressReceipt) async throws -> Void) async throws -> OfflineWorkResult {
            try Task.checkCancellation()
            requests.append(request); active += 1; maximumActive = max(maximumActive, active)
            defer { active -= 1; held.remove(request.id) }
            try await progress(OfflineProgressReceipt(kind: "fixture_read", summary: "Paylaşımlı pencere yerel fixture kaydı",
                                                       details: "Sentetik işçi; gerçek model veya proje dosyası okunmadı."))
            if request.objective.contains("[HOLD]") {
                held.insert(request.id)
                while held.contains(request.id) { try await Task.sleep(nanoseconds: 10_000_000) }
            }
            try Task.checkCancellation()
            return OfflineWorkResult(summary: "Yerel fixture sonucu", output: "LOCAL_PROVIDER_RESULT: \(request.objective)")
        }
        func release() { held.removeAll() }
        func snapshot() -> (requests: [OfflineWorkRequest], active: Int, maximum: Int) { (requests, active, maximumActive) }
    }

    private final class Wire {
        var paired = false
        var role = "deniz"
        var events: [[String: Any]] = []
        var calls: [(method: String, arguments: [String: Any])] = []
        func call(_ method: String, _ arguments: [String: Any]) async throws -> [String: Any] {
            calls.append((method, arguments))
            switch method {
            case "accountState": return paired ? ["role": role] : [:]
            case "accountHeartbeat": return ["localReady": paired, "peerAvailable": paired, "cancellations": []]
            case "accountPoll":
                let result = events; events.removeAll()
                return ["cursor": calls.count, "events": result]
            case "accountTake": return [:] // No synthetic owner ever takes/spends a request.
            case "accountSend":
                let id = arguments["id"] as? String ?? "missing"
                let text = arguments["text"] as? String ?? ""
                if !text.contains("ACCOUNT_HOLD") {
                    events.append(["id": id, "phase": "completed", "text": "VISIBLE_CLOUD_REPLY: " + (arguments["owner"] as? String ?? "unknown")])
                }
                return ["accepted": true]
            case "accountCancel": return [:]
            default: return [:]
            }
        }
        func count(_ method: String) -> Int { calls.filter { $0.method == method }.count }
        func complete(_ id: String) { events.append(["id": id, "phase": "interrupted", "text": "Synthetic cloud request finished."]) }
    }

    static func run() async -> Bool {
        guard ProcessInfo.processInfo.environment["BAVBAV_CODEX_BIN"]?.hasSuffix("BavbavFakeCodex") == true else {
            print("SHARED LOCAL CHECK REQUIRES LOCAL FAKE SERVER"); return false
        }
        let suite = "Bavbav.SharedLocal.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let workspace = directory.appendingPathComponent("Workspace", isDirectory: true)
        let tasks = directory.appendingPathComponent("Tasks", isDirectory: true)
        let logURL = directory.appendingPathComponent("fake-codex.jsonl")
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        let flags = ["BAVBAV_COMPANION_CHECK", "BAVBAV_SIDE_CHAT_CHECK", "BAVBAV_SIDE_CHAT_REQUEST_LOG"]
        let previousFlags = flags.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        setenv("BAVBAV_COMPANION_CHECK", "1", 1)
        setenv("BAVBAV_SIDE_CHAT_CHECK", "1", 1)
        setenv("BAVBAV_SIDE_CHAT_REQUEST_LOG", logURL.path, 1)
        defaults.set(true, forKey: "offline.enabled")
        defaults.set(true, forKey: "offline.automatic")
        let initialWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let worker = LocalWorker(), wire = Wire()
        let offline = OfflineAIService(defaults: defaults, tasksURL: tasks, repositoryPath: sourceRoot, worker: worker, diagnostic: true)
        let chat = SharedAccountChat(defaults: defaults, offlineAI: offline, localWorkspace: workspace) { method, args in
            try await wire.call(method, args)
        }
        let controller = SharedAccountWindow(service: chat)
        var restored: SharedAccountChat?
        var assertions = 0
        var report: [String: Any] = ["success": false, "productionDataUsed": false, "realRuntimeStarted": false,
            "modelLoaded": false, "physicalUserInteraction": false, "remoteNetworkUsed": false,
            "generalClipboardUsed": false, "hostPID": Int(ProcessInfo.processInfo.processIdentifier)]
        defer {
            controller.shutdown()
            NSApp.windows.filter { !initialWindows.contains(ObjectIdentifier($0)) }.forEach { $0.orderOut(nil); $0.close() }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory) // This UUID fixture directory only.
            for (key, value) in previousFlags {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        func check(_ condition: @autoclosure () -> Bool, _ detail: String) throws {
            assertions += 1
            guard condition() else { throw Failure(message: detail) }
        }
        func wait(_ label: String, _ condition: () -> Bool) async throws {
            for _ in 0..<350 {
                if condition() { return }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            throw Failure(message: "\(label): \(chat.error ?? offline.error ?? offline.status)")
        }
        func idleWorker() async throws {
            for _ in 0..<250 {
                if await worker.snapshot().active == 0 { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw Failure(message: "Synthetic local worker did not stop")
        }
        func cloudMethods() -> [String] {
            guard let data = try? Data(contentsOf: logURL), let text = String(data: data, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["method"] as? String
            }
        }
        func argument(_ name: String) -> String? {
            guard let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(index + 1) else { return nil }
            return CommandLine.arguments[index + 1]
        }
        func writeReport() {
            guard let path = argument("--shared-local-report"), let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else { return }
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        func postLocal(_ text: String) async throws -> OfflineTaskRecord {
            let before = offline.jobs.count
            chat.draft = text; chat.send(); chat.send()
            try await wait("accepted local provider task") { offline.jobs.count == before + 1 && !chat.selectedSubmitting }
            guard let record = offline.jobs.first(where: { $0.request.objective == text }) else { throw Failure(message: "Accepted local provider task missing") }
            return record
        }
        func seedCloud(_ owner: String, text: String) async throws {
            chat.selectProvider(owner); chat.draft = text; chat.send()
            try await wait("synthetic cloud acknowledgement") { !chat.submitting && chat.draft.isEmpty }
            try await chat.tick()
            try await wait("synthetic cloud visible response") { chat.activeID == nil && chat.visibleMessages.last?.phase == "completed" }
        }
        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            await offline.start(); offline.setDiagnosticNetwork(offline: true)
            chat.selectProvider("local")
            try? await chat.tick() // An unpaired Workspace must not disable the independent local provider.
            try check(chat.role == nil && chat.owner == "local" && chat.selectedReady,
                      "unpaired, offline device can explicitly select the independent local provider")
            try check(offline.modelID == OfflinePlugin.modelID && offline.modelID == "huihui_ai/qwen3-abliterated:14b-v2",
                      "shared local provider uses the exact current model identity and shared OfflineAIService")
            let first = try await postLocal("UNPAIRED_LOCAL_ONLY")
            try await wait("unpaired local completion") { offline.jobs.first(where: { $0.id == first.id })?.phase == .completed }
            let firstSnapshot = await worker.snapshot()
            try check(firstSnapshot.requests.count == 1 && first.request.sourceThreadID == chat.localSourceID
                      && first.request.workspacePath == workspace.path,
                      "double Enter creates one durable request in the same local queue and explicit workspace")
            try check(chat.visibleMessages.filter { $0.requestID == first.id }.count == 2,
                      "local timeline presents one user/result pair without duplicate submission")
            try check(wire.count("accountSend") == 0 && wire.count("accountCancel") == 0
                      && !cloudMethods().contains("turn/start") && !cloudMethods().contains("turn/interrupt"),
                      "unpaired local request never sends, cancels or starts any account/cloud turn")
            let durable = try String(contentsOf: tasks.appendingPathComponent("tasks.json"), encoding: .utf8)
            try check(durable.contains(first.id) && durable.contains("UNPAIRED_LOCAL_ONLY"), "provider result is stored in the durable offline ledger")
            let reloaded = SharedAccountChat(defaults: defaults, offlineAI: offline, localWorkspace: workspace) { method, args in try await wire.call(method, args) }
            restored = reloaded; reloaded.selectProvider("local")
            try check(reloaded.localSourceID == chat.localSourceID && reloaded.visibleMessages.contains { $0.requestID == first.id },
                      "a new window service restores the same local conversation and persisted result")

            wire.paired = true
            try await chat.tick()
            let sampleKey = "sk-" + String(repeating: "f", count: 900)
            let sampleBearer = "Bearer " + String(repeating: "b", count: 900)
            try await seedCloud("deniz", text: String(repeating: "eski görünür bağlam ", count: 240) + " " + sampleKey + " DENIZ_VISIBLE_CONTEXT")
            let protectedDenizDraft = "DENIZ_UNSENT_DRAFT_MUST_NOT_ENTER_CONTEXT"
            chat.draft = protectedDenizDraft
            chat.selectProvider("local")
            try check(chat.localContextOrigin?.contains("Deniz") == true && chat.draft.isEmpty,
                      "explicit Deniz-to-local selection captures visible context but does not move the cloud draft")
            let sendsBeforeDenizLocal = wire.count("accountSend"), cancelsBeforeDenizLocal = wire.count("accountCancel")
            let denizLocal = try await postLocal("LOCAL_TASK_FROM_DENIZ")
            try await wait("Deniz-context local completion") { offline.jobs.first(where: { $0.id == denizLocal.id })?.phase == .completed }
            let denizContext = denizLocal.request.context.map(\.text).joined(separator: "\n")
            try check(denizContext.contains("DENIZ_VISIBLE_CONTEXT") && !denizContext.contains(sampleKey)
                      && !denizContext.contains(String(repeating: "f", count: 40))
                      && !denizContext.contains(protectedDenizDraft) && denizLocal.request.context.reduce(0, { $0 + $1.text.count }) <= 1_500,
                      "Deniz context is bounded, visible-text-only and redacted before durable local submission")
            try check(wire.count("accountSend") == sendsBeforeDenizLocal && wire.count("accountCancel") == cancelsBeforeDenizLocal,
                      "Deniz-context local continuation consumes no account quota or cancellation RPC")
            try await seedCloud("emir", text: "EMIR_VISIBLE_CONTEXT " + sampleBearer)
            chat.selectProvider("local")
            try check(chat.localContextOrigin?.contains("Emir") == true, "Emir-to-local context origin is explicit, not inferred from billing owner")
            let sendsBeforeEmirLocal = wire.count("accountSend"), cancelsBeforeEmirLocal = wire.count("accountCancel")
            let emirLocal = try await postLocal("LOCAL_TASK_FROM_EMIR")
            try await wait("Emir-context local completion") { offline.jobs.first(where: { $0.id == emirLocal.id })?.phase == .completed }
            let emirContext = emirLocal.request.context.map(\.text).joined(separator: "\n")
            try check(emirContext.contains("EMIR_VISIBLE_CONTEXT") && !emirContext.contains("DENIZ_VISIBLE_CONTEXT")
                      && !emirContext.contains(String(repeating: "b", count: 40))
                      && !emirContext.contains(sampleBearer) && emirLocal.request.context.reduce(0, { $0 + $1.text.count }) <= 1_500,
                      "Emir visible context stays isolated and redacted instead of mixing account histories")
            try check(wire.count("accountSend") == sendsBeforeEmirLocal && wire.count("accountCancel") == cancelsBeforeEmirLocal,
                      "Emir-context local continuation also performs no account send/cancel RPC")

            chat.handoffLocalResult(to: "deniz", taskID: emirLocal.id)
            try await wait("protected handoff refusal") { chat.error != nil }
            chat.selectProvider("deniz")
            try check(chat.draft == protectedDenizDraft, "handoff never overwrites the explicit target's existing draft")
            chat.selectProvider("local")
            let sendsBeforeHandoff = wire.count("accountSend")
            chat.handoffLocalResult(to: "emir", taskID: emirLocal.id)
            try await wait("explicit Emir handoff draft") { chat.owner == "emir" && chat.draft.contains("LOCAL_PROVIDER_RESULT") }
            try check(chat.draft.contains(emirLocal.id) && wire.count("accountSend") == sendsBeforeHandoff,
                      "handoff fills only the explicitly selected empty account draft and never sends automatically")
            chat.selectProvider("deniz")
            try check(chat.draft == protectedDenizDraft, "explicit Emir handoff leaves the other account's draft untouched")

            // A held cloud receipt and an independent offline-panel job coexist;
            // stopping this provider's queued request must touch neither one.
            chat.selectProvider("emir"); chat.draft = "ACCOUNT_HOLD"; chat.send()
            try await wait("held synthetic cloud request") { !chat.submitting && chat.activeID != nil }
            guard let heldCloudID = chat.activeID else { throw Failure(message: "Synthetic held cloud request missing") }
            let panelJob = try await offline.enqueue(text: "[HOLD] Independent local panel job", threadID: "shared-local-check-independent", cwd: workspace.path)
            try await wait("independent shared queue running") { offline.jobs.first(where: { $0.id == panelJob.id })?.phase == .running }
            chat.selectProvider("local")
            let cancelsBeforeStop = wire.count("accountCancel"), sendsBeforeStop = wire.count("accountSend")
            let queued = try await postLocal("[HOLD] Provider queued request")
            try check(offline.jobs.first(where: { $0.id == queued.id })?.phase == .queued,
                      "provider shares the existing single-worker queue rather than spawning another model")
            chat.cancel()
            try await wait("queued provider-only cancellation") { offline.jobs.first(where: { $0.id == queued.id })?.phase == .cancelled }
            try check(offline.jobs.first(where: { $0.id == panelJob.id })?.phase == .running && chat.activeID == heldCloudID
                      && wire.count("accountCancel") == cancelsBeforeStop && wire.count("accountSend") == sendsBeforeStop,
                      "local Stop touches only the provider job, not an independent local job or held cloud request")
            await worker.release()
            try await wait("independent panel completion") { offline.jobs.first(where: { $0.id == panelJob.id })?.phase == .completed }
            let activeLocal = try await postLocal("[HOLD] Provider active request")
            try await wait("provider worker running") { offline.jobs.first(where: { $0.id == activeLocal.id })?.phase == .running }
            chat.cancel()
            try await wait("running provider-only cancellation") { offline.jobs.first(where: { $0.id == activeLocal.id })?.phase == .cancelled }
            try await idleWorker()
            try check(chat.activeID == heldCloudID && wire.count("accountCancel") == cancelsBeforeStop,
                      "running local cancellation also leaves the unrelated cloud request intact")
            wire.complete(heldCloudID); try await chat.tick()

            let background = try await postLocal("[HOLD] Closed shared window keeps local work")
            try await wait("local background request running") { offline.jobs.first(where: { $0.id == background.id })?.phase == .running }
            try await wait("local running timeline projection") {
                chat.visibleMessages.first(where: { $0.id == background.id })?.phase == "running"
                    && chat.visibleMessages.first(where: { $0.id == background.id })?.text.contains("Paylaşımlı pencere yerel fixture kaydı") == true
            }
            let heldLocalText = chat.visibleMessages.first(where: { $0.id == background.id })?.text
            wire.events.append(["id": background.id, "phase": "completed", "text": "PEER_FRAME_MUST_NOT_MUTATE_LOCAL"])
            try await chat.tick()
            await Task.yield()
            try check(offline.jobs.first(where: { $0.id == background.id })?.phase == .running
                      && chat.visibleMessages.first(where: { $0.id == background.id })?.phase == "running"
                      && chat.visibleMessages.first(where: { $0.id == background.id })?.text == heldLocalText
                      && chat.selectedActiveID == background.id,
                      "peer/account poll frames cannot overwrite a running local message even with its exact request ID")
            let window = controller.prepare()
            try check(!window.isVisible && window.level == .normal && window.styleMask.contains(.resizable), "provider UI prepares as an ordinary hidden native window")
            window.close()
            try await Task.sleep(nanoseconds: 60_000_000)
            try check(offline.jobs.first(where: { $0.id == background.id })?.phase == .running,
                      "closing the shared-account window is presentation-only and does not cancel local work")
            await worker.release()
            try await wait("closed-window local completion") { offline.jobs.first(where: { $0.id == background.id })?.phase == .completed }
            var quickIDs: [String] = []
            for index in 0..<10 {
                let quick = try await offline.enqueue(text: "QUEUE_RETIREMENT_STRESS_\(index)", threadID: chat.localSourceID, cwd: workspace.path)
                quickIDs.append(quick.id)
                await Task.yield() // Interleave producer enqueues with queue drain/retirement.
            }
            let quickSet = Set(quickIDs)
            try await wait("ten quick tasks survive queue drain and retirement") {
                offline.jobs.filter { quickSet.contains($0.id) && $0.phase == .completed }.count == quickIDs.count
            }
            let quickSnapshot = await worker.snapshot()
            try check(quickIDs.count == 10 && Set(quickSnapshot.requests.filter { quickSet.contains($0.id) }.map(\.id)) == quickSet
                      && quickSnapshot.requests.filter { quickSet.contains($0.id) }.count == quickIDs.count
                      && quickSnapshot.maximum == 1,
                      "ten rapid queue enqueues all complete exactly once without a lost wakeup or parallel worker")
            offline.enabled = false
            try await wait("disabled local provider") { !offline.runtimeReady }
            chat.selectProvider("local"); chat.draft = "DISABLED_LOCAL_DRAFT_PRESERVED"
            let countBeforeUnavailable = offline.jobs.count, sendsBeforeUnavailable = wire.count("accountSend")
            chat.send(); await Task.yield()
            try check(chat.draft == "DISABLED_LOCAL_DRAFT_PRESERVED" && offline.jobs.count == countBeforeUnavailable
                      && wire.count("accountSend") == sendsBeforeUnavailable,
                      "unavailable local provider preserves the draft and never falls back to an account")
            let endSnapshot = await worker.snapshot()
            try check(endSnapshot.maximum == 1 && endSnapshot.requests.allSatisfy { $0.sourceThreadID == chat.localSourceID || $0.id == panelJob.id },
                      "all local provider work uses one shared worker with exact stable conversation identity")
            let forbiddenMethods = cloudMethods().filter { ["turn/start", "turn/interrupt", "thread/start", "thread/fork"].contains($0) }
            try check(forbiddenMethods.isEmpty, "no local-provider case started or interrupted any Codex cloud thread/turn")
            try check(NSApp.windows.filter { !initialWindows.contains(ObjectIdentifier($0)) }.allSatisfy { !$0.isVisible },
                      "native provider views remain hidden for the complete fixture")
            if let path = argument("--shared-local-render"), let view = window.contentView {
                view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure(message: "Shared local view cannot render") }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure(message: "Shared local PNG encoding failed") }
                try png.write(to: URL(fileURLWithPath: path), options: .atomic)
                report["renderWidth"] = bitmap.pixelsWide; report["renderHeight"] = bitmap.pixelsHigh
            }
            report["assertions"] = assertions; report["localJobs"] = offline.jobs.count
            report["maximumParallelWorkers"] = endSnapshot.maximum; report["model"] = offline.modelID
            report["accountSendRPCs"] = wire.count("accountSend"); report["accountSendPurpose"] = "synthetic visible-context seeds and held cloud control only; zero local-request increments"
            report["accountCancelRPCs"] = wire.count("accountCancel"); report["cloudTurnRPCs"] = forbiddenMethods.count
            report["success"] = true
            await restored?.shutdown(); await chat.shutdown(); await offline.shutdown()
            writeReport()
            print("BAVBAV SHARED LOCAL CHECK PASSED: \(assertions) hidden host checks; unpaired local selection, exact pinned service/queue, durable timeline, redacted Deniz/Emir context, local-only stop, explicit no-autosend handoff; fake worker/server only")
            return true
        } catch {
            await worker.release(); await restored?.shutdown(); await chat.shutdown(); await offline.shutdown()
            report["assertions"] = assertions; report["error"] = String(describing: error); writeReport()
            print("BAVBAV SHARED LOCAL CHECK FAILED: \(error)")
            return false
        }
    }
}
