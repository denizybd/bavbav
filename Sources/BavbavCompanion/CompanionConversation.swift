import BavbavCore
import Foundation

@MainActor public protocol CompanionConversation: AnyObject {
    func connect() async throws -> String
    func send(text: String, image: URL?) async throws -> String
    func stop() async
}

public struct CompanionFailure: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// One lazy, restricted app-server connection using Bavbav's existing login.
/// Never takes over a coding chat, reads credentials or accesses Companion keys.
@MainActor public final class CodexCompanionConversation: CompanionConversation {
    private var client: CodexAppServer?
    public private(set) var threadID: String?
    private var generation = UUID()
    private var turnID: String?
    private var completed: (String, String?)?
    private var messages: [String: CodexMessage] = [:]
    private var messageOrder: [String] = []
    private var busy = false
    private let directory: URL
    private let ephemeral: Bool

    public init(directory: URL, ephemeral: Bool = false) {
        self.directory = directory; self.ephemeral = ephemeral
    }

    public func connect() async throws -> String {
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
            await server.setEventHandler { [weak self] event in
                Task { @MainActor in self?.receive(event, token: token) }
            }
            if !ephemeral { try? await server.setThreadName(id: thread.id, name: "Companion · Türkçe ses") }
            guard generation == token else { throw CancellationError() }
            busy = false
            return thread.id
        } catch {
            await server.shutdown()
            if generation == token { client = nil; threadID = nil; busy = false }
            throw error
        }
    }

    public func send(text: String, image: URL?) async throws -> String {
        guard let client, let threadID, !busy else { throw CompanionFailure("Önce bağlan; devam eden yanıtın bitmesini bekle.") }
        busy = true; completed = nil; turnID = nil; messages = [:]; messageOrder = []
        let token = generation
        defer { if generation == token { busy = false; turnID = nil } }
        var attachments: [ComposerAttachment] = []
        if let image {
            let size = try image.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            attachments = [ComposerAttachment(localURL: image, name: "Paylaşılan pencere.png", byteCount: Int64(size), isImage: true)]
        }
        let turn = try await client.startTurn(threadID: threadID, text: text, effort: "low",
                                              executionMode: .readOnly, attachments: attachments)
        guard generation == token else { throw CancellationError() }
        // Notifications can beat the RPC acknowledgement; retain their result.
        if let turnID, turnID != turn.id { throw CompanionFailure("Sohbet turu eşleşmedi; yeniden bağlan.") }
        turnID = turn.id
        if turn.status != "inProgress", completed == nil { completed = (turn.status, nil) }
        let deadline = Date().addingTimeInterval(120)
        while completed == nil, Date() < deadline {
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            try await Task.sleep(nanoseconds: 80_000_000)
        }
        guard generation == token else { throw CancellationError() }
        guard let completed else {
            try? await client.interruptCompanionTurn(threadID: threadID, turnID: turn.id)
            throw CompanionFailure("Yanıt zaman aşımına uğradı. Mesaj otomatik yeniden gönderilmedi.")
        }
        guard completed.0 == "completed" else { throw CompanionFailure(completed.1 ?? "Yanıt tamamlanmadı: \(completed.0)") }
        let ordered = messageOrder.compactMap { messages[$0] }
        let finals = ordered.filter { $0.status == "final_answer" || $0.title == "FINAL ANSWER" }
        let reply = (finals.isEmpty ? Array(ordered.suffix(1)) : finals).map(\.text).joined(separator: "\n\n")
        guard !reply.isEmpty else { throw CompanionFailure("Tur bitti ama okunabilir yanıt gelmedi. Başarı olarak gösterilmedi.") }
        return reply
    }

    private func receive(_ event: CodexServerEvent, token: UUID) {
        guard token == generation, busy else { return }
        switch event {
        case .turnStarted(let id, let turn) where id == threadID:
            if turnID == nil { turnID = turn }
        case .itemCompleted(let id, let turn, let message) where id == threadID:
            guard turnID == nil || turnID == turn, message.kind == .agent else { return }
            turnID = turn
            if messages[message.id] == nil { messageOrder.append(message.id) }
            messages[message.id] = message
        case .turnCompleted(let id, let turn, let status, let error) where id == threadID:
            guard turnID == nil || turnID == turn else { return }
            turnID = turn; completed = (status, error)
        case .transportClosed(let error): completed = ("failed", error)
        default: break
        }
    }

    public func stop() async {
        generation = UUID()
        let old = client; let oldThread = threadID; let oldTurn = turnID
        client = nil; threadID = nil; turnID = nil; completed = nil; busy = false
        if let oldThread, let oldTurn { try? await old?.interruptCompanionTurn(threadID: oldThread, turnID: oldTurn) }
        // Only our dedicated child is stopped, never Bavbav's coding workers.
        await old?.setEventHandler(nil)
        await old?.shutdown()
    }
}
