import BavbavCore
import Foundation

/// The Codex actor produces ordered events faster than an expensive native
/// layout can consume them. Keep that backlog bounded instead of scheduling a
/// retained main-queue closure for every token. Lifecycle events are barriers.
final class CodexEventInbox: @unchecked Sendable {
    struct Diagnostics: Sendable {
        let queuedEvents: Int
        let queuedBytes: Int
        let peakEvents: Int
        let peakBytes: Int
        let coalescedEvents: Int
        let blockedSubmissions: Int
        let closed: Bool
    }

    private struct Entry {
        let event: CodexServerEvent
        var parts: [String]?
        var deltaBytes: Int
        var bytes: Int

        init(_ event: CodexServerEvent) {
            self.event = event
            switch event {
            case .agentMessageDelta(_, _, _, let delta), .itemTextDelta(_, _, _, _, _, let delta):
                parts = [delta]; deltaBytes = delta.utf8.count
            default: parts = nil; deltaBytes = 0
            }
            bytes = event.inboxBytes
        }

        func canAppend(_ next: CodexServerEvent) -> Bool {
            guard let parts, parts.count < 128 else { return false }
            switch (event, next) {
            case let (.agentMessageDelta(a, b, c, _), .agentMessageDelta(x, y, z, delta)):
                return a == x && b == y && c == z && deltaBytes + delta.utf8.count <= 65_536
            case let (.itemTextDelta(a, b, c, k, t, _), .itemTextDelta(x, y, z, l, u, delta)):
                return a == x && b == y && c == z && k == l && t == u && deltaBytes + delta.utf8.count <= 65_536
            default: return false
            }
        }

        mutating func append(_ next: CodexServerEvent) {
            let delta = next.inboxDelta!
            parts!.append(delta); deltaBytes += delta.utf8.count
            bytes += delta.utf8.count + 64 // Retained fragment storage, even for empty deltas.
        }

        func materialized() -> CodexServerEvent {
            guard let parts, parts.count > 1 else { return event }
            let text = parts.joined()
            switch event {
            case .agentMessageDelta(let thread, let turn, let item, _):
                return .agentMessageDelta(threadID: thread, turnID: turn, itemID: item, delta: text)
            case .itemTextDelta(let thread, let turn, let item, let kind, let title, _):
                return .itemTextDelta(threadID: thread, turnID: turn, itemID: item, kind: kind, title: title, delta: text)
            default: return event
            }
        }
    }

    private let condition = NSCondition()
    private let maximumEvents: Int
    private let maximumBytes: Int
    private let batchSize: Int
    private let deliver: @MainActor @Sendable (CodexServerEvent) -> Void
    private var entries: [Entry] = []
    private var queuedBytes = 0
    private var scheduled = false
    private var closed = false
    private var peakEvents = 0
    private var peakBytes = 0
    private var coalescedEvents = 0
    private var blockedSubmissions = 0

    init(maximumEvents: Int = 128, maximumBytes: Int = 8 * 1_024 * 1_024, batchSize: Int = 32,
         deliver: @escaping @MainActor @Sendable (CodexServerEvent) -> Void) {
        precondition(maximumEvents > 0 && maximumBytes > 0 && batchSize > 0)
        self.maximumEvents = maximumEvents; self.maximumBytes = maximumBytes
        self.batchSize = batchSize; self.deliver = deliver
    }

    @discardableResult
    func submit(_ event: CodexServerEvent) -> Bool {
        // The real producer is the Codex actor. A main-thread caller must never
        // wait for its own drain: consume its bounded preceding batch inline.
        if Thread.isMainThread {
            return MainActor.assumeIsolated { submitOnMain(event) }
        }
        let entry = Entry(event)
        var waited = false
        condition.lock()
        defer { condition.unlock() }
        while !closed {
            if let last = entries.last, last.canAppend(event) {
                let added = event.inboxDelta!.utf8.count + 64
                if queuedBytes + added <= maximumBytes {
                    entries[entries.count - 1].append(event)
                    queuedBytes += added; coalescedEvents += 1; updatePeaks()
                    return true
                }
            }
            // An individual oversized final message is delivered exclusively,
            // never truncated. Other retained events still obey the budget.
            if entries.count < maximumEvents && (entries.isEmpty || queuedBytes + entry.bytes <= maximumBytes) {
                entries.append(entry); queuedBytes += entry.bytes; updatePeaks()
                if !scheduled { scheduled = true; scheduleDrain() }
                return true
            }
            if !waited { blockedSubmissions += 1; waited = true }
            condition.wait()
        }
        return false
    }

    func close() {
        condition.lock()
        closed = true; entries.removeAll(keepingCapacity: false); queuedBytes = 0
        condition.broadcast(); condition.unlock()
    }

    var diagnostics: Diagnostics {
        condition.lock(); defer { condition.unlock() }
        return Diagnostics(queuedEvents: entries.count, queuedBytes: queuedBytes,
                           peakEvents: peakEvents, peakBytes: peakBytes,
                           coalescedEvents: coalescedEvents, blockedSubmissions: blockedSubmissions, closed: closed)
    }

    private func updatePeaks() {
        peakEvents = max(peakEvents, entries.count); peakBytes = max(peakBytes, queuedBytes)
    }

    private func scheduleDrain() {
        DispatchQueue.main.async { [weak self] in self?.drain() }
    }

    @MainActor private func submitOnMain(_ event: CodexServerEvent) -> Bool {
        condition.lock()
        guard !closed else { condition.unlock(); return false }
        let preceding = entries
        entries.removeAll(keepingCapacity: false); queuedBytes = 0
        condition.broadcast(); condition.unlock()
        for entry in preceding { deliver(entry.materialized()) }
        deliver(event)
        return true
    }

    @MainActor private func drain() {
        let start = ProcessInfo.processInfo.systemUptime
        var count = 0
        while count < batchSize && ProcessInfo.processInfo.systemUptime - start < 0.008 {
            condition.lock()
            guard !closed, !entries.isEmpty else {
                scheduled = false; condition.unlock(); return
            }
            let entry = entries.removeFirst(); queuedBytes -= entry.bytes
            condition.broadcast(); condition.unlock()
            deliver(entry.materialized()); count += 1
        }
        condition.lock()
        if closed || entries.isEmpty { scheduled = false }
        else { scheduleDrain() }
        condition.unlock()
    }
}

private extension CodexServerEvent {
    var inboxDelta: String? {
        switch self {
        case .agentMessageDelta(_, _, _, let delta), .itemTextDelta(_, _, _, _, _, let delta): return delta
        default: return nil
        }
    }

    var inboxBytes: Int {
        func size(_ strings: String?...) -> Int { strings.reduce(0) { $0 + ($1?.utf8.count ?? 0) } }
        func message(_ value: CodexMessage) -> Int {
            size(value.id, value.text, value.title, value.status)
                + (value.images ?? []).reduce(0) { $0 + size($1.source, $1.title) + 64 }
        }
        func option(_ value: CodexInteractionOption) -> Int { size(value.id, value.label, value.detail) + 64 }
        let textBytes: Int
        switch self {
        case .turnStarted(let thread, let turn): textBytes = size(thread, turn)
        case .itemStarted(let thread, let turn, let value), .itemCompleted(let thread, let turn, let value):
            textBytes = size(thread, turn) + message(value)
        case .agentMessageDelta(let thread, let turn, let item, let delta): textBytes = size(thread, turn, item, delta)
        case .itemTextDelta(let thread, let turn, let item, _, let title, let delta): textBytes = size(thread, turn, item, title, delta)
        case .turnDiffUpdated(let thread, let turn, let diff): textBytes = size(thread, turn, diff)
        case .turnCompleted(let thread, let turn, let status, let error): textBytes = size(thread, turn, status, error)
        case .interactionRequested(let value):
            textBytes = size(value.id, value.threadID, value.turnID, value.itemID, value.title, value.summary, value.detail, value.defaultOptionID)
                + value.options.reduce(0) { $0 + option($1) }
                + value.questions.reduce(0) { sum, question in
                    sum + size(question.id, question.header, question.prompt) + 128
                        + question.options.reduce(0) { $0 + option($1) }
                }
        case .interactionResolved(let id, let thread): textBytes = size(id.stableID, thread)
        case .warning(let thread, let message): textBytes = size(thread, message)
        case .transportClosed(let message): textBytes = size(message)
        case .rateLimitsUpdated: textBytes = 512
        }
        return 256 + textBytes
    }
}
