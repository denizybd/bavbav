import Foundation
import CoreGraphics
import BavbavCompanion
import CompanionSafety

private final class DesktopTestClock: GateClock, @unchecked Sendable {
    var unixMS: Double = 100_000
    var monotonic: Double = 100
    func advance(_ seconds: Double) { unixMS += seconds * 1_000; monotonic += seconds }
    var date: Date { Date(timeIntervalSince1970: unixMS / 1_000) }
}

@MainActor private final class DesktopTestCursor: CompanionDesktopCursorDisplaying {
    var points: [CGPoint] = []
    var hides = 0
    func show(at point: CGPoint) { points.append(point) }
    func hide() { hides += 1 }
}

@MainActor private final class DesktopTestExecutor: CompanionDesktopExecuting {
    var windows: [CompanionDesktopWindowSnapshot]
    var current: TargetSnapshot
    var enumerationCount = 0
    var delayEnumeration = false
    var pendingEnumerations: [Int: CheckedContinuation<[CompanionDesktopWindowSnapshot], Error>] = [:]
    var posts = 0
    var releases = 0
    var accessAllowed = true
    var accessRequests = 0
    var delayPrepare = false
    var pendingPrepare: CheckedContinuation<Void, Never>?
    var resolveCount = 0
    var delayResolve = false
    var pendingResolves: [Int: CheckedContinuation<TargetSnapshot, Error>] = [:]
    var afterDown: (() -> Void)?
    init() {
        current = TargetSnapshot(windowID: 42, pid: 1_234, bundleID: "test.ordinary.editor", displayID: 1,
            bounds: Rect(x: 100, y: 100, width: 800, height: 600), displayBounds: Rect(x: 0, y: 0, width: 1_000, height: 800),
            scale: 2, isVisible: true, isFrontmost: true)
        windows = [CompanionDesktopWindowSnapshot(target: current)]
    }
    func prepareControlAccess() -> Bool { accessRequests += 1; return accessAllowed }
    func visibleWindows(in screenshotBounds: CGRect) async throws -> [CompanionDesktopWindowSnapshot] {
        enumerationCount += 1
        if delayEnumeration {
            let attempt = enumerationCount
            return try await withCheckedThrowingContinuation { pendingEnumerations[attempt] = $0 }
        }
        return windows
    }
    func resolveTarget(at point: CGPoint, screenshotBounds: CGRect) async throws -> TargetSnapshot {
        resolveCount += 1
        if delayResolve {
            let attempt = resolveCount
            return try await withCheckedThrowingContinuation { pendingResolves[attempt] = $0 }
        }
        return current
    }
    func prepareTarget(_ target: TargetSnapshot, at point: CGPoint, gate: SafetyGate, epoch: UInt64) async throws -> TargetSnapshot {
        if delayPrepare { await withCheckedContinuation { pendingPrepare = $0 } }
        guard gate.status().epoch == epoch else { throw CancellationError() }
        return current
    }
    func dispatchClick(at point: CGPoint, target: TargetSnapshot, request: ActionRequest,
                       gate: SafetyGate, ownerID: String) async throws -> ActionOutcome {
        switch gate.preflight(request, currentTarget: current, ownerID: ownerID, screenPermission: true, accessibilityPermission: true) {
        case .deny(let result): throw CompanionFailure(result.errorCode ?? "Fixture gate refused")
        case .allow: break
        }
        for i in 0..<2 {
            if let rejected = gate.withDispatchAuthorization(request, currentTarget: current, ownerID: ownerID,
                screenPermission: true, accessibilityPermission: true, body: { posts += 1 }) {
                if i == 1 { releases += 1 }
                throw CompanionFailure(rejected.errorCode ?? "Fixture revoked")
            }
            if i == 0 { afterDown?() }
        }
        let result = ActionOutcome(state: "completed", actionID: request.actionID, dispatchedEvents: 2, verified: false)
        gate.recordOutcome(result, for: request)
        return result
    }
}

/// No native executor, desktop query, cursor window, microphone or live input.
@MainActor enum CompanionDesktopControlChecks {
    private static var assertions = 0
    private static let bounds = CGRect(x: 0, y: 0, width: 1_000, height: 800)
    private static let click = #"{"action":"click","x":0.3,"y":0.25,"explanation":"Play düğmesine tıkla"}"#
    private static func check(_ value: Bool, line: UInt = #line) {
        assertions += 1
        guard value else { fatalError("DESKTOP CONTROL FIXTURE FAILED at line \(line)") }
    }
    private static func rejects(_ operation: () async throws -> Void, line: UInt = #line) async {
        do { try await operation(); check(false, line: line) }
        catch { check(true, line: line) }
    }
    private static func register(_ control: CompanionDesktopControl, clock: DesktopTestClock) async throws {
        let snapshot = try await control.prepareFrameCapture(screenshotBounds: bounds)
        try await control.registerFrame(snapshot: snapshot, capturedAt: clock.date)
    }
    static func run() async -> Int {
        assertions = 0
        do {
            let parsed = try CompanionDesktopClick.parse(click)
            check(parsed.x == 0.3 && parsed.y == 0.25)
            for invalid in ["[]", "```json\n\(click)\n```", "prose \(click)",
                #"{"action":"keypress","x":0.3,"y":0.25,"explanation":"Play"}"#,
                #"{"action":"click","x":true,"y":0.25,"explanation":"Play"}"#,
                #"{"action":"click","x":1,"y":0.25,"explanation":"Play"}"#,
                #"{"action":"click","x":-0.1,"y":0.25,"explanation":"Play"}"#,
                #"{"action":"click","x":0.3,"y":0.25,"explanation":"Play","text":"sudo command"}"#,
                #"{"action":"click","x":0.3,"y":0.25,"explanation":"Satın almayı onayla"}"#,
                #"{"action":"click","x":0.3,"y":0.25,"explanation":"Delete document"}"#] {
                do { _ = try CompanionDesktopClick.parse(invalid); check(false) } catch { check(true) }
            }
            for dangerous in ["Allow", "Şifre", "Sistem Ayarları", "Send", "Checkout", "Delete", "Execute", "Terminal", "Giriş"] {
                check(CompanionDesktopRisk.isRisky(dangerous))
            }
            check(!CompanionDesktopRisk.isRisky("Play düğmesine tıkla"))
            check(CompanionDesktopRisk.isBlockedBundle("com.apple.systempreferences"))

            let clock = DesktopTestClock(); let executor = DesktopTestExecutor(); let cursor = DesktopTestCursor()
            let control = CompanionDesktopControl(executor: executor, cursor: cursor, clock: clock, previewDelayNanoseconds: 0)
            check(!control.enabled && !control.automaticClicks && control.pending == nil)
            await rejects { try await register(control, clock: clock) }
            check(executor.enumerationCount == 0 && executor.posts == 0)
            executor.accessAllowed = false; control.enable()
            check(!control.enabled && !control.automaticClicks && executor.accessRequests == 1)
            check(control.status.contains("izin")); executor.accessAllowed = true
            control.enable()
            try await register(control, clock: clock)
            let proposal = try await control.prepareProposal(response: click, screenshotBounds: bounds, capturedAt: clock.date)
            check(proposal.point == CGPoint(x: 300, y: 200)); check(cursor.points == [proposal.point])
            check(executor.posts == 0 && control.pending?.id == proposal.id)
            let result = try await control.executePending(id: proposal.id)
            check(result.dispatchedEvents == 2 && !result.verified); check(executor.posts == 2)
            check(control.pending == nil && !control.executing)
            await rejects { _ = try await control.executePending(id: proposal.id) }
            check(executor.posts == 2)

            control.enable(automaticClicks: false)
            try await register(control, clock: clock)
            let manual = try await control.prepareProposal(response: click, screenshotBounds: bounds, capturedAt: clock.date)
            await rejects { _ = try await control.executePending(id: manual.id) }
            check(executor.posts == 2)
            _ = try await control.executePending(id: manual.id, userApproved: true)
            check(executor.posts == 4)

            control.enable(scope: .selectedWindow(CompanionWindow(id: 99, pid: 1_234, bundleID: "test.ordinary.editor", label: "Other")))
            try await register(control, clock: clock)
            await rejects { _ = try await control.prepareProposal(response: click, screenshotBounds: bounds, capturedAt: clock.date) }
            check(executor.posts == 4)
            control.enable()
            try await register(control, clock: clock)
            executor.current.bounds.x += 1
            await rejects { _ = try await control.prepareProposal(response: click, screenshotBounds: bounds, capturedAt: clock.date) }
            executor.current.bounds.x -= 1
            await rejects { _ = try await control.prepareProposal(response: click, screenshotBounds: bounds, capturedAt: clock.date.addingTimeInterval(0.1)) }

            control.enable(); try await register(control, clock: clock)
            let stale = try await control.prepareProposal(response: click, screenshotBounds: bounds, capturedAt: clock.date)
            clock.advance(10.1)
            await rejects { _ = try await control.executePending(id: stale.id) }
            check(executor.posts == 4)

            control.enable(); try await register(control, clock: clock)
            let pending = try await control.prepareProposal(response: click, screenshotBounds: bounds, capturedAt: clock.date)
            executor.delayPrepare = true
            let task = Task { try await control.executePending(id: pending.id) }
            while executor.pendingPrepare == nil { await Task.yield() }
            control.stop(); check(!control.enabled && control.pending == nil)
            executor.pendingPrepare?.resume()
            do { _ = try await task.value; check(false) } catch { check(true) }
            check(executor.posts == 4 && !control.executing)
            check(control.status.contains("DURDURULDU"))

            executor.delayPrepare = false
            control.enable(); try await register(control, clock: clock)
            let release = try await control.prepareProposal(response: click, screenshotBounds: bounds, capturedAt: clock.date)
            executor.afterDown = { control.stop() }
            await rejects { _ = try await control.executePending(id: release.id) }
            check(executor.posts == 5 && executor.releases == 1)
            check(!control.enabled && !control.executing)

            executor.afterDown = nil; executor.delayResolve = true
            control.enable(); try await register(control, clock: clock)
            let oldResolve = executor.resolveCount + 1
            let oldProposal = Task { try await control.prepareProposal(response: click, screenshotBounds: bounds, capturedAt: clock.date) }
            while executor.pendingResolves[oldResolve] == nil { await Task.yield() }
            await rejects { _ = try await control.prepareProposal(response: click, screenshotBounds: bounds, capturedAt: clock.date) }
            check(executor.resolveCount == oldResolve && control.pending == nil)
            control.stop()
            control.enable(); try await register(control, clock: clock)
            let newResolve = oldResolve + 1
            let newProposal = Task { try await control.prepareProposal(response: click, screenshotBounds: bounds, capturedAt: clock.date) }
            while executor.pendingResolves[newResolve] == nil { await Task.yield() }
            let replacementStatus = control.status
            executor.pendingResolves.removeValue(forKey: oldResolve)?.resume(returning: executor.current)
            do { _ = try await oldProposal.value; check(false) } catch { check(error is CancellationError) }
            check(control.pending == nil && control.status == replacementStatus)
            // The old defer must not release a newer preparation's slot.
            await rejects { _ = try await control.prepareProposal(response: click, screenshotBounds: bounds, capturedAt: clock.date) }
            check(executor.resolveCount == newResolve)
            executor.pendingResolves.removeValue(forKey: newResolve)?.resume(returning: executor.current)
            let replacement = try await newProposal.value
            check(control.pending?.id == replacement.id && control.enabled)
            executor.delayResolve = false
            let replacementOutcome = try await control.executePending(id: replacement.id)
            check(replacementOutcome.dispatchedEvents == 2 && executor.posts == 7)

            // The geometry must bracket the screenshot, not merely be sampled
            // after it. These fixtures simulate changes during pixel capture.
            let captureClock = DesktopTestClock(); let captureExecutor = DesktopTestExecutor()
            let captureCursor = DesktopTestCursor()
            let captureControl = CompanionDesktopControl(executor: captureExecutor, cursor: captureCursor,
                clock: captureClock, previewDelayNanoseconds: 0)
            let original = captureExecutor.current
            var underneath = original; underneath.windowID = 43; underneath.pid = 5_678
            underneath.bundleID = "test.ordinary.viewer"; underneath.isFrontmost = false
            let ordered = [CompanionDesktopWindowSnapshot(target: original), CompanionDesktopWindowSnapshot(target: underneath)]
            captureExecutor.windows = ordered; captureControl.enable()
            let unchanged = try await captureControl.prepareFrameCapture(screenshotBounds: bounds)
            try await captureControl.registerFrame(snapshot: unchanged, capturedAt: captureClock.date)
            check(captureExecutor.enumerationCount == 2 && captureExecutor.posts == 0)
            await rejects { try await captureControl.registerFrame(snapshot: unchanged, capturedAt: captureClock.date) }
            let unchangedProposal = try await captureControl.prepareProposal(response: click, screenshotBounds: bounds, capturedAt: captureClock.date)
            check(unchangedProposal.target.windowID == original.windowID)

            let moved = try await captureControl.prepareFrameCapture(screenshotBounds: bounds)
            var movedTarget = original; movedTarget.bounds.x += 1
            captureExecutor.windows[0] = CompanionDesktopWindowSnapshot(target: movedTarget)
            await rejects { try await captureControl.registerFrame(snapshot: moved, capturedAt: captureClock.date) }
            await rejects { _ = try await captureControl.prepareProposal(response: click, screenshotBounds: bounds, capturedAt: captureClock.date) }
            check(captureControl.pending == nil && captureExecutor.posts == 0)

            captureExecutor.windows = ordered
            let covered = try await captureControl.prepareFrameCapture(screenshotBounds: bounds)
            captureExecutor.windows = Array(ordered.reversed())
            await rejects { try await captureControl.registerFrame(snapshot: covered, capturedAt: captureClock.date) }
            check(captureControl.pending == nil && captureCursor.points.count == 1 && captureExecutor.posts == 0)

            captureExecutor.windows = ordered
            let replacedCapture = try await captureControl.prepareFrameCapture(screenshotBounds: bounds)
            var impostor = original; impostor.windowID = 55; impostor.pid = 7_890; impostor.bundleID = "test.ordinary.other"
            captureExecutor.windows[0] = CompanionDesktopWindowSnapshot(target: impostor)
            await rejects { try await captureControl.registerFrame(snapshot: replacedCapture, capturedAt: captureClock.date) }
            check(captureExecutor.posts == 0)

            captureExecutor.windows = ordered
            let changedDisplay = try await captureControl.prepareFrameCapture(screenshotBounds: bounds)
            var changedDisplayTarget = original; changedDisplayTarget.displayBounds.width += 1
            captureExecutor.windows[0] = CompanionDesktopWindowSnapshot(target: changedDisplayTarget)
            await rejects { try await captureControl.registerFrame(snapshot: changedDisplay, capturedAt: captureClock.date) }

            captureExecutor.windows = ordered
            let stoppedBeforeCapture = try await captureControl.prepareFrameCapture(screenshotBounds: bounds)
            captureControl.stop(); captureControl.enable()
            let enumerationBeforeRejectedToken = captureExecutor.enumerationCount
            await rejects { try await captureControl.registerFrame(snapshot: stoppedBeforeCapture, capturedAt: captureClock.date) }
            check(captureExecutor.enumerationCount == enumerationBeforeRejectedToken && captureExecutor.posts == 0)

            let oldCapture = try await captureControl.prepareFrameCapture(screenshotBounds: bounds)
            let newerCapture = try await captureControl.prepareFrameCapture(screenshotBounds: bounds)
            await rejects { try await captureControl.registerFrame(snapshot: oldCapture, capturedAt: captureClock.date) }
            try await captureControl.registerFrame(snapshot: newerCapture, capturedAt: captureClock.date)
            check(captureExecutor.posts == 0)

            let staleCapture = try await captureControl.prepareFrameCapture(screenshotBounds: bounds)
            captureClock.advance(10.1)
            await rejects { try await captureControl.registerFrame(snapshot: staleCapture, capturedAt: captureClock.date) }

            let reverseTimeCapture = try await captureControl.prepareFrameCapture(screenshotBounds: bounds)
            await rejects { try await captureControl.registerFrame(snapshot: reverseTimeCapture, capturedAt: captureClock.date.addingTimeInterval(-1)) }

            // STOP during post-capture enumeration must not let a late result
            // register over a newly enabled control session's own capture.
            let interrupted = try await captureControl.prepareFrameCapture(screenshotBounds: bounds)
            captureExecutor.delayEnumeration = true
            let interruptedEnumeration = captureExecutor.enumerationCount + 1
            let interruptedRegister = Task { try await captureControl.registerFrame(snapshot: interrupted, capturedAt: captureClock.date) }
            while captureExecutor.pendingEnumerations[interruptedEnumeration] == nil { await Task.yield() }
            await rejects { try await captureControl.registerFrame(snapshot: interrupted, capturedAt: captureClock.date) }
            captureControl.stop(); captureControl.enable(); captureExecutor.delayEnumeration = false
            let afterStop = try await captureControl.prepareFrameCapture(screenshotBounds: bounds)
            try await captureControl.registerFrame(snapshot: afterStop, capturedAt: captureClock.date)
            captureExecutor.pendingEnumerations.removeValue(forKey: interruptedEnumeration)?.resume(returning: ordered)
            do { try await interruptedRegister.value; check(false) } catch { check(error is CancellationError) }
            let afterStopProposal = try await captureControl.prepareProposal(response: click, screenshotBounds: bounds, capturedAt: captureClock.date)
            check(captureControl.enabled && captureControl.pending?.id == afterStopProposal.id && captureExecutor.posts == 0)

            // Likewise, STOP while the pre-capture query is pending revokes it
            // before any capture token can be returned to its caller.
            captureExecutor.delayEnumeration = true
            let interruptedPreparation = captureExecutor.enumerationCount + 1
            let pendingPreparation = Task { try await captureControl.prepareFrameCapture(screenshotBounds: bounds) }
            while captureExecutor.pendingEnumerations[interruptedPreparation] == nil { await Task.yield() }
            captureControl.stop()
            captureExecutor.pendingEnumerations.removeValue(forKey: interruptedPreparation)?.resume(returning: ordered)
            do { _ = try await pendingPreparation.value; check(false) } catch { check(error is CancellationError) }
            check(!captureControl.enabled && captureControl.pending == nil && captureExecutor.posts == 0)
        } catch { fatalError("DESKTOP CONTROL FIXTURE unexpected failure: \(error)") }
        print("DESKTOP CONTROL CHECKS PASSED: \(assertions) assertions; no native input or desktop queries")
        return assertions
    }
}
