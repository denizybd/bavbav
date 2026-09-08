import Foundation

/// Preserve server timeline order while using reconciled conversation rows for
/// live text and optimistic sends. Filtering never modifies persisted history.
public enum ChatTimeline {
    public static func visible(activity: [CodexMessage], conversation: [CodexMessage],
                               commandsVisible: Bool) -> [CodexMessage] {
        let latest = Dictionary(conversation.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        var seen = Set<String>()
        var result: [CodexMessage] = []
        for item in activity where commandsVisible || item.kind.isChatVisible {
            guard seen.insert(item.id).inserted else { continue }
            result.append(latest[item.id] ?? item)
        }
        for item in conversation where seen.insert(item.id).inserted { result.append(item) }
        return result
    }
}
