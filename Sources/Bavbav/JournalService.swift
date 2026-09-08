import BavbavCore
import Combine
import Foundation

@MainActor
final class JournalService: ObservableObject {
    static let defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Bavbav/Journal", isDirectory: true)
    static let dailyRequestLimit = 60
    @Published private(set) var state = JournalState()
    @Published private(set) var working = false
    @Published private(set) var error: String?
    @Published private(set) var loaded = false
    @Published var sourceConnected = false
    @Published private(set) var lastDeletedID: String?
    var onOpenSource: ((CodexThread) -> Void)?
    var recoverTurn: ((String, String) async throws -> (messages: [CodexMessage], complete: Bool))?
    var extract: ((JournalJob, [JournalNote]) async throws -> [JournalCandidate])?
    private let repository: JournalRepository
    private let directory: URL?
    private let active: Bool
    private var task: Task<Void, Never>?
    private var persistence: Task<Void, Never>?
    private var revision = 0
    private var recoveryRunning = false
    private var recoveryIDs = Set<String>()
    private var lastRecoveryAt = Date.distantPast
    private var storageFailed = false
    private var halted = false
    private var worker: CodexAppServer?
    var notes: [JournalNote] { state.notes.filter { !$0.deleted } }
    var pendingCount: Int { state.jobs.count }
    var status: String {
        if let error { return error }
        if !state.enabled { return "OTOMATİK NOT KAPALI" }
        if working { return "NOTLAR AYIKLANIYOR" }
        if state.requestsToday >= Self.dailyRequestLimit && state.usageDay == JournalRules.day(Date()) { return "GÜNLÜK SINIR · BEKLEYENLER YARIN DEVAM EDER" }
        if !sourceConnected { return "CODEX BAĞLANTISI BEKLENİYOR" }
        return pendingCount > 0 ? "\(pendingCount) İŞ BEKLİYOR" : "YENİ KONUŞMALAR İZLENİYOR"
    }

    init(directory: URL? = nil, activeInMemory: Bool = false) {
        self.directory = directory
        active = directory != nil || activeInMemory
        repository = JournalRepository(directory: directory)
    }

    private func extractWithCodex(_ job: JournalJob, _ notes: [JournalNote]) async throws -> [JournalCandidate] {
            let worker = CodexAppServer(journalWorker: true)
            self.worker = worker
            defer { self.worker = nil }
            let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("bavbav-journal-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            do {
                let output = try await worker.extractJournal(prompt: JournalRules.prompt(job: job, existing: notes), cwd: workspace.path)
                await worker.shutdown()
                try? FileManager.default.removeItem(at: workspace) // Owned unique, empty, read-only worker directory.
                return output
            } catch {
                await worker.shutdown()
                try? FileManager.default.removeItem(at: workspace)
                throw error
            }
    }

    func start() async {
        guard !loaded else { return }
        do {
            state = try await repository.load()
            loaded = true
            recoveryIDs = Set(state.jobs.filter { !$0.ready }.map(\.id))
            pulse()
        } catch {
            storageFailed = true; loaded = true; self.error = error.localizedDescription
        }
    }

    func observe(thread: CodexThread, turnID: String, channel: String, message: CodexMessage? = nil) {
        guard active, loaded, !storageFailed, state.enabled else { return }
        let jobID = "\(thread.id)/\(turnID)"
        guard !state.completedJobs.contains(jobID) else { return }
        if !state.jobs.contains(where: { $0.id == jobID }) {
            var job = JournalJob(thread: thread, turnID: turnID, channel: channel)
            job.context = state.contexts.first(where: { $0.threadID == thread.id })?.messages ?? []
            state.jobs.append(job)
        }
        if let message, message.kind.isConversation,
           let index = state.jobs.firstIndex(where: { $0.id == jobID }) {
            var dated = message
            if dated.timestamp == nil { dated.timestamp = state.jobs[index].capturedAt }
            if let found = state.jobs[index].messages.firstIndex(where: { $0.id == message.id }) {
                state.jobs[index].messages[found] = dated
            } else {
                state.jobs[index].messages.append(dated)
            }
        }
        persist()
    }

    func finish(threadID: String, turnID: String, succeeded: Bool) {
        guard active, loaded, let index = state.jobs.firstIndex(where: { $0.id == "\(threadID)/\(turnID)" }) else { return }
        if !succeeded { state.jobs[index].messages.removeAll { $0.role != .user } }
        state.jobs[index].ready = true
        rememberContext(state.jobs[index])
        persist()
        pulse()
    }

    /// Called by the existing refresh cadence; no always-on extra timer/process.
    func pulse() {
        guard active, loaded, !halted, !storageFailed, state.enabled else { return }
        if !recoveryRunning, !recoveryIDs.isEmpty, Date().timeIntervalSince(lastRecoveryAt) > 60, let recoverTurn {
            recoveryRunning = true
            lastRecoveryAt = Date()
            let candidates = state.jobs.filter { recoveryIDs.contains($0.id) }.prefix(3)
            Task { [weak self] in
                guard let self else { return }
                defer { recoveryRunning = false }
                for job in candidates {
                    do {
                        let recovered = try await recoverTurn(job.thread.id, job.turnID)
                        guard !halted, let index = state.jobs.firstIndex(where: { $0.id == job.id }) else { continue }
                        if recovered.complete {
                            if !recovered.messages.isEmpty { state.jobs[index].messages = recovered.messages }
                            state.jobs[index].ready = true
                            rememberContext(state.jobs[index])
                            recoveryIDs.remove(job.id)
                            persist()
                        }
                    } catch { self.error = "Bekleyen not korunuyor: \(error.localizedDescription)" }
                }
                runNext()
            }
        }
        runNext()
    }

    private func runNext() {
        guard active, loaded, !halted, !storageFailed, state.enabled, task == nil else { return }
        let today = JournalRules.day(Date())
        if state.usageDay != today { state.usageDay = today; state.requestsToday = 0 }
        guard state.requestsToday < Self.dailyRequestLimit,
              let job = state.jobs.first(where: { $0.ready && $0.attempts < 3 && $0.nextAttempt <= Date() }) else { return }
        working = true
        task = Task { [weak self] in
            guard let self else { return }
            defer { working = false; task = nil; if !halted { runNext() } }
            // Persisted outbox precedes model invocation and can survive an app quit.
            await flush()
            guard !storageFailed, !Task.isCancelled, state.enabled else { return }
            if job.messages.isEmpty {
                complete(jobID: job.id, notes: [])
                return
            }
            do {
                _ = try JournalRules.prompt(job: job, existing: state.notes)
                state.requestsToday += 1
                persist()
                await flush()
                let candidates: [JournalCandidate]
                if let extract { candidates = try await extract(job, state.notes) }
                else { candidates = try await extractWithCodex(job, state.notes) }
                guard !Task.isCancelled, !halted else { return }
                let accepted = JournalRules.accepted(candidates, job: job, existing: state.notes)
                complete(jobID: job.id, notes: accepted)
                error = nil
            } catch is CancellationError {
                // Keep the job in the outbox; resume after relaunch/unpause.
            } catch {
                if let index = state.jobs.firstIndex(where: { $0.id == job.id }) {
                    state.jobs[index].attempts += 1
                    state.jobs[index].nextAttempt = Date().addingTimeInterval(Double(state.jobs[index].attempts) * 120)
                }
                self.error = error.localizedDescription
                persist()
            }
        }
    }

    private func complete(jobID: String, notes: [JournalNote]) {
        state.notes.append(contentsOf: notes)
        state.completedJobs.insert(jobID)
        state.jobs.removeAll { $0.id == jobID }
        persist()
    }
    private func rememberContext(_ job: JournalJob) {
        guard !state.contexts.contains(where: { $0.threadID == job.thread.id && $0.updatedAt > job.capturedAt }) else { return }
        var remaining = 16_000
        var context: [CodexMessage] = []
        for message in (job.context + job.messages).suffix(8).reversed() {
            guard message.text.utf8.count <= remaining else { continue }
            remaining -= message.text.utf8.count
            context.insert(message, at: 0)
        }
        state.contexts.removeAll { $0.threadID == job.thread.id }
        state.contexts.append(JournalContext(threadID: job.thread.id, updatedAt: job.capturedAt, messages: context))
        state.contexts = Array(state.contexts.suffix(32))
    }
    func toggleEnabled() {
        state.enabled.toggle()
        if !state.enabled { task?.cancel() }
        persist()
        if state.enabled { pulse() }
    }
    func retry() {
        error = nil
        for index in state.jobs.indices { state.jobs[index].attempts = 0; state.jobs[index].nextAttempt = .distantPast }
        lastRecoveryAt = .distantPast
        persist(); pulse()
    }
    func edit(id: String, summary: String, day: String?) -> Bool {
        let summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty, summary.count <= 240, day == nil || JournalRules.date(day!) != nil,
              let index = state.notes.firstIndex(where: { $0.id == id }) else { return false }
        state.notes[index].summary = summary; state.notes[index].eventDay = day; state.notes[index].edited = true
        persist(); return true
    }
    func delete(id: String) {
        guard let index = state.notes.firstIndex(where: { $0.id == id }) else { return }
        state.notes[index].deleted = true; lastDeletedID = id
        persist()
    }
    func undoDelete() {
        guard let id = lastDeletedID, let index = state.notes.firstIndex(where: { $0.id == id }) else { return }
        state.notes[index].deleted = false; lastDeletedID = nil
        persist()
    }
    private func persist() {
        guard active, loaded, !storageFailed else { return }
        revision += 1
        let snapshot = state, number = revision, previous = persistence
        persistence = Task { [weak self, repository] in
            await previous?.value
            do { try await repository.save(snapshot, revision: number) }
            catch { self?.storageFailed = true; self?.error = error.localizedDescription }
        }
    }
    func flush() async { await persistence?.value }
    func stop() async {
        halted = true; task?.cancel()
        await worker?.shutdown()
        await task?.value
        await flush()
    }
}
