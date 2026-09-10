import Foundation

/// Compatibility fallback for app-server projections that stop advancing.
/// Reads only persisted public conversation items, never private reasoning or
/// tool output. Independent actor keeps file IO/JSON decoding off the UI actor.
public actor RolloutConversationReader {
    private struct Entry {
        var offset: UInt64 = 0
        var pending = Data()
        var discarding = false
        var messages: [CodexMessage] = []
        var bytes = 0
        var modified: Date?
        var inode: UInt64?
    }
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    public init() {}

    public func read(path: String, threadID: String) throws -> [CodexMessage] {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { return [] }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = attributes[.modificationDate] as? Date
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        let key = threadID + ":" + path
        var entry = entries[key] ?? Entry()
        if size < entry.offset || (entry.offset > 0 && inode != entry.inode)
            || (size == entry.offset && modified != entry.modified) { entry = Entry() }
        if size > entry.offset {
            let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? file.close() }
            try file.seek(toOffset: entry.offset)
            while entry.offset < size {
                try Task.checkCancellation()
                let chunk = try file.read(upToCount: Int(min(262_144, size - entry.offset))) ?? Data()
                guard !chunk.isEmpty else { break }
                entry.offset += UInt64(chunk.count)
                for part in chunk.split(separator: 10, omittingEmptySubsequences: false).enumerated() {
                    if part.offset > 0 {
                        if !entry.discarding, let message = Self.parse(entry.pending, threadID: threadID) {
                            if let old = entry.messages.firstIndex(where: { $0.id == message.id }) {
                                entry.bytes -= entry.messages[old].text.utf8.count
                                entry.messages[old] = message
                            } else { entry.messages.append(message) }
                            entry.bytes += message.text.utf8.count
                            while entry.messages.count > 2_000 || entry.bytes > 8 * 1_024 * 1_024 {
                                entry.bytes -= entry.messages.removeFirst().text.utf8.count
                            }
                        }
                        entry.pending.removeAll(keepingCapacity: false)
                        entry.discarding = false
                    }
                    if !entry.discarding {
                        if entry.pending.count + part.element.count > 8 * 1_024 * 1_024 {
                            entry.pending.removeAll(keepingCapacity: false)
                            entry.discarding = true
                        } else { entry.pending.append(contentsOf: part.element) }
                    }
                }
            }
        }
        entry.modified = modified
        entry.inode = inode
        entries[key] = entry
        order.removeAll { $0 == key }; order.append(key)
        while order.count > 2 { entries.removeValue(forKey: order.removeFirst()) }
        return entry.messages
    }

    private static func parse(_ line: Data, threadID: String) -> CodexMessage? {
        // Only explicitly public completed messages can enter the UI cache.
        guard let row = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              row["type"] as? String == "event_msg",
              let payload = row["payload"] as? [String: Any],
              payload["type"] as? String == "item_completed",
              payload["thread_id"] as? String == threadID,
              let item = payload["item"] as? [String: Any],
              let id = item["id"] as? String,
              let type = item["type"] as? String,
              ["UserMessage", "AgentMessage"].contains(type) else { return nil }
        guard (item["phase"] as? String)?.lowercased() != "analysis" else { return nil }
        let content = item["content"] as? [[String: Any]] ?? []
        let text = content.compactMap { part -> String? in
            guard ["Text", "text"].contains(part["type"] as? String ?? "") else { return nil }
            return part["text"] as? String
        }.joined(separator: "\n")
        guard !text.isEmpty, text.utf8.count <= 1_024 * 1_024 else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = (row["timestamp"] as? String).flatMap { formatter.date(from: $0) }
        return CodexMessage(id: id, role: type == "UserMessage" ? .user : .agent,
                            text: text, status: item["phase"] as? String, timestamp: timestamp)
    }

    public static func merge(_ indexed: [CodexMessage], with persisted: [CodexMessage]) -> [CodexMessage] {
        var seen = Set(indexed.map(\.id))
        var result = indexed
        var missing: [CodexMessage] = []
        for message in persisted {
            if seen.contains(message.id) {
                if !missing.isEmpty, let anchor = result.firstIndex(where: { $0.id == message.id }) {
                    result.insert(contentsOf: missing, at: anchor)
                    missing.removeAll(keepingCapacity: true)
                }
            } else {
                seen.insert(message.id)
                missing.append(message)
            }
        }
        result.append(contentsOf: missing)
        return result
    }
}
