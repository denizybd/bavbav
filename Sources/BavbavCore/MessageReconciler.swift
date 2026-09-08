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
