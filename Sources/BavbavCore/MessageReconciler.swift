import Foundation

/// Tracks the temporary message drawn before App Server echoes the same user
/// item back with its persisted id.
public struct OptimisticUserMessage: Equatable, Sendable {
    public var threadID: String
    public let localID: String
    public let text: String
    public var serverID: String?

    public init(threadID: String, localID: String, text: String, serverID: String? = nil) {
        self.threadID = threadID
        self.localID = localID
        self.text = text
        self.serverID = serverID
    }
}

public enum MessageReconciler {
    /// Loaded history supplies the prefix and ordering; protected live rows keep
    /// their exact text. A lagging server projection must not
    /// delete them or replace a final answer with an older partial answer.
    public static func mergeHistory(_ history: [CodexMessage], current: [CodexMessage],
                                    protecting ids: Set<String> = []) -> [CodexMessage] {
        let live = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        let base = history.map { ids.contains($0.id) ? (live[$0.id] ?? $0) : $0 }
        var seen = Set<String>()
        return RolloutConversationReader.merge(base, with: current).filter { seen.insert($0.id).inserted }
    }

    /// Refresh while a send is in flight without dropping its optimistic row
    /// or mistaking an older identical prompt for this submission's echo.
    public static func refreshedHistory(_ history: [CodexMessage], current: [CodexMessage],
                                        threadID: String, pending: inout [OptimisticUserMessage],
                                        protecting ids: Set<String> = []) -> [CodexMessage] {
        var result = history
        var replacedLocalIDs = Set<String>()
        var claimed = Set(pending.compactMap(\.serverID))
        for index in pending.indices where pending[index].threadID == threadID {
            let candidate = pending[index]
            guard let row = current.first(where: { $0.id == candidate.localID || $0.id == candidate.serverID }) else { continue }
            let match = history.first { incoming in
                if incoming.id == candidate.localID || incoming.id == candidate.serverID { return true }
                guard candidate.serverID == nil, !claimed.contains(incoming.id), incoming.role == .user,
                      normalized(incoming.text) == normalized(candidate.text),
                      let sent = row.timestamp, let received = incoming.timestamp else { return false }
                return received >= sent.addingTimeInterval(-1)
            }
            if let match {
                pending[index].serverID = match.id
                claimed.insert(match.id)
                if candidate.localID != match.id { replacedLocalIDs.insert(candidate.localID) }
            } else if !result.contains(where: { $0.id == row.id }) { result.append(row) }
        }
        return mergeHistory(result, current: current.filter { !replacedLocalIDs.contains($0.id) }, protecting: ids)
    }

    /// Queue-aware variant used when an active turn receives one or more steer
    /// messages before it completes. Identity wins; text only matches an echo
    /// that has not received a persisted server id yet.
    @discardableResult
    public static func mergeUserEcho(
        messages: inout [CodexMessage],
        incoming: CodexMessage,
        threadID: String,
        pending: inout [OptimisticUserMessage]
    ) -> Bool {
        guard incoming.role == .user else { return false }

        let identityIndex = pending.firstIndex { candidate in
            candidate.threadID == threadID
                && (incoming.id == candidate.localID || incoming.id == candidate.serverID)
        }
        let matchIndex = identityIndex ?? pending.firstIndex { candidate in
            candidate.threadID == threadID
                && candidate.serverID == nil
                && normalized(incoming.text) == normalized(candidate.text)
        }
        guard let matchIndex else { return false }

        var candidate = pending[matchIndex]
        let correlatedIDs = Set(
            [candidate.localID, candidate.serverID, incoming.id].compactMap { $0 }
        )
        let originalIndex = messages.firstIndex { correlatedIDs.contains($0.id) }
        messages.removeAll { correlatedIDs.contains($0.id) }
        if let originalIndex {
            messages.insert(incoming, at: min(originalIndex, messages.endIndex))
        } else {
            messages.append(incoming)
        }

        candidate.serverID = incoming.id
        pending[matchIndex] = candidate
        return true
    }

    /// Replaces an optimistic user row with the server echo while keeping its
    /// original position. Matching is limited to the one pending submission,
    /// so intentionally sending identical text twice still creates two turns.
    @discardableResult
    public static func mergeUserEcho(
        messages: inout [CodexMessage],
        incoming: CodexMessage,
        threadID: String,
        pending: inout OptimisticUserMessage?
    ) -> Bool {
        var queue = pending.map { [$0] } ?? []
        let matched = mergeUserEcho(
            messages: &messages,
            incoming: incoming,
            threadID: threadID,
            pending: &queue
        )
        pending = queue.first
        return matched
    }

    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
    }
}
