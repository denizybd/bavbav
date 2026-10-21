import AppKit
import BavbavCore
import BavbavOffline
import Combine
import Foundation
import Network

extension Notification.Name {
    static let bavbavOpenOfflineAI = Notification.Name("Bavbav.OpenOfflineAI")
}

/// Host adapter for the independently testable BavbavOffline plugin. It never
/// changes Codex auth/configuration or treats a transport failure as permission
/// to replay a possibly accepted cloud action.
@MainActor
final class OfflineAIService: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "offline.enabled")
            if enabled != oldValue { enabledDidChange() }
        }
    }
    @Published var automatic: Bool { didSet { defaults.set(automatic, forKey: "offline.automatic") } }
    @Published var objective = ""
    @Published var workspacePath = ""
    @Published private(set) var sourceThreadID = "standalone-local"
    @Published private(set) var sourceTitle = "Yerel görev"
    @Published private(set) var jobs: [OfflineTaskRecord] = []
    @Published var selectedID: String?
    @Published private(set) var status = "Yerel eklenti hazırlanıyor"
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    @Published private(set) var runtimeReady = false
    @Published private(set) var networkOffline = false
    @Published private(set) var networkKnown = false
    @Published private(set) var repositoryPath: String
    let modelID = OfflinePlugin.modelID
    let version = OfflinePlugin.version
    var onChange: (() -> Void)?
    var onHandoff: ((OfflineTaskRecord, String) -> Bool)?
    var canReadSource: ((String) -> Bool)?
    var readCloudStatus: ((String, String) async -> String?)?
    private struct CloudTurnKey: Hashable { let threadID: String; let turnID: String }
    private var recentCloudCompletions: [CloudTurnKey: Bool] = [:]
    private var cloudReconciliationRunning = false
    private let defaults: UserDefaults
    private let tasksURL: URL
    private let injectedWorker: (any OfflineWorker)?
    private var coordinator: OfflineCoordinator?
    private var runTask: Task<Void, Never>?
    private var queueWakeRequested = false
    private var setupTask: Task<Void, Never>?
    private var lifecycleTask: Task<Void, Never>?
    private var submissionInFlight = false
    private var monitor: NWPathMonitor?
    private var context: [OfflineContextMessage] = []
    private var panelDrafts: [String: (text: String, workspace: String)] = [:]
    private var stopping = false
    private let diagnostic: Bool

    init(defaults: UserDefaults = .standard, tasksURL: URL? = nil,
         repositoryPath: String? = nil, worker: (any OfflineWorker)? = nil, diagnostic: Bool = false) {
        self.defaults = defaults
        enabled = defaults.object(forKey: "offline.enabled") == nil ? true : defaults.bool(forKey: "offline.enabled")
        automatic = defaults.object(forKey: "offline.automatic") == nil ? true : defaults.bool(forKey: "offline.automatic")
        self.tasksURL = tasksURL ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Bavbav/OfflineAI/Tasks")
        self.repositoryPath = repositoryPath ?? Self.discoverRepository(defaults: defaults)
        self.injectedWorker = worker
        self.diagnostic = diagnostic
    }

    var selected: OfflineTaskRecord? { jobs.first { $0.id == selectedID } }
    var shouldAutomaticallyRoute: Bool { enabled && automatic && networkKnown && networkOffline && coordinator != nil && !stopping && lifecycleTask == nil }
    var connectivity: String { networkKnown ? (networkOffline ? "Ağ bağlantısı yok" : "Ağ mevcut · bulut ayrıca doğrulanır") : "Ağ durumu belirleniyor" }

    func start() async {
        guard coordinator == nil, !stopping else { return }
        do {
            let repository = try OfflineRepository(rootURL: tasksURL)
            let worker: any OfflineWorker
            if let injectedWorker { worker = injectedWorker } else { worker = try OllamaOfflineWorker() }
            coordinator = try OfflineCoordinator(repository: repository, worker: worker)
            await refreshJobs()
            await reconcilePersistedCloud()
            guard !stopping else { return }
            status = "Yerel eklenti hazır · model henüz yüklenmedi"
            if !diagnostic {
                let path = NWPathMonitor()
                path.pathUpdateHandler = { [weak self] result in
                    Task { @MainActor in
                        self?.networkKnown = true
                        self?.networkOffline = result.status == .unsatisfied
                    }
                }
                path.start(queue: DispatchQueue(label: "bavbav.offline.network", qos: .utility))
                monitor = path
                if enabled { prepareRuntime() }
            } else { runtimeReady = true }
        } catch { fail(error) }
    }

    func setSource(thread: CodexThread?, messages: [CodexMessage]) {
        let nextID = thread?.id ?? "standalone-local"
        if nextID != sourceThreadID {
            panelDrafts[sourceThreadID] = (objective, workspacePath)
            objective = panelDrafts[nextID]?.text ?? ""
            workspacePath = panelDrafts[nextID]?.workspace ?? thread?.cwd ?? repositoryPath
        } else if workspacePath.isEmpty { workspacePath = thread?.cwd ?? repositoryPath }
        sourceThreadID = nextID
        sourceTitle = thread?.title ?? "Yerel görev"
        // A bounded, visible-text checkpoint; no hidden reasoning, command
        // environment, credentials or full historical transcript is copied.
        context = Self.checkpoint(messages)
    }

    private static func checkpoint(_ messages: [CodexMessage]) -> [OfflineContextMessage] {
        var remaining = 1_500
        return Array(messages.filter { $0.kind.isConversation }.suffix(6).reversed().compactMap { message in
            guard remaining > 0 else { return nil }
            let text = String(Self.redacted(message.text).suffix(min(remaining, 1_000)))
            remaining -= text.count
            return OfflineContextMessage(role: message.role == .user ? "user" : "assistant", text: text)
        }.reversed())
    }

    nonisolated static func redacted(_ text: String) -> String {
        var value = text
        for expression in [#"sk-[A-Za-z0-9_-]{16,}"#, #"(?i)Bearer\s+[A-Za-z0-9._~-]{16,}"#,
                           #"(?s)-----BEGIN [A-Z ]*PRIVATE KEY-----.*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)"#] {
            value = value.replacingOccurrences(of: expression, with: "[GİZLİ DEĞER ÇIKARILDI]", options: .regularExpression)
        }
        return value
    }

    @discardableResult
    func enqueue(text: String, threadID: String, cwd: String, messages: [CodexMessage] = [],
                 disposition: OfflineCloudDisposition = .notSubmitted, deduplicationKey: String? = nil,
                 capturedContext: [OfflineContextMessage]? = nil, requestID: String? = nil) async throws -> OfflineTaskRecord {
        guard enabled, let coordinator, !stopping else { throw OfflineHostError.message("Yerel eklenti etkin veya hazır değil.") }
        if disposition != .outcomeUnknown, jobs.contains(where: {
            $0.request.sourceThreadID == threadID && $0.phase == .awaitingCloudResolution
        }) { throw OfflineHostError.message("Bu mesajın bulutta kabul edilip edilmediği belirsiz. Otomatik tekrar çalıştırılmadı.") }
        if disposition != .outcomeUnknown, canReadSource?(threadID) == false {
            throw OfflineHostError.message("Kaynak sohbet hâlâ çalışıyor. Yerel devir için turun tamamlanmasını bekle.")
        }
        guard text.utf8.count <= 6_000 else { throw OfflineHostError.message("Yerel görev en fazla 6.000 UTF-8 baytı olabilir. Mesajın taslakta korundu.") }
        let request = OfflineWorkRequest(id: requestID ?? UUID().uuidString, deduplicationKey: deduplicationKey ?? UUID().uuidString,
            sourceThreadID: threadID, workspacePath: cwd, objective: Self.redacted(text),
            context: capturedContext ?? Self.checkpoint(messages), cloudDisposition: disposition,
            limits: OfflineLimits(maxContextCharacters: 20_000, maxSteps: 8, maxDurationSeconds: 180))
        let record = try await coordinator.enqueue(request)
        error = nil
        if disposition != .outcomeUnknown { selectedID = record.id }
        await refreshJobs()
        if disposition != .outcomeUnknown { processQueue() }
        return record
    }

    func submitDraft() {
        let text = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !submissionInFlight, !stopping, enabled else { return }
        submissionInFlight = true
        let source = sourceThreadID, cwd = workspacePath, captured = context
        Task {
            defer { submissionInFlight = false }
            do {
                _ = try await enqueue(text: text, threadID: source, cwd: cwd, capturedContext: captured)
                if let saved = panelDrafts[source], saved.workspace == cwd,
                   saved.text.trimmingCharacters(in: .whitespacesAndNewlines) == text {
                    panelDrafts[source] = ("", cwd)
                }
                if sourceThreadID == source, workspacePath == cwd,
                   objective.trimmingCharacters(in: .whitespacesAndNewlines) == text { objective = "" }
            } catch { fail(error) }
        }
    }

    func prepareRuntime() {
        guard !diagnostic, enabled, setupTask == nil, runTask == nil, lifecycleTask == nil, !stopping else { return }
        let root = repositoryPath
        setupTask = Task {
            busy = true; error = nil; status = "Repo içi model ve çalıştırıcı doğrulanıyor…"
            defer { busy = false; setupTask = nil }
            do {
                guard Self.isRepository(root) else { throw OfflineHostError.message("Bavbav kaynak klasörü bulunamadı. Repo klasörünü seç.") }
                _ = try await OfflineRuntimeCommand.run(root: root, action: ["setup", "--allow-download"], timeout: 900)
                try Task.checkCancellation()
                _ = try await OfflineRuntimeCommand.run(root: root, action: ["start"], timeout: 90)
                try Task.checkCancellation()
                guard !stopping, enabled, repositoryPath == root else { return }
                runtimeReady = true
                status = "Qwen3 14B hazır · yalnızca bu repo · 127.0.0.1:11439"
                processQueue()
            } catch {
                runtimeReady = false
                if !Task.isCancelled && !stopping { fail(error) }
            }
        }
    }

    func chooseRepository() {
        guard runTask == nil, setupTask == nil, lifecycleTask == nil, !submissionInFlight, !stopping else {
            fail(OfflineHostError.message("Repo değiştirmek için etkin yerel işin veya kurulumun durmasını bekle."))
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "Model ve çalıştırıcının tutulacağı Bavbav kaynak reposunu seç."
        guard panel.runModal() == .OK, let path = panel.url?.path, Self.isRepository(path) else { return }
        // A modal panel can process other events. Recheck after it closes.
        guard runTask == nil, setupTask == nil, lifecycleTask == nil, !submissionInFlight, !stopping else {
            fail(OfflineHostError.message("Yerel çalışma başladı; repo değiştirilmedi."))
            return
        }
        guard path != repositoryPath else { return }
        let previousRoot = repositoryPath
        lifecycleTask = Task {
            busy = true
            defer { busy = false; lifecycleTask = nil }
            do {
                if !diagnostic, Self.isRepository(previousRoot) {
                    _ = try await OfflineRuntimeCommand.run(root: previousRoot, action: ["stop"], timeout: 20)
                }
                guard !stopping else { return }
                repositoryPath = path; defaults.set(path, forKey: "offline.repository-path")
                runtimeReady = diagnostic
            } catch { fail(error); return }
            // prepareRuntime must run after lifecycleTask releases its guard.
            Task { [weak self] in
                await Task.yield()
                guard let self, self.enabled, !self.stopping else { return }
                self.prepareRuntime()
            }
        }
    }

    func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "Yerel ajanın yalnızca okuyabileceği çalışma klasörünü seç."
        if panel.runModal() == .OK, let url = panel.url { workspacePath = url.path }
    }

    private func processQueue() {
        guard lifecycleTask == nil, !stopping, enabled, let coordinator else { return }
        // An enqueue can land while runNext() is returning nil but before the
        // old drain clears runTask. Remember that wakeup instead of stranding
        // the newly persisted job until an unrelated later submission.
        queueWakeRequested = true
        guard runTask == nil else { return }
        guard runtimeReady else { prepareRuntime(); return }
        queueWakeRequested = false
        runTask = Task {
            defer {
                runTask = nil; onChange?()
                if queueWakeRequested { processQueue() }
            }
            while !Task.isCancelled && !stopping && enabled {
                // Independent UI refreshes don't reconstruct native chat views.
                let progress = Task {
                    while !Task.isCancelled {
                        await refreshJobs()
                        try? await Task.sleep(nanoseconds: 600_000_000)
                    }
                }
                do {
                    let result = try await coordinator.runNext()
                    progress.cancel(); await refreshJobs()
                    guard let result else { break }
                    status = result.phase == .completed ? "Yerel sonuç hazır · buluta henüz gönderilmedi" : "Yerel görev: \(result.phase.rawValue)"
                } catch { progress.cancel(); await refreshJobs(); fail(error); break }
            }
        }
    }

    func prepareTaskHandoff(id: String) async throws -> OfflineHandoffReport {
        guard let coordinator else { throw OfflineHostError.message("Yerel görev kaydı hazır değil.") }
        let report = try await coordinator.prepareHandoff(id: id)
        await refreshJobs()
        return report
    }

    func acceptTaskHandoff(id: String, reportID: String) async throws {
        guard let coordinator else { throw OfflineHostError.message("Yerel görev kaydı hazır değil.") }
        _ = try await coordinator.acceptHandoff(id: id, reportID: reportID)
        error = nil
        await refreshJobs()
    }

    func cancelTask(id: String) async throws {
        guard let coordinator else { throw OfflineHostError.message("Yerel görev kaydı hazır değil.") }
        _ = try await coordinator.cancel(id: id)
        error = nil
        await refreshJobs()
    }

    func resumeSelected() {
        guard let id = selectedID, let coordinator else { return }
        Task { do { try await coordinator.resume(id: id); error = nil; await refreshJobs(); processQueue() } catch { fail(error) } }
    }
    func cancelSelected() {
        guard let id = selectedID, let coordinator else { return }
        Task { do { try await coordinator.cancel(id: id); error = nil; await refreshJobs() } catch { fail(error) } }
    }
    func handoffSelected() {
        guard let id = selectedID, let coordinator else { return }
        Task {
            do {
                let report = try await coordinator.prepareHandoff(id: id)
                guard let record = await coordinator.task(id: id), onHandoff?(record, report.text) == true else {
                    throw OfflineHostError.message("Kaynak sohbette boş bir yazma alanı gerekli. Mevcut taslağın değiştirilmedi.")
                }
                _ = try await coordinator.acceptHandoff(id: id, reportID: report.id)
                error = nil
                await refreshJobs()
                status = "Rapor kaynak sohbetin yazma alanında · göndermek için Enter"
            } catch { fail(error) }
        }
    }
    /// Persist intent before contacting the cloud. A crash or missing RPC reply
    /// leaves it held, not an invitation to repeat side effects locally.
    func checkpointCloud(id: String, text: String, threadID: String, cwd: String, messages: [CodexMessage]) async throws -> String? {
        guard enabled else { return nil }
        // Do not change the meaning of a cloud objective by truncating it.
        // Oversized work is simply ineligible for automatic local continuation.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 6_000 else { return nil }
        if coordinator == nil { await start() }
        let record = try await enqueue(text: text, threadID: threadID, cwd: cwd, messages: messages,
                                      disposition: .outcomeUnknown, deduplicationKey: id, requestID: id)
        // The ID prefix is the coordinator's explicit monitoring-record policy.
        return record.id
    }

    func retargetCloudCheckpoint(id: String?, threadID: String, cwd: String) async throws {
        guard let id else { return }
        guard let coordinator else { throw OfflineHostError.message("Yerel görev kaydı hazır değil; bulut isteği tekrarlanmadı.") }
        _ = try await coordinator.retargetUnboundCloudIntent(id: id, sourceThreadID: threadID, workspacePath: cwd)
        await refreshJobs()
    }

    func bindCloudCheckpoint(id: String?, threadID: String, turnID: String) async {
        guard let id, let coordinator else { return }
        do {
            _ = try await coordinator.bindCloudTurn(id: id, sourceThreadID: threadID, turnID: turnID)
            if let succeeded = recentCloudCompletions[CloudTurnKey(threadID: threadID, turnID: turnID)] {
                await reconcileExactCloud(threadID: threadID, turnID: turnID, succeeded: succeeded)
            }
            await refreshJobs()
        } catch { fail(error) }
    }

    func observeCloudCompletion(threadID: String, turnID: String, status: String) {
        guard ["completed", "failed", "interrupted"].contains(status) else { return }
        if recentCloudCompletions.count >= 128 { recentCloudCompletions.removeAll(keepingCapacity: true) }
        recentCloudCompletions[CloudTurnKey(threadID: threadID, turnID: turnID)] = status == "completed"
        Task { await reconcileExactCloud(threadID: threadID, turnID: turnID, succeeded: status == "completed") }
    }

    private func reconcileExactCloud(threadID: String, turnID: String, succeeded: Bool) async {
        guard let coordinator else { return }
        do {
            let failed = try await coordinator.reconcileCloudTurn(sourceThreadID: threadID, turnID: turnID, succeeded: succeeded)
            if enabled && automatic && networkKnown && networkOffline && canReadSource?(threadID) != false {
                for record in failed { _ = try await coordinator.resume(id: record.id) }
                processQueue()
            }
            await refreshJobs()
        } catch { fail(error) }
    }

    func reconcilePersistedCloud() async {
        guard !cloudReconciliationRunning, let readCloudStatus else { return }
        cloudReconciliationRunning = true
        defer { cloudReconciliationRunning = false }
        for record in jobs.filter({ $0.phase == .awaitingCloudResolution && $0.request.sourceTurnID != nil }).prefix(4) {
            guard !stopping, let turnID = record.request.sourceTurnID,
                  let status = await readCloudStatus(record.request.sourceThreadID, turnID),
                  ["completed", "failed", "interrupted"].contains(status) else { continue }
            await reconcileExactCloud(threadID: record.request.sourceThreadID, turnID: turnID, succeeded: status == "completed")
        }
    }

    func setDiagnosticNetwork(offline: Bool) {
        guard diagnostic else { return }
        networkKnown = true; networkOffline = offline
    }
    func refreshJobs() async {
        guard let coordinator else { return }
        let latest = await coordinator.tasks()
        if jobs != latest { jobs = latest; onChange?() }
    }
    private func enabledDidChange() {
        guard !stopping else { return }
        if enabled {
            guard lifecycleTask == nil else { return }
            if diagnostic {
                runtimeReady = true; error = nil
                status = "Yerel eklenti hazır · model henüz yüklenmedi"
                processQueue()
            }
            else { prepareRuntime() }
            return
        }
        runtimeReady = false
        runTask?.cancel(); setupTask?.cancel()
        guard lifecycleTask == nil else { return }
        status = "Yerel eklenti durduruluyor · kayıtlar korunuyor"
        lifecycleTask = Task {
            await stopActiveWork()
            lifecycleTask = nil
            guard !stopping else { return }
            if enabled {
                if diagnostic {
                    runtimeReady = true; error = nil
                    status = "Yerel eklenti hazır · model henüz yüklenmedi"
                    processQueue()
                }
                else { prepareRuntime() }
            } else { status = "Yerel eklenti kapalı · görevler duraklatıldı" }
        }
    }

    private func stopActiveWork() async {
        let activeRun = runTask, activeSetup = setupTask
        activeRun?.cancel(); activeSetup?.cancel()
        if let coordinator {
            for job in await coordinator.tasks() where job.phase == .running {
                try? await coordinator.pause(id: job.id)
            }
        }
        // Await structured cancellation so a late setup cannot spawn a server
        // after stop, and worker cancellation can unload its own model first.
        await activeRun?.value
        await activeSetup?.value
        runtimeReady = false
        if !diagnostic, Self.isRepository(repositoryPath) {
            do { _ = try await OfflineRuntimeCommand.run(root: repositoryPath, action: ["stop"], timeout: 20) }
            catch { if !stopping { fail(error) } }
        }
        await refreshJobs()
    }

    func shutdown() async {
        stopping = true; monitor?.cancel(); monitor = nil
        runTask?.cancel(); setupTask?.cancel()
        let pendingLifecycle = lifecycleTask
        await pendingLifecycle?.value
        await stopActiveWork()
    }
    func fail(_ error: Error) { self.error = error.localizedDescription; status = "Yerel eklenti dikkat gerektiriyor" }
    nonisolated static func isRepository(_ path: String) -> Bool {
        path.hasPrefix("/") && FileManager.default.fileExists(atPath: path + "/scripts/local-ai-setup.py")
            && FileManager.default.fileExists(atPath: path + "/Resources/LocalAI/model-lock.json")
    }
    private static func discoverRepository(defaults: UserDefaults) -> String {
        if let saved = defaults.string(forKey: "offline.repository-path"), isRepository(saved) { return saved }
        if let resources = Bundle.main.resourceURL,
           let data = try? Data(contentsOf: resources.appendingPathComponent("LocalAI/host.json")),
           let host = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let root = host["repositoryPath"], isRepository(root) { return root }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        return source
    }
}

enum OfflineHostError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum OfflineRuntimeCommand {
    private final class Output: @unchecked Sendable {
        let lock = NSLock(); var data = Data()
        func append(_ value: Data) { lock.lock(); defer { lock.unlock() }; if data.count < 131_072 { data.append(value.prefix(131_072 - data.count)) } }
        func text() -> String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }
    /// Bridges cancellation across the blocking Foundation Process boundary.
    /// Only this exact spawned Python child can be terminated, never its process
    /// group or the user's shared Ollama daemon. The CLI owns daemon shutdown.
    private final class ProcessControl: @unchecked Sendable {
        private let lock = NSLock()
        private var child: Process?
        private var cancelled = false
        func launch(_ process: Process) throws {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled else { throw CancellationError() }
            child = process
            try process.run()
        }
        func cancel() {
            lock.lock()
            cancelled = true
            let process = child
            lock.unlock()
            if let process, process.isRunning { process.terminate() }
        }
        func terminateChild() {
            lock.lock(); let process = child; lock.unlock()
            if let process, process.isRunning { process.terminate() }
        }
        func isCancelled() -> Bool {
            lock.lock(); defer { lock.unlock() }; return cancelled
        }
    }
    static func run(root: String, action: [String], timeout: TimeInterval) async throws -> String {
        let control = ProcessControl()
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            guard OfflineAIService.isRepository(root) else { throw OfflineHostError.message("Geçerli Bavbav reposu gerekli.") }
            let process = Process(), output = Output(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [root + "/scripts/local-ai-setup.py", "--repo", root] + action
            // The provisioning CLI gets no account/API credentials or shell.
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory()]
            process.standardOutput = pipe; process.standardError = pipe; process.standardInput = FileHandle.nullDevice
            defer {
                pipe.fileHandleForReading.readabilityHandler = nil
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
            }
            pipe.fileHandleForReading.readabilityHandler = { handle in
                if let data = try? handle.read(upToCount: 16_384) { output.append(data) }
            }
            try control.launch(process)
            try? pipe.fileHandleForWriting.close()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline && !Task.isCancelled && !control.isCancelled() {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            let wasCancelled = Task.isCancelled || control.isCancelled()
            let timedOut = !wasCancelled && process.isRunning
            if process.isRunning {
                control.terminateChild()
                let terminationDeadline = Date().addingTimeInterval(5)
                while process.isRunning && Date() < terminationDeadline { usleep(50_000) }
                guard !process.isRunning else {
                    throw OfflineHostError.message("Yerel kurulum işlemi henüz durmadı; başka bir işlem başlatılmadı.")
                }
            }
            process.waitUntilExit()
            pipe.fileHandleForReading.readabilityHandler = nil
            if let remaining = try? pipe.fileHandleForReading.readToEnd() { output.append(remaining) }
            if wasCancelled { throw CancellationError() }
            if timedOut { throw OfflineHostError.message("Yerel kurulum zaman aşımına uğradı; mevcut dosyalar korunuyor.") }
            guard process.terminationStatus == 0 else { throw OfflineHostError.message(String(output.text().suffix(3_000))) }
            return output.text()
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: {
            worker.cancel()
            control.cancel()
        })
    }
}
