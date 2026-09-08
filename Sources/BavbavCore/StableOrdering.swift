import Foundation

public enum StableOrdering {
    public static func reconcile<T: Identifiable>(
        _ items: [T],
        preferredIDs: [T.ID]
    ) -> [T] where T.ID: Hashable {
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let known = preferredIDs.compactMap { byID[$0] }
        let knownIDs = Set(known.map(\.id))
        return known + items.filter { !knownIDs.contains($0.id) }
    }

    public static func moved<T>(_ items: [T], from index: Int, delta: Int) -> (items: [T], index: Int) {
        guard items.indices.contains(index), !items.isEmpty else { return (items, index) }
        let destination = max(0, min(items.count - 1, index + delta))
        guard destination != index else { return (items, index) }

        var copy = items
        let item = copy.remove(at: index)
        copy.insert(item, at: destination)
        return (copy, destination)
    }
}

public enum ListInteractionOutput: Equatable {
    case none
    case activate(String)
    case enteredReorder(String)
    case committed
    case cancelled
}

public struct ListInteractionState: Equatable {
    public enum Mode: Equatable {
        case browsing
        case pressing(String)
        case reordering(itemID: String, originalIDs: [String])
    }

    public var selectedID: String?
    public var mode: Mode = .browsing

    public init(selectedID: String? = nil) {
        self.selectedID = selectedID
    }

    public mutating func beginSpace(visibleIDs: [String]) -> ListInteractionOutput {
        guard let selectedID, visibleIDs.contains(selectedID) else { return .none }
        if case .reordering = mode {
            mode = .browsing
            return .committed
        }
        mode = .pressing(selectedID)
        return .none
    }

    public mutating func crossLongPressThreshold(visibleIDs: [String]) -> ListInteractionOutput {
        guard case .pressing(let id) = mode, visibleIDs.contains(id) else { return .none }
        mode = .reordering(itemID: id, originalIDs: visibleIDs)
        return .enteredReorder(id)
    }

    public mutating func releaseSpace() -> ListInteractionOutput {
        guard case .pressing(let id) = mode else { return .none }
        mode = .browsing
        return .activate(id)
    }

    public mutating func cancel() -> ListInteractionOutput {
        guard case .reordering = mode else {
            mode = .browsing
            return .none
        }
        mode = .browsing
        return .cancelled
    }

    public var isReordering: Bool {
        if case .reordering = mode { return true }
        return false
    }

    public var originalIDs: [String]? {
        if case .reordering(_, let ids) = mode { return ids }
        return nil
    }
}
