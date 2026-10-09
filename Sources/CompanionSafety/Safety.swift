import Foundation

public protocol GateClock: Sendable {
    var unixMS: Double { get }
    var monotonic: Double { get }
}
public struct SystemGateClock: GateClock {
    public init() {}
    public var unixMS: Double { Date().timeIntervalSince1970 * 1000 }
    public var monotonic: Double { ProcessInfo.processInfo.systemUptime }
}
public enum ActionKind: String, Codable, Sendable { case click, typeText = "type_text", keypress, scroll }
public struct ActionRequest: Codable, Sendable, Equatable {
    public var apiVersion: Int
    public var sessionID: String, taskID: String, actionID: String, frameID: String
    public var epoch: UInt64, expiresAtUnixMS: Double, kind: ActionKind
    public var x: Double?, y: Double?, text: String?, key: String?, deltaX: Double?, deltaY: Double?
    public init(apiVersion: Int = 1, sessionID: String, taskID: String, actionID: String, frameID: String, epoch: UInt64, expiresAtUnixMS: Double, kind: ActionKind, x: Double? = nil, y: Double? = nil, text: String? = nil, key: String? = nil, deltaX: Double? = nil, deltaY: Double? = nil) {
        self.apiVersion = apiVersion; self.sessionID = sessionID; self.taskID = taskID; self.actionID = actionID; self.frameID = frameID
        self.epoch = epoch; self.expiresAtUnixMS = expiresAtUnixMS; self.kind = kind; self.x = x; self.y = y; self.text = text; self.key = key; self.deltaX = deltaX; self.deltaY = deltaY
    }
    enum CodingKeys: String, CodingKey {
        case apiVersion, sessionID = "sessionId", taskID = "taskId", actionID = "actionId", frameID = "frameId", epoch, expiresAtUnixMS = "expiresAtUnixMs", kind, x, y, text, key, deltaX, deltaY
    }
}
public struct ActionOutcome: Codable, Sendable, Equatable {
    public var state: String, errorCode: String?, actionID: String?, dispatchedEvents: Int, verified: Bool
    public init(state: String, errorCode: String? = nil, actionID: String? = nil, dispatchedEvents: Int = 0, verified: Bool = false) {
        self.state = state; self.errorCode = errorCode; self.actionID = actionID; self.dispatchedEvents = dispatchedEvents; self.verified = verified
    }
    enum CodingKeys: String, CodingKey { case state, errorCode, actionID = "actionId", dispatchedEvents, verified }
}
public enum GateDecision: Sendable { case allow, deny(ActionOutcome) }
public struct GateStatus: Codable, Sendable {
    public var sessionID: String, epoch: UInt64, ownerID: String?, taskID: String?, target: TargetSnapshot?
    public var pendingOwnerID: String?, pendingTaskID: String?, leaseRemainingSeconds: Double, queuedActions: Int
    enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId", epoch, ownerID = "ownerId", taskID = "taskId", target, pendingOwnerID = "pendingOwnerId", pendingTaskID = "pendingTaskId", leaseRemainingSeconds, queuedActions
    }
}

/// Single-owner fail-closed executor. All native event posts must run inside
/// withDispatchAuthorization; its lock is also the local stop linearization barrier.
public final class SafetyGate: @unchecked Sendable {
    public let sessionID: String
    public let maxFrameAge: Double, leaseDuration: Double, actionTimeout: Double
    private let clock: any GateClock
    private let lock = NSLock()
    private var epoch: UInt64 = 1
    private var ownerID: String?, taskID: String?, target: TargetSnapshot?
    private var pendingOwnerID: String?, pendingTaskID: String?
    private var leaseDeadline: Double = 0
    private var frames: [String: FrameRecord] = [:]
    private var consumedFrames: Set<String> = []
    private struct Entry { var request: ActionRequest; var ownerID: String; var outcome: ActionOutcome; var deadline: Double }
    private var entries: [String: Entry] = [:]
    private var activeID: String?
    private let maxRecords = 512
    public init(clock: any GateClock = SystemGateClock(), maxFrameAge: Double = 3, leaseDuration: Double = 60, actionTimeout: Double = 2) {
        self.clock = clock; self.sessionID = UUID().uuidString
        self.maxFrameAge = max(0.05, min(maxFrameAge.isFinite ? maxFrameAge : 3, 10))
        self.leaseDuration = max(0.1, min(leaseDuration.isFinite ? leaseDuration : 60, 60))
        self.actionTimeout = max(0.05, min(actionTimeout.isFinite ? actionTimeout : 2, 2))
    }
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    public func status() -> GateStatus { locked {
        _ = expireLocked()
        return GateStatus(sessionID: sessionID, epoch: epoch, ownerID: ownerID, taskID: taskID, target: target, pendingOwnerID: pendingOwnerID, pendingTaskID: pendingTaskID, leaseRemainingSeconds: max(0, leaseDeadline - clock.monotonic), queuedActions: activeID == nil ? 0 : 1)
    } }
    public func proposeTask(ownerID: String, taskID: String) -> ActionOutcome { locked {
        guard validID(ownerID), validID(taskID) else { return reject("INVALID_ID") }
        _ = expireLocked()
        if let current = self.ownerID, current != ownerID { return reject("CONTROL_OWNER_BUSY") }
        // Every new proposal ends the current grant, even if a client reuses
        // its task ID. A task ID is not authority to preserve older frames or
        // queued input across a new instruction and its local approval gate.
        if self.ownerID == ownerID { invalidateLocked(reason: "TASK_REPLACED") }
        pendingOwnerID = ownerID; pendingTaskID = taskID
        return ActionOutcome(state: "accepted")
    } }
    /// Call only from a visible local UI consent action, never expose as an MCP tool.
    public func grantLocalControl(ownerID: String, taskID: String, target: TargetSnapshot) -> ActionOutcome { locked {
        _ = expireLocked()
        guard validID(ownerID), validID(taskID), target.isValid, target.isVisible else { return reject("INVALID_SCOPE") }
        if let current = self.ownerID, current != ownerID { return reject("CONTROL_OWNER_BUSY") }
        // Consent is bound to the proposal displayed in the local UI.
        guard pendingOwnerID == ownerID, pendingTaskID == taskID else { return reject("NO_PENDING_PROPOSAL") }
        invalidateLocked(reason: "LOCAL_GRANT_CHANGED")
        self.ownerID = ownerID; self.taskID = taskID; self.target = target
        leaseDeadline = clock.monotonic + leaseDuration
        pendingOwnerID = nil; pendingTaskID = nil
        return ActionOutcome(state: "accepted")
    } }
    @discardableResult public func addFrame(_ frame: FrameRecord) -> Bool { locked {
        _ = expireLocked()
        guard frame.isValid, frame.sessionID == sessionID, frame.epoch == epoch, target?.matches(frame.target) == true, frame.target.isVisible, frame.target.isFrontmost, ownerID != nil, frame.capturedAtMonotonic <= clock.monotonic, clock.monotonic - frame.capturedAtMonotonic <= maxFrameAge, frames[frame.frameID] == nil, !consumedFrames.contains(frame.frameID) else { return false }
        if frames.count >= 16 { frames.removeAll(); consumedFrames.removeAll() }
        frames[frame.frameID] = frame
        return true
    } }
    public func outcome(actionID: String) -> ActionOutcome? { locked { _ = expireLocked(); return entries[actionID]?.outcome } }
    /// Resolve a known action before trying to inspect a target/frame which may
    /// have disappeared since delivery. Payload and connection identity must match.
    public func replayOutcome(for request: ActionRequest, ownerID: String) -> ActionOutcome? { locked {
        _ = expireLocked()
        guard let entry = entries[request.actionID] else { return nil }
        guard entry.request == request, entry.ownerID == ownerID else { return reject("ACTION_ID_CONFLICT", request) }
        return entry.outcome
    } }
    public func frameRecord(id: String) -> FrameRecord? { locked { _ = expireLocked(); return frames[id] } }
    /// Does not request OS permission or start input. It can invalidate an expired
    /// lease/lost scope, as status/watchdog do; no image should be sent on rejection.
    public func captureAuthorization(ownerID: String, sessionID: String, epoch: UInt64, currentTarget: TargetSnapshot, screenPermission: Bool) -> ActionOutcome? { locked {
        _ = expireLocked()
        guard screenPermission else { invalidateLocked(reason: "PERMISSION_LOST"); return reject("PERMISSION_LOST") }
        guard sessionID == self.sessionID else { return reject("SESSION_MISMATCH") }
        guard epoch == self.epoch else { return reject("EPOCH_MISMATCH") }
        guard self.ownerID == ownerID else { return reject("CONTROL_NOT_GRANTED") }
        guard target?.matches(currentTarget) == true, currentTarget.isVisible, currentTarget.isFrontmost else { invalidateLocked(reason: "TARGET_CHANGED"); return reject("TARGET_CHANGED") }
        return nil
    } }
    public func preflight(_ request: ActionRequest, currentTarget: TargetSnapshot, ownerID: String, screenPermission: Bool, accessibilityPermission: Bool) -> GateDecision { locked {
        if let entry = entries[request.actionID] {
            guard entry.request == request, entry.ownerID == ownerID else { return .deny(reject("ACTION_ID_CONFLICT", request)) }
            _ = expireLocked()
            return .deny(entries[request.actionID]?.outcome ?? entry.outcome)
        }
        if let code = checkLocked(request, currentTarget, ownerID, screenPermission, accessibilityPermission, isDispatch: false) { return .deny(reject(code, request)) }
        guard activeID == nil else { return .deny(reject("QUEUE_FULL", request)) }
        guard !consumedFrames.contains(request.frameID) else { return .deny(reject("FRAME_CONSUMED", request)) }
        let outcome = ActionOutcome(state: "accepted", actionID: request.actionID)
        let deadline = clock.monotonic + min(actionTimeout, (request.expiresAtUnixMS - clock.unixMS) / 1000)
        // A bounded dedup ledger never evicts identities during a live session.
        // Require a fresh process/session rather than let replay produce new events.
        guard entries.count < maxRecords else { return .deny(reject("SESSION_ACTION_BUDGET", request)) }
        entries[request.actionID] = Entry(request: request, ownerID: ownerID, outcome: outcome, deadline: deadline)
        activeID = request.actionID; consumedFrames.insert(request.frameID)
        return .allow
    } }
    /// The callback must post at most one immediate native event; no awaits, sleeps,
    /// AX calls or re-entry to the gate. Stop waits only for this bounded callback.
    /// nil means a native event was sent, not that the application accepted it.
    public func withDispatchAuthorization(_ request: ActionRequest, currentTarget: TargetSnapshot, ownerID: String, screenPermission: Bool, accessibilityPermission: Bool, body: () -> Void) -> ActionOutcome? { locked {
        guard let entry = entries[request.actionID], entry.request == request, entry.ownerID == ownerID, activeID == request.actionID else { return reject("ACTION_NOT_RESERVED", request) }
        if let code = checkLocked(request, currentTarget, ownerID, screenPermission, accessibilityPermission, isDispatch: true) { return reject(code, request) }
        // One click/key/text down+up pair or one wheel event per action.
        guard entry.outcome.dispatchedEvents < (request.kind == .scroll ? 1 : 2) else { return reject("EVENT_BUDGET_EXCEEDED", request) }
        body()
        if var updated = entries[request.actionID] {
            updated.outcome.state = "running"; updated.outcome.dispatchedEvents += 1
            entries[request.actionID] = updated
        }
        return nil
    } }
    public func recordOutcome(_ outcome: ActionOutcome, for request: ActionRequest) { locked {
        guard var entry = entries[request.actionID], entry.request == request, activeID == request.actionID else { return }
        // Event count is server-owned; callers cannot forge a verified result.
        let state = ["completed", "cancelled", "rejected", "unknown"].contains(outcome.state) ? outcome.state : "unknown"
        entry.outcome = ActionOutcome(state: state, errorCode: outcome.errorCode, actionID: request.actionID, dispatchedEvents: entry.outcome.dispatchedEvents, verified: false)
        entries[request.actionID] = entry; activeID = nil
    } }
    @discardableResult public func invalidate(reason: String) -> ActionOutcome { locked {
        invalidateLocked(reason: reason)
        return ActionOutcome(state: "cancelled", errorCode: reason)
    } }
    /// Idempotent visible local stop; never asserts reversal of delivered events.
    @discardableResult public func emergencyStop() -> ActionOutcome { locked {
        if ownerID != nil || activeID != nil || pendingOwnerID != nil || !frames.isEmpty { invalidateLocked(reason: "EMERGENCY_STOP") }
        return ActionOutcome(state: "cancelled", errorCode: "EMERGENCY_STOP")
    } }
    @discardableResult public func watchdog() -> Bool { locked { expireLocked() } }
    private func validID(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 128 && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }
    private func reject(_ code: String, _ request: ActionRequest? = nil) -> ActionOutcome { ActionOutcome(state: "rejected", errorCode: code, actionID: request?.actionID) }
    private func invalidateLocked(reason: String) {
        // No queued command survives epoch rollover. Reaching UInt64.max is fatal
        // to control: a new process/session is needed rather than wraparound.
        if epoch < UInt64.max { epoch += 1 }
        if let activeID, var entry = entries[activeID] { entry.outcome.state = entry.outcome.dispatchedEvents == 0 ? "cancelled" : "unknown"; entry.outcome.errorCode = reason; entries[activeID] = entry }
        activeID = nil; ownerID = nil; taskID = nil; target = nil; leaseDeadline = 0
        pendingOwnerID = nil; pendingTaskID = nil; frames.removeAll(); consumedFrames.removeAll()
    }
    private func expireLocked() -> Bool {
        if ownerID != nil && clock.monotonic >= leaseDeadline { invalidateLocked(reason: "LEASE_EXPIRED"); return true }
        if let activeID, let entry = entries[activeID], clock.monotonic >= entry.deadline { invalidateLocked(reason: "WATCHDOG_EXPIRED"); return true }
        return false
    }
    private func checkLocked(_ request: ActionRequest, _ currentTarget: TargetSnapshot, _ owner: String, _ screen: Bool, _ accessibility: Bool, isDispatch: Bool) -> String? {
        _ = expireLocked()
        guard screen && accessibility else { invalidateLocked(reason: "PERMISSION_LOST"); return "PERMISSION_LOST" }
        guard request.apiVersion == 1, validID(request.actionID), validID(request.taskID), validID(request.frameID) else { return "INVALID_REQUEST" }
        guard request.sessionID == sessionID else { return "SESSION_MISMATCH" }
        guard request.epoch == epoch else { return "EPOCH_MISMATCH" }
        guard self.ownerID == owner, self.taskID == request.taskID else { return "CONTROL_NOT_GRANTED" }
        guard let target, target.matches(currentTarget), currentTarget.isVisible && currentTarget.isFrontmost else { invalidateLocked(reason: "TARGET_CHANGED"); return "TARGET_CHANGED" }
        guard request.expiresAtUnixMS.isFinite, request.expiresAtUnixMS > clock.unixMS, request.expiresAtUnixMS - clock.unixMS <= actionTimeout * 1000 else { return "ACTION_EXPIRED" }
        guard let frame = frames[request.frameID], frame.sessionID == sessionID, frame.epoch == epoch, frame.target == currentTarget else { return "FRAME_UNKNOWN" }
        let age = clock.monotonic - frame.capturedAtMonotonic
        guard age >= 0 && age <= maxFrameAge else { return "FRAME_STALE" }
        if isDispatch {
            guard let entry = entries[request.actionID], clock.monotonic < entry.deadline else { return "ACTION_EXPIRED" }
        }
        switch request.kind {
        case .click:
            guard let x = request.x, let y = request.y, frame.globalPoint(pixel: Point(x:x,y:y)) != nil, request.text == nil, request.key == nil, request.deltaX == nil, request.deltaY == nil else { return "INVALID_CLICK" }
        case .typeText:
            guard let text = request.text, !text.isEmpty, text.utf16.count <= 256, !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), request.x == nil, request.y == nil, request.key == nil, request.deltaX == nil, request.deltaY == nil else { return "INVALID_TEXT" }
        case .keypress:
            guard let key = request.key, ["Tab","Shift+Tab","Escape","Left","Right","Up","Down","Home","End"].contains(key), request.x == nil, request.y == nil, request.text == nil, request.deltaX == nil, request.deltaY == nil else { return "KEY_NOT_ALLOWED" }
        case .scroll:
            guard let dx = request.deltaX, let dy = request.deltaY, dx.isFinite, dy.isFinite, abs(dx) <= 100, abs(dy) <= 100, dx != 0 || dy != 0, request.x == nil, request.y == nil, request.text == nil, request.key == nil else { return "INVALID_SCROLL" }
        }
        return nil
    }
}
