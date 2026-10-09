import BavbavCore
import Foundation

@MainActor public protocol CompanionConversation: AnyObject {
    func connect() async throws -> String
    func send(text: String, image: URL?) async throws -> String
    func stop() async
    func setDisconnectionHandler(_ handler: ((String) -> Void)?)
}

public extension CompanionConversation {
    func setDisconnectionHandler(_ handler: ((String) -> Void)?) {}
}

public struct CompanionFailure: LocalizedError {
    public let message: String
    public let requiresReconnect: Bool
    public init(_ message: String, requiresReconnect: Bool = false) {
        self.message = message; self.requiresReconnect = requiresReconnect
    }
    public var errorDescription: String? { message }
}

/// One lazy, restricted app-server connection using Bavbav's existing login.
/// Never takes over a coding chat, reads credentials or accesses Companion keys.
@MainActor public final class CodexCompanionConversation: CompanionConversation {
    private var client: CodexAppServer?
    public private(set) var threadID: String?
    private var generation = UUID()
    private struct TurnResult {
        var completed: (String, String?)?
        var messages: [String: CodexMessage] = [:]
        var messageOrder: [String] = []
    }
    @MainActor private final class PendingSend {
        let generation: UUID
        let server: CodexAppServer
        let threadID: String
        // Only the RPC acknowledgement can establish our turn's identity.
        var turnID: String?
        var results: [String: TurnResult] = [:]
        var bufferedTurns: [String] = []
        var transportFailure: String?
        var submitted = false
        var cleanup: Task<Void, Never>?
        init(generation: UUID, server: CodexAppServer, threadID: String) {
            self.generation = generation; self.server = server; self.threadID = threadID
        }
    }
    private var pendingSend: PendingSend?
    private var eventTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<CodexServerEvent>.Continuation?
    private var busy = false
    private var disconnectedCleanup: Task<Void, Never>?
    private var disconnectionHandler: ((String) -> Void)?
    private let directory: URL
    private let ephemeral: Bool

    public init(directory: URL, ephemeral: Bool = false) {
        self.directory = directory; self.ephemeral = ephemeral
    }

    public func setDisconnectionHandler(_ handler: ((String) -> Void)?) {
        disconnectionHandler = handler
    }

    public func connect() async throws -> String {
        if let cleanup = disconnectedCleanup {
            let token = generation
            await cleanup.value
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
        }
        if let threadID, client != nil { return threadID }
        guard !busy else { throw CompanionFailure("Bağlantı zaten hazırlanıyor.") }
        busy = true
        let token = UUID(); generation = token
        let server = CodexAppServer(companionWorker: true)
        client = server
        do {
            let health = try await server.connect()
            guard generation == token else { throw CancellationError() }
            guard health.authenticated, health.accountType == "chatgpt" else {
                throw CompanionFailure("Bavbav için ChatGPT hesap girişi gerekiyor. API anahtarı yolu kullanılmadı.")
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let thread = try await server.startCompanionThread(cwd: directory.path, ephemeral: ephemeral)
            guard generation == token else { throw CancellationError() }
            threadID = thread.id
            let events = AsyncStream<CodexServerEvent>.makeStream()
            eventContinuation = events.continuation
            eventTask = Task { @MainActor [weak self] in
                for await event in events.stream {
                    guard !Task.isCancelled else { return }
                    self?.receive(event, token: token)
                }
            }
            await server.setEventHandler { event in events.continuation.yield(event) }
            if !ephemeral { try? await server.setThreadName(id: thread.id, name: "Companion · Türkçe ses") }
            guard generation == token else { throw CancellationError() }
            busy = false
            return thread.id
        } catch {
            await server.shutdown()
            if generation == token { endEvents(); client = nil; threadID = nil; busy = false }
            throw error
        }
    }

    public func send(text: String, image: URL?) async throws -> String {
        guard let client, let threadID, !busy else {
            throw CompanionFailure("Önce bağlan; devam eden yanıtın bitmesini bekle.", requiresReconnect: self.client == nil)
        }
        try Task.checkCancellation()
        let request = PendingSend(generation: generation, server: client, threadID: threadID)
        busy = true; pendingSend = request
        defer { if pendingSend === request { pendingSend = nil; busy = false } }
        return try await withTaskCancellationHandler {
            do { return try await send(text: text, image: image, request: request) }
            catch {
                if Task.isCancelled {
                    await cancelSend(request)
                    throw CancellationError()
                }
                if request.submitted && request.turnID == nil || request.transportFailure != nil {
                    // A failed/expired start RPC may already have submitted a
                    // turn. Do not release its writer slot onto that transport.
                    await cancelSend(request)
                    throw CompanionFailure(error.localizedDescription, requiresReconnect: true)
                }
                throw error
            }
        } onCancel: {
            // Cancelling while turn/start is awaiting its RPC reply must not
            // wait for that reply. If its ID is unknown, close only this child.
            Task { @MainActor [weak self] in await self?.cancelSend(request) }
        }
    }

    private func send(text: String, image: URL?, request: PendingSend) async throws -> String {
        var attachments: [ComposerAttachment] = []
        if let image {
            let size = try image.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            attachments = [ComposerAttachment(localURL: image, name: "Paylaşılan görüntü.png", byteCount: Int64(size), isImage: true)]
        }
        request.submitted = true
        let turn = try await request.server.startTurn(threadID: request.threadID, text: text, effort: "low",
                                              executionMode: .readOnly, attachments: attachments)
        try Task.checkCancellation()
        guard pendingSend === request, generation == request.generation else { throw CancellationError() }
        // Legitimate completions may precede the acknowledgement, while delayed
        // notifications from an older turn may arrive in the same interval.
        request.turnID = turn.id
        request.results = [turn.id: request.results[turn.id] ?? TurnResult()]
        request.bufferedTurns = [turn.id]
        // A terminal RPC status does not mean the notification stream has
        // drained. Its ordered turn/completed event follows the final items.
        let deadline = Date().addingTimeInterval(120)
        while request.results[turn.id]?.completed == nil, request.transportFailure == nil, Date() < deadline {
            try Task.checkCancellation()
            guard pendingSend === request, generation == request.generation else { throw CancellationError() }
            try await Task.sleep(nanoseconds: 80_000_000)
        }
        try Task.checkCancellation()
        guard pendingSend === request, generation == request.generation else { throw CancellationError() }
        if let failure = request.transportFailure { throw CompanionFailure(failure) }
        guard let result = request.results[turn.id], let completed = result.completed else {
            await cancelSend(request)
            throw CompanionFailure("Yanıt zaman aşımına uğradı. Mesaj otomatik yeniden gönderilmedi.", requiresReconnect: true)
        }
        guard completed.0 == "completed" else { throw CompanionFailure(completed.1 ?? "Yanıt tamamlanmadı: \(completed.0)") }
        let ordered = result.messageOrder.compactMap { result.messages[$0] }
        let finals = ordered.filter { $0.status == "final_answer" || $0.title == "FINAL ANSWER" }
        let reply = (finals.isEmpty ? Array(ordered.suffix(1)) : finals).map(\.text).joined(separator: "\n\n")
        guard !reply.isEmpty else { throw CompanionFailure("Tur bitti ama okunabilir yanıt gelmedi. Başarı olarak gösterilmedi.") }
        return reply
    }

    private func receive(_ event: CodexServerEvent, token: UUID) {
        guard token == generation else { return }
        if case .transportClosed(let error) = event {
            if let request = pendingSend, request.generation == token {
                request.transportFailure = error
            } else {
                disconnectIdleTransport(error)
            }
            return
        }
        guard let request = pendingSend, request.generation == token else { return }
        switch event {
        case .itemCompleted(let id, let turn, let message) where id == request.threadID:
            guard request.turnID == nil || request.turnID == turn, message.kind == .agent else { return }
            var result = bufferedResult(turn: turn, request: request)
            if result.messages[message.id] == nil { result.messageOrder.append(message.id) }
            result.messages[message.id] = message; request.results[turn] = result
        case .turnCompleted(let id, let turn, let status, let error) where id == request.threadID:
            guard request.turnID == nil || request.turnID == turn else { return }
            var result = bufferedResult(turn: turn, request: request)
            if result.completed == nil { result.completed = (status, error) }
            request.results[turn] = result
        default: break
        }
    }

    private func disconnectIdleTransport(_ error: String) {
        guard let old = client else { return }
        let token = UUID(); generation = token
        client = nil; threadID = nil; busy = true; endEvents()
        // Publish loss immediately, but keep a fence around the old child until
        // cleanup completes. Reopening waits for this task; it cannot replace
        // the old transport while shutdown is still in progress.
        disconnectedCleanup = Task { @MainActor [weak self] in
            await old.setEventHandler(nil)
            await old.shutdown()
            guard let self, self.generation == token else { return }
            self.disconnectedCleanup = nil; self.busy = false
        }
        disconnectionHandler?(error)
    }

    private func bufferedResult(turn: String, request: PendingSend) -> TurnResult {
        if let result = request.results[turn] { return result }
        // RPC acknowledgement is bounded to 30 seconds. Bound stale-turn
        // storage as well, retaining the most recently observed 16 turn IDs.
        if request.turnID == nil, request.bufferedTurns.count >= 16 {
            request.results.removeValue(forKey: request.bufferedTurns.removeFirst())
        }
        request.bufferedTurns.append(turn)
        return TurnResult()
    }

    private func endEvents() {
        eventContinuation?.finish(); eventContinuation = nil
        eventTask?.cancel(); eventTask = nil
    }

    private func cancelSend(_ request: PendingSend) async {
        if let cleanup = request.cleanup { await cleanup.value; return }
        guard pendingSend === request, generation == request.generation else { return }
        generation = UUID(); endEvents(); client = nil; threadID = nil
        // Keep the writer slot reserved until its owned process has stopped.
        let knownTurn = request.turnID
        let cleanup = Task {
            await request.server.setEventHandler(nil)
            if let knownTurn {
                try? await request.server.interruptCompanionTurn(threadID: request.threadID, turnID: knownTurn)
            }
            await request.server.shutdown()
        }
        request.cleanup = cleanup
        await cleanup.value
        if pendingSend === request { pendingSend = nil; busy = false }
    }

    public func stop() async {
        let token = UUID(); generation = token
        let old = client; let request = pendingSend
        let idleCleanup = disconnectedCleanup
        client = nil; threadID = nil; pendingSend = nil; busy = true; endEvents()
        // Only our dedicated child is stopped, never Bavbav's coding workers.
        await idleCleanup?.value
        if let cleanup = request?.cleanup { await cleanup.value }
        else {
            await old?.setEventHandler(nil)
            if let request, let turn = request.turnID {
                try? await old?.interruptCompanionTurn(threadID: request.threadID, turnID: turn)
            }
            await old?.shutdown()
        }
        if generation == token { disconnectedCleanup = nil; busy = false }
    }
}
