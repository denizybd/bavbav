import AppKit
import BavbavCore
import BavbavOffline
import Combine
import SwiftUI

extension Notification.Name {
    static let bavbavSharedAccountChat = Notification.Name("dev.deniz.bavbav.shared-account-chat")
}

struct AccountChatMessage: Identifiable {
    let id: String
    let requestID: String
    let owner: String
    let author: String
    var text: String
    var phase: String
}

/// Account credentials stay inside the owner's Codex process. This service
/// polls only the narrowly typed conversation channel in the pinned engine.
@MainActor final class SharedAccountChat: ObservableObject {
    typealias RPC = (String, [String: Any]) async throws -> [String: Any]
    @Published private(set) var role: String?
    @Published var owner = "deniz" {
        didSet {
            guard owner != oldValue else { return }
            providerDrafts[oldValue] = draft
            draft = providerDrafts[owner] ?? ""
            if owner == "local", ["deniz", "emir"].contains(oldValue) { captureLocalContext(from: oldValue) }
            error = nil
        }
    }
    @Published var draft = ""
    @Published private(set) var messages: [AccountChatMessage] = []
    @Published private(set) var peerAvailable = false
    @Published private(set) var localReady = false
    @Published private(set) var activeID: String?
    @Published private(set) var hostingRequester: String?
    @Published private(set) var submitting = false
    @Published var error: String?
    @Published private(set) var accountError: String?
    @Published private(set) var localSubmitting = false
    @Published private(set) var localActiveID: String?
    @Published private(set) var localContextOrigin: String?
    @Published private(set) var localHandoffBusy = false
    @Published var sharing = false {
        didSet { if let role, loadedPreference { defaults.set(sharing, forKey: "account-chat.sharing." + role) } }
    }
    private let rpc: RPC
    private let defaults: UserDefaults
    private let worker: CodexAppServer
    private let offlineAI: OfflineAIService?
    private let localWorkspace: URL
    let localSourceID: String
    private var offlineSubscription: AnyCancellable?
    private var offlineStateSubscription: AnyCancellable?
    private var providerDrafts: [String: String] = [:]
    private var localContext: [OfflineContextMessage] = []
    private var localJobs: [OfflineTaskRecord] = []
    private var localEphemeral: [AccountChatMessage] = []
    private var cancelledLocalIDs = Set<String>()
    private let clientID = UUID().uuidString.lowercased()
    private var conversations: [String: String] = [:]
    private var threads: [String: String] = [:]
    private var task: Task<Void, Never>?
    private var hostWrites: Task<Void, Never>?
    private var lastConnection = Date.distantPast
    private var authenticated = false
    private var loadedPreference = false
    private var cursor = 0
    private var directory: URL?
    private struct Running {
        let id: String
        var threadID: String?
        var turnID: String?
        var cancelled = false
        var items: [String: String] = [:]
        var order: [String] = []
    }
    private var running: Running?
    private var finishedTurns = Set<String>()
    var peerRole: String { role == "emir" ? "deniz" : "emir" }
    var visibleMessages: [AccountChatMessage] { messages.filter { $0.owner == owner } }
    var selectedReady: Bool { owner == "local" ? offlineAI?.enabled == true : owner == role ? localReady : peerAvailable }
    var selectedActiveID: String? { owner == "local" ? localActiveID : activeID }
    var selectedSubmitting: Bool { owner == "local" ? localSubmitting : submitting }
    var localEnabled: Bool { offlineAI?.enabled == true }
    var localModelReady: Bool { offlineAI?.runtimeReady == true }
    var localStatus: String { offlineAI?.status ?? "Yerel eklenti bu sürümde bağlanmamış." }
    var latestLocalResultID: String? { localJobs.last { [.completed, .handedBack].contains($0.phase) && $0.result != nil }?.id }
    var accountLabel: String { owner == "local" ? "Yerel AI · Bu Mac" : "\(Self.name(owner)) hesabı" }
    static func name(_ role: String) -> String {
        switch role { case "emir": return "Emir"; case "local": return "Yerel AI"; case "you": return "Sen"; default: return "Deniz" }
    }

    init(defaults: UserDefaults = .standard, worker: CodexAppServer = CodexAppServer(sharedAccountWorker: true),
         offlineAI: OfflineAIService? = nil, localWorkspace: URL? = nil, rpc: @escaping RPC) {
        self.rpc = rpc; self.defaults = defaults; self.worker = worker
        self.offlineAI = offlineAI
        self.localWorkspace = localWorkspace ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Bavbav/LocalAccountChats", isDirectory: true)
        let saved = defaults.string(forKey: "account-chat.local-conversation").flatMap(UUID.init(uuidString:))
        let conversation = (saved ?? UUID()).uuidString.lowercased()
        defaults.set(conversation, forKey: "account-chat.local-conversation")
        localSourceID = "account-local-" + conversation
        if let offlineAI {
            refreshLocal(offlineAI.jobs)
            offlineSubscription = offlineAI.$jobs.sink { [weak self] jobs in
                Task { @MainActor in self?.refreshLocal(jobs) }
            }
            offlineStateSubscription = offlineAI.objectWillChange.sink { [weak self] in
                Task { @MainActor in self?.objectWillChange.send() }
            }
        }
    }

    func selectProvider(_ provider: String) {
        guard ["deniz", "emir", "local"].contains(provider) else { return }
        owner = provider
    }

    private func captureLocalContext(from provider: String) {
        var remaining = 1_500
        localContext = Array(messages.filter { $0.owner == provider && !$0.text.isEmpty }.suffix(8).reversed().compactMap { item in
            guard remaining > 0 else { return nil }
            // Remove complete secrets before truncation can cut their prefix.
            let text = String(OfflineAIService.redacted(item.text).suffix(min(remaining, 750)))
            remaining -= text.count
            return OfflineContextMessage(role: item.author == "assistant" ? "assistant" : "user", text: text)
        }.reversed())
        localContextOrigin = localContext.isEmpty ? nil : Self.name(provider) + " · yalnızca görünür konuşma"
    }

    private func refreshLocal(_ jobs: [OfflineTaskRecord]) {
        localJobs = jobs.filter { $0.request.sourceThreadID == localSourceID }.sorted { $0.request.createdAt < $1.request.createdAt }
        let known = Set(localJobs.map(\.id))
        localEphemeral.removeAll { known.contains($0.requestID) }
        let projected = localJobs.flatMap { job in
            [AccountChatMessage(id: job.id + "-user", requestID: job.id, owner: "local", author: "you",
                                text: job.request.objective, phase: "sent"),
             AccountChatMessage(id: job.id, requestID: job.id, owner: "local", author: "assistant",
                                text: job.result?.output ?? job.errorMessage ?? (OfflineAIView.phase(job.phase)
                                    + (job.receipts.last.map { " · " + $0.summary } ?? "")), phase: job.phase.rawValue)]
        }
        messages = messages.filter { $0.owner != "local" } + projected + localEphemeral
        if let id = localActiveID, let record = localJobs.first(where: { $0.id == id }),
           ![.queued, .running].contains(record.phase) { localActiveID = nil }
        if localActiveID == nil {
            localActiveID = localJobs.first(where: { [.queued, .running].contains($0.phase) })?.id
        }
    }

    private func clearDraft(_ text: String, provider: String) {
        if provider == owner {
            if draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft = "" }
        } else if providerDrafts[provider]?.trimmingCharacters(in: .whitespacesAndNewlines) == text {
            providerDrafts[provider] = ""
        }
    }

    private func sendLocal() {
        guard !localSubmitting, localActiveID == nil else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 6_000 else { error = "Yerel mesaj boş olmamalı ve 6.000 UTF-8 baytını aşmamalı."; return }
        guard let offlineAI, offlineAI.enabled else { error = "Yerel AI eklentisini etkinleştir. Başka hesaba otomatik geçilmedi."; return }
        let id = UUID().uuidString.lowercased()
        var context = localContext
        for item in localJobs.suffix(2) {
            context.append(.init(role: "user", text: String(OfflineAIService.redacted(item.request.objective).suffix(350))))
            if let output = item.result?.output { context.append(.init(role: "assistant", text: String(OfflineAIService.redacted(output).suffix(350)))) }
        }
        var contextBudget = 1_500
        let captured = Array(context.reversed().compactMap { item -> OfflineContextMessage? in
            guard contextBudget > 0 else { return nil }
            let value = String(OfflineAIService.redacted(item.text).suffix(contextBudget))
            contextBudget -= value.count
            return .init(role: item.role, text: value)
        }.reversed())
        localSubmitting = true; localActiveID = id; error = nil
        localEphemeral += [AccountChatMessage(id: id + "-user", requestID: id, owner: "local", author: "you", text: text, phase: "sent"),
                           AccountChatMessage(id: id, requestID: id, owner: "local", author: "assistant", text: "Yerel görev kaydediliyor…", phase: "queued")]
        refreshLocal(offlineAI.jobs)
        Task {
            defer { localSubmitting = false; cancelledLocalIDs.remove(id) }
            do {
                let values = try? localWorkspace.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard values?.isSymbolicLink != true else { throw OfflineHostError.message("Yerel sohbet çalışma klasörü bir bağlantı olamaz.") }
                try FileManager.default.createDirectory(at: localWorkspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: localWorkspace.path)
                await offlineAI.start()
                guard !cancelledLocalIDs.contains(id) else { throw CancellationError() }
                _ = try await offlineAI.enqueue(text: text, threadID: localSourceID, cwd: localWorkspace.path,
                                               deduplicationKey: "account-local-request-" + id, capturedContext: captured, requestID: id)
                if cancelledLocalIDs.contains(id) {
                    try await offlineAI.cancelTask(id: id)
                    refreshLocal(offlineAI.jobs)
                    return
                }
                clearDraft(text, provider: "local")
                refreshLocal(offlineAI.jobs)
            } catch {
                if !(error is CancellationError) { self.error = error.localizedDescription }
                if let index = localEphemeral.firstIndex(where: { $0.id == id }) {
                    localEphemeral[index].phase = error is CancellationError ? "cancelled" : "failed"
                    localEphemeral[index].text = error is CancellationError ? "Yerel gönderim iptal edildi; taslağın korundu." : error.localizedDescription
                }
                if localActiveID == id { localActiveID = nil }
                refreshLocal(offlineAI.jobs)
            }
        }
    }

    func handoffLocalResult(to target: String, taskID: String? = nil) {
        guard ["deniz", "emir"].contains(target), !localHandoffBusy, let offlineAI,
              let id = taskID ?? latestLocalResultID,
              localJobs.contains(where: { $0.id == id && [.completed, .handedBack].contains($0.phase) }) else { return }
        localHandoffBusy = true
        Task {
            defer { localHandoffBusy = false }
            do {
                let report = try await offlineAI.prepareTaskHandoff(id: id)
                let existing = target == owner ? draft : providerDrafts[target] ?? ""
                guard existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw OfflineHostError.message("\(Self.name(target)) taslağı dolu; yerel rapor mevcut yazının üzerine konmadı.")
                }
                providerDrafts[target] = OfflineAIService.redacted(report.text)
                if owner == target { draft = providerDrafts[target] ?? "" }
                else { owner = target }
                try await offlineAI.acceptTaskHandoff(id: id, reportID: report.id)
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            await self.worker.setEventHandler { [weak self] event in Task { @MainActor in self?.handle(event) } }
            while !Task.isCancelled {
                do { try await self.tick() }
                catch {
                    self.localReady = false; self.peerAvailable = false; self.accountError = error.localizedDescription
                    if self.owner != "local" { self.error = error.localizedDescription }
                    if let id = self.running?.id { await self.stopHost(id) }
                    if let id = self.activeID {
                        _ = try? await self.rpc("accountCancel", ["id": id])
                        self.consume(["id": id, "phase": "failed", "text": "Hesap bağlantısı kesildi. Mesaj otomatik tekrar gönderilmedi."])
                    }
                    // A restarted engine has a new ephemeral event cursor.
                    // Durable owner receipts still prevent duplicate spending.
                    self.cursor = 0
                }
                do { try await Task.sleep(nanoseconds: 700_000_000) } catch { break }
            }
        }
    }
    func tick() async throws {
        let state = try await rpc("accountState", [:])
        guard let role = state["role"] as? String, ["deniz", "emir"].contains(role) else { throw CodexClientError.invalidResponse("Önce Workspace içinde Deniz ve Emir cihazlarını eşleştirin.") }
        if self.role == nil {
            self.role = role
            if owner != "local" { owner = role }
            // Deniz explicitly requested sharing his quota. Emir independently
            // opts in on his device before anybody can spend his quota.
            let key = "account-chat.sharing." + role
            sharing = defaults.object(forKey: key) == nil ? role == "deniz" : defaults.bool(forKey: key)
            loadedPreference = true
        }
        if !authenticated && Date().timeIntervalSince(lastConnection) > 15 {
            lastConnection = Date()
            do {
                let health = try await worker.connect()
                authenticated = health.authenticated && health.modelAvailable && health.accountType == "chatgpt"
                if !authenticated {
                    accountError = "Bu Mac'te kullanılabilir bir ChatGPT/Codex hesabıyla giriş yapılmalı."
                    if owner != "local" { error = accountError }
                }
            } catch { accountError = error.localizedDescription; if owner != "local" { self.error = error.localizedDescription } }
        }
        let status = try await rpc("accountHeartbeat", ["clientId": clientID, "enabled": sharing, "available": authenticated])
        localReady = status["localReady"] as? Bool == true; peerAvailable = status["peerAvailable"] as? Bool == true
        hostingRequester = (status["active"] as? [String: Any])?["requester"] as? String
        for cancelled in status["cancellations"] as? [String] ?? [] where running?.id == cancelled { await stopHost(cancelled) }
        let updates = try await rpc("accountPoll", ["after": cursor])
        cursor = updates["cursor"] as? Int ?? cursor
        if updates["truncated"] as? Bool == true {
            accountError = "Yanıt akışının bir kısmı alınamadı. İstek tekrar gönderilmedi."
            if owner != "local" { error = accountError }
        }
        for event in updates["events"] as? [[String: Any]] ?? [] { consume(event) }
        if running == nil, authenticated {
            let result = try await rpc("accountTake", ["clientId": clientID])
            if let request = result["request"] as? [String: Any] { beginHost(request) }
        }
    }
    func send() {
        if owner == "local" { sendLocal(); return }
        guard !submitting, activeID == nil else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 32768 else { error = "Mesaj boş olmamalı ve 32 KB sınırını aşmamalı."; return }
        guard role != nil, selectedReady else { error = "Seçilen hesap kullanılamıyor. Diğer hesaba otomatik geçilmedi."; return }
        let id = UUID().uuidString.lowercased(), selectedOwner = owner
        let conversation = conversations[selectedOwner] ?? UUID().uuidString.lowercased(); conversations[selectedOwner] = conversation
        submitting = true; error = nil
        messages.append(AccountChatMessage(id: id + "-user", requestID: id, owner: selectedOwner, author: role ?? "", text: text, phase: "sent"))
        messages.append(AccountChatMessage(id: id, requestID: id, owner: selectedOwner, author: "assistant", text: "", phase: "accepted"))
        activeID = id
        Task {
            defer { submitting = false }
            do {
                _ = try await rpc("accountSend", ["id": id, "conversation": conversation, "owner": selectedOwner, "text": text])
                clearDraft(text, provider: selectedOwner)
            } catch {
                self.error = error.localizedDescription
                consume(["id": id, "phase": "failed", "text": error.localizedDescription])
            }
        }
    }
    func cancel() {
        if owner == "local" {
            guard let id = localActiveID, let offlineAI else { return }
            cancelledLocalIDs.insert(id)
            if localJobs.contains(where: { $0.id == id }) {
                Task {
                    do { try await offlineAI.cancelTask(id: id); error = nil; cancelledLocalIDs.remove(id) }
                    catch { self.error = error.localizedDescription }
                }
            }
            return
        }
        guard let id = activeID else { return }
        Task { do { _ = try await rpc("accountCancel", ["id": id]) } catch { self.error = error.localizedDescription } }
    }
    private func consume(_ event: [String: Any]) {
        guard let id = event["id"] as? String, let phase = event["phase"] as? String,
              let index = messages.firstIndex(where: { $0.id == id && $0.owner != "local" }) else { return }
        guard !["completed", "failed", "interrupted"].contains(messages[index].phase) else { return }
        messages[index].phase = phase
        if let text = event["text"] as? String {
            if phase == "delta" { messages[index].text += text }
            else { messages[index].text = text }
        }
        if ["completed", "failed", "interrupted"].contains(phase), activeID == id { activeID = nil }
    }
    private func beginHost(_ request: [String: Any]) {
        guard let id = request["id"] as? String, let conversation = request["conversation"] as? String,
              let requester = request["requester"] as? String, let text = request["text"] as? String else { return }
        running = Running(id: id)
        Task {
            do {
                if directory == nil {
                    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BavbavAccountChat-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); directory = root
                }
                let key = requester + ":" + conversation
                let threadID: String
                if let existing = threads[key] { threadID = existing }
                else { threadID = try await worker.startSharedAccountThread(cwd: directory!.path).id; threads[key] = threadID }
                guard running?.id == id, running?.cancelled == false else { return }
                running?.threadID = threadID
                let turn = try await worker.startSharedAccountTurn(threadID: threadID, text: text)
                guard running?.id == id else { try? await worker.interruptSharedAccountTurn(threadID: threadID, turnID: turn.id); return }
                running?.turnID = turn.id
                if running?.cancelled == true { await stopHost(id) }
                else { queueReply(id: id, phase: "running") }
            } catch { queueReply(id: id, phase: "failed", text: error.localizedDescription) }
        }
    }
    private func handle(_ event: CodexServerEvent) {
        if case .transportClosed(let reason) = event {
            authenticated = false; threads.removeAll()
            if let id = running?.id { queueReply(id: id, phase: "failed", text: reason) }
            return
        }
        guard let current = running else { return }
        switch event {
        case .turnStarted(let thread, let turn) where thread == current.threadID && !finishedTurns.contains(turn): running?.turnID = turn
        case .agentMessageDelta(let thread, let turn, let item, let delta) where thread == current.threadID && turn == current.turnID:
            if running?.items[item] == nil { running?.order.append(item) }
            running?.items[item, default: ""] += delta
            // Split by characters: at most 4 KiB per protocol frame.
            var rest = delta[...]
            while !rest.isEmpty { let chunk = String(rest.prefix(1024)); queueReply(id: current.id, phase: "delta", text: chunk); rest = rest.dropFirst(chunk.count) }
        case .itemCompleted(let thread, let turn, let message) where thread == current.threadID && turn == current.turnID:
            if message.role == .agent && message.kind == .agent {
                if running?.items[message.id] == nil { running?.order.append(message.id) }
                running?.items[message.id] = message.text
            }
        case .turnCompleted(let thread, let turn, let status, let failure) where thread == current.threadID && turn == current.turnID:
            finishedTurns.insert(turn)
            let answer = (running?.order ?? []).compactMap { running?.items[$0] }.joined(separator: "\n\n")
            queueReply(id: current.id, phase: status == "completed" ? "completed" : status == "interrupted" ? "interrupted" : "failed", text: status == "completed" ? (answer.isEmpty ? "Yanıt metni gelmedi." : answer) : failure ?? "İstek tamamlanmadı.")
        default: break
        }
    }
    private func queueReply(id: String, phase: String, text: String? = nil) {
        let previous = hostWrites
        hostWrites = Task { [weak self] in
            await previous?.value
            guard let self, self.running?.id == id else { return }
            var args: [String: Any] = ["clientId": self.clientID, "id": id, "phase": phase]
            if let text, !text.isEmpty { args["text"] = text }
            do { _ = try await self.rpc("accountReply", args) }
            catch {
                self.accountError = error.localizedDescription
                if self.owner != "local" { self.error = error.localizedDescription }
                await self.stopHost(id)
            }
            if ["completed", "failed", "interrupted"].contains(phase), self.running?.id == id { self.running = nil }
        }
    }
    private func stopHost(_ id: String) async {
        guard running?.id == id else { return }
        running?.cancelled = true
        if let thread = running?.threadID, let turn = running?.turnID { try? await worker.interruptSharedAccountTurn(threadID: thread, turnID: turn) }
        running = nil
    }
    func shutdown() async {
        task?.cancel(); task = nil
        if let id = running?.id { await stopHost(id) }
        _ = try? await rpc("accountHeartbeat", ["clientId": clientID, "enabled": false, "available": false])
        await worker.shutdown()
        if let directory { try? FileManager.default.removeItem(at: directory) }; directory = nil
    }
}

@MainActor final class SharedAccountWindow: NSObject, NSWindowDelegate {
    let service: SharedAccountChat
    private var window: NSWindow?
    private var monitor: Any?
    var isVisible: Bool { window?.isVisible == true }
    init(service: SharedAccountChat) { self.service = service }
    @discardableResult func prepare() -> NSWindow {
        if window == nil {
            let result = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 740), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            result.title = "Bavbav · Konuşma hesabı"; result.identifier = .init("bavbav.account-chat")
            result.minSize = NSSize(width: 650, height: 550); result.isReleasedWhenClosed = false
            result.appearance = NSAppearance(named: .darkAqua); result.delegate = self; result.level = .normal
            let container = CornerResizeContainer(frame: NSRect(origin: .zero, size: result.contentLayoutRect.size))
            container.setContent(NSHostingView(rootView: SharedAccountView(service: service)))
            result.contentView = container; result.center(); window = result
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }; return self.handleKey(event)
            }
        }
        return window!
    }
    func show() {
        _ = prepare()
        service.start(); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func handleKey(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window else { return event }
        let editing = (window.firstResponder as? NSTextView)?.isEditable == true || window.firstResponder is NSTextField
        if !editing, event.keyCode == 12, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            window.orderOut(nil); return nil
        }
        return event
    }
    func shutdown() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.orderOut(nil); return false }
}

struct SharedAccountView: View {
    @ObservedObject var service: SharedAccountChat
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("KİMİN HESABI KULLANILSIN?").font(BavbavTheme.mono(16, weight: .semibold)).foregroundStyle(BavbavTheme.accent)
            HStack(spacing: 12) {
                account("deniz", color: Color(red: 1, green: 0.32, blue: 0.4))
                account("emir", color: Color(red: 0.36, green: 0.61, blue: 1))
                account("local", color: BavbavTheme.accent)
            }
            Text(service.owner == "local" ? "Çıkarım bu Mac'te · hesap kotası kullanılmaz · salt okunur yerel araçlar."
                 : "Bu konuşma \(SharedAccountChat.name(service.owner)) hesabının kullanım kotasından gider.")
                .font(BavbavTheme.mono(11)).foregroundStyle(BavbavTheme.text)
            if service.owner == "local" {
                Text(service.localStatus).font(BavbavTheme.mono(9)).foregroundStyle(BavbavTheme.muted)
                if let origin = service.localContextOrigin {
                    Text("Açık seçimle alınan bağlam: \(origin)").font(BavbavTheme.mono(9)).foregroundStyle(BavbavTheme.muted)
                }
            } else {
                HStack {
                    Button("Yerel AI'ya devret") { service.selectProvider("local") }
                        .buttonStyle(.plain).foregroundStyle(BavbavTheme.accent)
                    Text("Görünür metni alır; mesaj göndermez ve hesap isteğini durdurmaz.").foregroundStyle(BavbavTheme.muted)
                }.font(BavbavTheme.mono(8))
            }
            if let role = service.role {
                Toggle("\(SharedAccountChat.name(service.peerRole)) benim hesabımı kullanabilsin", isOn: $service.sharing)
                    .toggleStyle(.checkbox).font(BavbavTheme.mono(11))
                Text("Bu cihaz: \(SharedAccountChat.name(role)) · \(service.localReady ? "hesap hazır" : "hesap bağlantısı bekleniyor")")
                    .font(BavbavTheme.mono(10)).foregroundStyle(BavbavTheme.muted)
            }
            if let requester = service.hostingRequester, requester != service.role {
                Label("\(SharedAccountChat.name(requester)) şu anda hesabını kullanıyor", systemImage: "person.2.fill")
                    .font(BavbavTheme.mono(11)).foregroundStyle(BavbavTheme.accent)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if service.visibleMessages.isEmpty {
                            Text(service.owner == "local" ? "Bu Mac'te yerel bir konuşma başlat. Eşleştirme veya hesap girişi gerekmez." : "Bu hesapla yeni bir konuşma başlat.")
                                .foregroundStyle(BavbavTheme.muted)
                        }
                        ForEach(service.visibleMessages) { message in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(message.author == "assistant" ? (message.owner == "local" ? "LOCAL · QWEN3 14B" : "AI · \(SharedAccountChat.name(message.owner)) hesabı") : SharedAccountChat.name(message.author))
                                    .font(BavbavTheme.mono(10, weight: .semibold)).foregroundStyle(BavbavTheme.accent)
                                Text(message.text.isEmpty ? "Yanıt bekleniyor…" : message.text).textSelection(.enabled)
                                    .font(BavbavTheme.mono(12)).foregroundStyle(["failed", "interrupted"].contains(message.phase) ? BavbavTheme.warning : BavbavTheme.text)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .background(BavbavTheme.raised).clipShape(RoundedRectangle(cornerRadius: 8)).id(message.id)
                        }
                    }
                }.onChange(of: service.messages.count) { _ in if let last = service.visibleMessages.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            if service.owner == "local", service.latestLocalResultID != nil {
                HStack {
                    Text("Raporu yalnızca boş hesap taslağına aktar:").foregroundStyle(BavbavTheme.muted)
                    Button("Deniz taslağına") { service.handoffLocalResult(to: "deniz") }
                    Button("Emir taslağına") { service.handoffLocalResult(to: "emir") }
                }.font(BavbavTheme.mono(8)).disabled(service.localHandoffBusy)
            }
            if let error = service.error { Text(error).font(BavbavTheme.mono(11)).foregroundStyle(BavbavTheme.warning).textSelection(.enabled) }
            TextEditor(text: $service.draft).font(BavbavTheme.mono(12)).scrollContentBackground(.hidden)
                .padding(8).frame(height: 85).background(BavbavTheme.raised).clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Hesap sohbeti mesajı")
            HStack {
                Text("Metin sohbeti · bu oturumdaki hesap konuşmaları ayrı tutulur").font(BavbavTheme.mono(9)).foregroundStyle(BavbavTheme.muted)
                Spacer()
                if service.selectedActiveID != nil { Button("Durdur") { service.cancel() } }
                Button(service.selectedSubmitting ? "Gönderiliyor…" : service.owner == "local" ? "Yerelde çalıştır" : "Gönder") { service.send() }
                    .keyboardShortcut(.return, modifiers: .command).buttonStyle(.borderedProminent).tint(BavbavTheme.accent)
                    .disabled(service.selectedSubmitting || service.selectedActiveID != nil || !service.selectedReady || service.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(22).background(BavbavTheme.background).foregroundStyle(BavbavTheme.text)
    }
    private func account(_ role: String, color: Color) -> some View {
        Button { service.selectProvider(role) } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                Image(systemName: service.owner == role ? "checkmark.circle.fill" : "circle")
                Text(role == "local" ? "Yerel AI · Bu Mac" : "\(SharedAccountChat.name(role)) hesabı")
                Spacer()
                }
                Text(role == "local" ? (service.localModelReady ? "YEREL MODEL HAZIR" : service.localEnabled ? "MODEL HAZIRLANIYOR" : "EKLENTİ KAPALI")
                     : role == service.role ? "BU CİHAZ" : service.peerAvailable ? "HAZIR" : "KULLANILAMIYOR").font(BavbavTheme.mono(8))
            }.padding(12).frame(maxWidth: .infinity).background(color.opacity(service.owner == role ? 0.16 : 0.04))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(service.owner == role ? 1 : 0.3)))
        }.buttonStyle(.plain).foregroundStyle(color).font(BavbavTheme.mono(13, weight: .medium))
            .accessibilityIdentifier("account.provider." + role)
    }
}
