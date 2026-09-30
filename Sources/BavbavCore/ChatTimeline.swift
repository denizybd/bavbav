import Foundation

/// Preserve server timeline order while using reconciled conversation rows for
/// live text and optimistic sends. Filtering never modifies persisted history.
public enum ChatTimeline {
    public static func visible(activity: [CodexMessage], conversation: [CodexMessage],
                               commandsVisible: Bool) -> [CodexMessage] {
        let latest = Dictionary(conversation.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        var seen = Set<String>()
        var result: [CodexMessage] = []
        // Place recovered conversation gaps before their next shared anchor,
        // not after a newer final answer at the bottom of the transcript.
        let ordered = RolloutConversationReader.merge(activity, with: conversation)
        for item in ordered where commandsVisible || item.isChatVisible {
            guard seen.insert(item.id).inserted else { continue }
            result.append(latest[item.id] ?? item)
        }
        return result
    }
}
