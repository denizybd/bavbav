import Foundation
import BavbavOffline
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private enum CheckFailure: Error { case failed(String) }

private final class Checks {
    var count = 0
    func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw CheckFailure.failed(message) }
        count += 1
    }
    func rejects(_ message: String, _ body: () throws -> Void) throws {
        do { try body() }
        catch { count += 1; return }
        throw CheckFailure.failed(message)
    }
}

private actor ReceiptWorker: OfflineWorker {
    enum Mode: Sendable { case normal, tooManyReceipts, oversizedResult, collision, network, partialNetwork }
    let repository: OfflineRepository
    let mode: Mode
    private(set) var calls = 0
    private(set) var durableReceipts = 0
    private(set) var receivedCheckpoints: [OfflineProgressReceipt] = []
    init(repository: OfflineRepository, mode: Mode = .normal) { self.repository = repository; self.mode = mode }
    func run(request: OfflineWorkRequest,
             progress: @escaping @Sendable (OfflineProgressReceipt) async throws -> Void) async throws -> OfflineWorkResult {
        calls += 1
        receivedCheckpoints = request.checkpointReceipts
        if mode == .network { throw OfflineError.networkUnavailable("local runtime unavailable") }
        for index in 0..<(mode == .tooManyReceipts ? 3 : 2) {
            let receipt = OfflineProgressReceipt(id: "\(request.id)-receipt-\(mode == .collision ? 0 : index)",
                                                 kind: "test.read", summary: "Fixture step \(index)")
            try await progress(receipt)
            guard try repository.load().first(where: { $0.id == request.id })?.receipts.contains(receipt) == true else {
                throw CheckFailure.failed("Progress returned before its durable checkpoint")
            }
            durableReceipts += 1
        }
        return OfflineWorkResult(summary: "Local fixture completed", output: mode == .oversizedResult
                                 ? String(repeating: "x", count: request.limits.maxOutputCharacters + 1) : "Read-only proposal",
                                 disposition: mode == .partialNetwork ? .waitingForNetwork : .completed)
    }
}

/// Intentionally ignores cancellation until explicitly released; proves late callbacks are fenced.
private actor GateWorker: OfflineWorker {
    private(set) var calls = 0
    private(set) var lateReceiptBlocked = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func run(request: OfflineWorkRequest,
             progress: @escaping @Sendable (OfflineProgressReceipt) async throws -> Void) async throws -> OfflineWorkResult {
        calls += 1
        if !released { await withCheckedContinuation { waiter = $0 } }
        do { try await progress(.init(kind: "test.late", summary: "Late callback")) }
        catch { lateReceiptBlocked = true }
        return .init(summary: "late completion", output: "must not replace cancelled/paused state")
    }
    func waitUntilStarted() async throws {
        for _ in 0..<300 {
            if calls > 0 { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CheckFailure.failed("Fixture worker did not start")
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

@main
struct BavbavOfflineChecks {
    static func main() async {
        setbuf(stdout, nil)
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("OFFLINE CHECK FAILED: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func run() async throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--probe-lease" {
            do {
                _ = try OfflineRepository(rootURL: URL(fileURLWithPath: CommandLine.arguments[2]))
                print("LEASE_NOT_BLOCKED")
                exit(2)
            } catch OfflineError.repositoryBusy(_) { print("LEASE_BLOCKED"); return }
        }
        if CommandLine.arguments.contains("--live") {
            try await OfflineLiveCheck.run()
            return
        }
        let checks = Checks()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bavbav-offline-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func request(_ key: String, cloud: OfflineCloudDisposition = .notSubmitted,
                     limits: OfflineLimits = .init()) -> OfflineWorkRequest {
            .init(deduplicationKey: key, sourceThreadID: "fixture-thread", workspacePath: root.path,
                  objective: "Inspect fixture files and propose a change", context: [.init(role: "user", text: "fixture context")],
                  cloudDisposition: cloud, limits: limits)
        }

        let repository = try OfflineRepository(rootURL: root.appendingPathComponent("main"))
        try checks.rejects("A second repository must not obtain the same process lease") {
            _ = try OfflineRepository(rootURL: repository.rootURL)
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        child.arguments = ["--probe-lease", repository.rootURL.path]
        let pipe = Pipe(); child.standardOutput = pipe; child.standardError = pipe
        try child.run(); child.waitUntilExit()
        let childOutput = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        try checks.expect(child.terminationStatus == 0 && childOutput.contains("LEASE_BLOCKED"), "Cross-process lease was not exclusive")

        let worker = ReceiptWorker(repository: repository)
        let coordinator = try OfflineCoordinator(repository: repository, worker: worker)
        try checks.rejects("Two coordinators shared one repository lease") {
            _ = try OfflineCoordinator(repository: repository, worker: worker)
        }
        let first = request("first")
        let enqueued = try await coordinator.enqueue(first)
        try checks.expect(enqueued.phase == .queued, "New work must queue")
        var duplicate = first; duplicate.id = UUID().uuidString
        let duplicateRecord = try await coordinator.enqueue(duplicate)
        try checks.expect(duplicateRecord.id == first.id, "Deduplication must preserve a stable task ID")
        var reusedID = first; reusedID.deduplicationKey = "different-key-same-id"
        do { _ = try await coordinator.enqueue(reusedID); throw CheckFailure.failed("Task identity reused by different work") }
        catch is OfflineError { checks.count += 1 }
        duplicate.objective = "Different operation"
        do { _ = try await coordinator.enqueue(duplicate); throw CheckFailure.failed("Different work reused a deduplication key") }
        catch is OfflineError { checks.count += 1 }
        let completed = try await coordinator.runNext()
        try checks.expect(completed?.phase == .completed && completed?.receipts.count == 2, "Work did not durably complete")
        let durabilityCount = await worker.durableReceipts
        try checks.expect(durabilityCount == 2, "A receipt was not durably committed before next action")
        let taskCount = await coordinator.tasks().count
        let workerCalls = await worker.calls
        try checks.expect(taskCount == 1 && workerCalls == 1, "Duplicate request executed twice")
        let idle = try await coordinator.runNext()
        try checks.expect(idle == nil, "Completed work was replayed")

        let report = try await coordinator.prepareHandoff(id: first.id)
        let sameReport = try await coordinator.prepareHandoff(id: first.id)
        try checks.expect(report.id == sameReport.id && report.text.contains(first.id), "Handoff was not durable/idempotent")
        let beforeAccept = await coordinator.task(id: first.id)
        try checks.expect(beforeAccept?.phase == .completed, "Preparing a report must not count as accepting/sending it")
        do { _ = try await coordinator.acceptHandoff(id: first.id, reportID: "wrong"); throw CheckFailure.failed("Wrong handoff was accepted") }
        catch is OfflineError { checks.count += 1 }
        _ = try await coordinator.acceptHandoff(id: first.id, reportID: report.id)
        let accepted = try await coordinator.acceptHandoff(id: first.id, reportID: report.id)
        try checks.expect(accepted.phase == .handedBack && accepted.handoffAcceptedAt != nil, "Accepted handoff did not persist")
        let loaded = try repository.load()
        try checks.expect(loaded.first?.handoff == report && loaded.first?.phase == .handedBack, "Report changed after disk roundtrip")
        let rootMode = try FileManager.default.attributesOfItem(atPath: repository.rootURL.path)[.posixPermissions] as? NSNumber
        let fileMode = try FileManager.default.attributesOfItem(atPath: repository.rootURL.appendingPathComponent("tasks.json").path)[.posixPermissions] as? NSNumber
        try checks.expect(rootMode?.intValue == 0o700 && fileMode?.intValue == 0o600, "Task context is not private on disk")

        let unknown = request("unknown", cloud: .outcomeUnknown)
        let unknownRecord = try await coordinator.enqueue(unknown)
        try checks.expect(unknownRecord.phase == .awaitingCloudResolution, "Uncertain cloud attempt was queued unsafely")
        let noUnknownExecution = try await coordinator.runNext()
        let afterUnknownCalls = await worker.calls
        try checks.expect(noUnknownExecution == nil && afterUnknownCalls == 1, "Cloud outcome unknown was auto-executed")
        _ = try await coordinator.resolveCloud(id: unknown.id, disposition: .confirmedStopped)
        let resolved = try await coordinator.runNext()
        try checks.expect(resolved?.phase == .completed, "Explicitly reconciled cloud work could not execute")

        let intentRepo = try OfflineRepository(rootURL: root.appendingPathComponent("cloud-intents"))
        let intentWorker = ReceiptWorker(repository: intentRepo)
        var monitor: OfflineCoordinator? = try OfflineCoordinator(repository: intentRepo, worker: intentWorker)
        var firstIntent = request("cloud-intent-first", cloud: .outcomeUnknown)
        firstIntent.id = "cloud-intent-" + UUID().uuidString
        var otherIntent = request("cloud-intent-other", cloud: .outcomeUnknown)
        otherIntent.id = "cloud-intent-" + UUID().uuidString
        var manualUnknown = request("manual-unknown", cloud: .outcomeUnknown)
        manualUnknown.sourceTurnID = "turn-a"
        _ = try await monitor!.enqueue(firstIntent)
        _ = try await monitor!.enqueue(otherIntent)
        _ = try await monitor!.enqueue(manualUnknown)
        _ = try await monitor!.bindCloudTurn(id: firstIntent.id, sourceThreadID: "fixture-thread", turnID: "turn-a")
        _ = try await monitor!.bindCloudTurn(id: firstIntent.id, sourceThreadID: "fixture-thread", turnID: "turn-a")
        _ = try await monitor!.bindCloudTurn(id: otherIntent.id, sourceThreadID: "fixture-thread", turnID: "turn-b")
        do {
            _ = try await monitor!.bindCloudTurn(id: firstIntent.id, sourceThreadID: "fixture-thread", turnID: "different-turn")
            throw CheckFailure.failed("A bound cloud intent was reassigned to another turn")
        } catch is OfflineError { checks.count += 1 }
        do {
            _ = try await monitor!.bindCloudTurn(id: manualUnknown.id, sourceThreadID: "fixture-thread", turnID: "turn-a")
            throw CheckFailure.failed("Non-monitoring task was rebound by cloud event")
        } catch is OfflineError { checks.count += 1 }
        let wrongTurn = try await monitor!.reconcileCloudTurn(sourceThreadID: "fixture-thread", turnID: "turn-never-submitted", succeeded: true)
        let afterWrongTurn = await monitor!.tasks()
        try checks.expect(wrongTurn.isEmpty && afterWrongTurn.count == 3, "Wrong turn changed another intent")
        monitor = nil
        let restartedMonitor = try OfflineCoordinator(repository: intentRepo, worker: intentWorker)
        let durableBinding = await restartedMonitor.task(id: firstIntent.id)
        try checks.expect(durableBinding?.request.sourceTurnID == "turn-a" && durableBinding?.phase == .awaitingCloudResolution,
                          "Restart lost exact cloud turn binding")
        let failedIntents = try await restartedMonitor.reconcileCloudTurn(sourceThreadID: "fixture-thread", turnID: "turn-a", succeeded: false)
        try checks.expect(failedIntents.count == 1 && failedIntents.first?.phase == .paused
                          && failedIntents.first?.request.cloudDisposition == .confirmedStopped,
                          "Confirmed cloud failure did not produce a paused, explicit-resume checkpoint")
        let noFailedIntentReplay = try await restartedMonitor.runNext()
        let intentWorkerCalls = await intentWorker.calls
        try checks.expect(noFailedIntentReplay == nil && intentWorkerCalls == 0, "Confirmed cloud failure auto-executed without host/user decision")
        _ = try await restartedMonitor.reconcileCloudTurn(sourceThreadID: "fixture-thread", turnID: "turn-b", succeeded: true)
        let removedMonitor = await restartedMonitor.task(id: otherIntent.id)
        let preservedManual = await restartedMonitor.task(id: manualUnknown.id)
        let preservedPaused = await restartedMonitor.task(id: firstIntent.id)
        try checks.expect(removedMonitor == nil && preservedManual?.phase == .awaitingCloudResolution && preservedPaused?.phase == .paused,
                          "Successful cloud checkpoint pruning removed unrelated or local-ready work")
        _ = try await restartedMonitor.resume(id: firstIntent.id)
        _ = try await restartedMonitor.runNext()
        _ = try await restartedMonitor.reconcileCloudTurn(sourceThreadID: "fixture-thread", turnID: "turn-a", succeeded: true)
        let completedLocalIntent = await restartedMonitor.task(id: firstIntent.id)
        try checks.expect(completedLocalIntent?.phase == .completed, "Late cloud success removed an already-local task")
        var forkIntent = request("cloud-intent-fork", cloud: .outcomeUnknown)
        forkIntent.id = "cloud-intent-" + UUID().uuidString
        _ = try await restartedMonitor.enqueue(forkIntent)
        let retargeted = try await restartedMonitor.retargetUnboundCloudIntent(id: forkIntent.id, sourceThreadID: "actual-fork", workspacePath: root.path)
        let retargetAgain = try await restartedMonitor.retargetUnboundCloudIntent(id: forkIntent.id, sourceThreadID: "actual-fork", workspacePath: root.path)
        try checks.expect(retargeted == retargetAgain && retargeted.request.sourceThreadID == "actual-fork",
                          "Unbound fork checkpoint was not retargeted durably/idempotently")
        let savedFork = try intentRepo.load().first { $0.id == forkIntent.id }
        try checks.expect(savedFork?.request.sourceThreadID == "actual-fork" && savedFork?.request.sourceTurnID == nil,
                          "Fork destination was not durable before the turn RPC acknowledgement")
        do {
            _ = try await restartedMonitor.retargetUnboundCloudIntent(id: forkIntent.id, sourceThreadID: "bad-fork", workspacePath: "relative/path")
            throw CheckFailure.failed("Invalid fork workspace persisted")
        } catch is OfflineError { checks.count += 1 }
        _ = try await restartedMonitor.bindCloudTurn(id: forkIntent.id, sourceThreadID: "actual-fork", turnID: "fork-turn")
        do {
            _ = try await restartedMonitor.retargetUnboundCloudIntent(id: forkIntent.id, sourceThreadID: "wrong-fork", workspacePath: root.path)
            throw CheckFailure.failed("Bound turn was retargeted")
        } catch is OfflineError { checks.count += 1 }
        _ = try await restartedMonitor.reconcileCloudTurn(sourceThreadID: "fixture-thread", turnID: "fork-turn", succeeded: true)
        let beforeExactForkEvent = await restartedMonitor.task(id: forkIntent.id)
        try checks.expect(beforeExactForkEvent != nil, "Original-thread event pruned the fork checkpoint")
        _ = try await restartedMonitor.reconcileCloudTurn(sourceThreadID: "actual-fork", turnID: "fork-turn", succeeded: true)
        let afterExactForkEvent = await restartedMonitor.task(id: forkIntent.id)
        try checks.expect(afterExactForkEvent == nil, "Actual fork turn could not reconcile its checkpoint")

        var invalid = request("invalid")
        invalid.limits.maxSteps = 33
        try checks.rejects("Excessive step limit accepted") { try invalid.validate() }
        invalid = request("invalid2"); invalid.limits.maxDurationSeconds = .infinity
        try checks.rejects("Nonfinite deadline accepted") { try invalid.validate() }
        invalid = request("invalid3"); invalid.objective = String(repeating: "x", count: 12_001)
        try checks.rejects("Excessive objective accepted") { try invalid.validate() }
        invalid = request("invalid4"); invalid.context = [.init(role: "user", text: String(repeating: "x", count: 32_001))]
        try checks.rejects("Excessive context accepted") { try invalid.validate() }
        invalid = request("invalid5"); invalid.attachments = Array(repeating: "/fixture", count: 9)
        try checks.rejects("Excessive attachments accepted") { try invalid.validate() }
        invalid = request("invalid6"); invalid.workspacePath = "relative/path"
        try checks.rejects("Relative workspace accepted") { try invalid.validate() }

        let capacityRepo = try OfflineRepository(rootURL: root.appendingPathComponent("capacity"), maxTasks: 2)
        let capacity = try OfflineCoordinator(repository: capacityRepo, worker: ReceiptWorker(repository: capacityRepo))
        _ = try await capacity.enqueue(request("capacity1")); _ = try await capacity.enqueue(request("capacity2"))
        do { _ = try await capacity.enqueue(request("capacity3")); throw CheckFailure.failed("Unbounded task count") }
        catch is OfflineError { checks.count += 1 }

        let recoveryRepo = try OfflineRepository(rootURL: root.appendingPathComponent("recovery"))
        var interrupted = OfflineTaskRecord(request: request("crash"))
        interrupted.phase = .running; interrupted.attemptID = "pre-crash-attempt"
        interrupted.receipts = [.init(kind: "test.checkpoint", summary: "Already completed operation")]
        try recoveryRepo.save([interrupted])
        let recoveryWorker = ReceiptWorker(repository: recoveryRepo)
        let recovery = try OfflineCoordinator(repository: recoveryRepo, worker: recoveryWorker)
        let recovered = await recovery.task(id: interrupted.id)
        let noRecoveryReplay = try await recovery.runNext()
        let recoveryCalls = await recoveryWorker.calls
        try checks.expect(recovered?.phase == .paused && recovered?.receipts == interrupted.receipts,
                          "Interrupted work was not recovered as paused with its journal intact")
        try checks.expect(noRecoveryReplay == nil && recoveryCalls == 0, "Crash recovery replayed work automatically")
        _ = try await recovery.resume(id: interrupted.id)
        let afterResume = try await recovery.runNext()
        try checks.expect(afterResume?.phase == .completed, "Explicit recovery resume failed")
        let resumedCheckpoints = await recoveryWorker.receivedCheckpoints
        try checks.expect(resumedCheckpoints == interrupted.receipts, "Explicit resume lost its completed-operation checkpoints")

        let corruptURL = root.appendingPathComponent("corrupt")
        try FileManager.default.createDirectory(at: corruptURL, withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: corruptURL.appendingPathComponent("tasks.json"))
        try checks.rejects("Corrupt snapshot did not fail closed") { _ = try OfflineRepository(rootURL: corruptURL) }
        try Data("{\"schemaVersion\":1,\"records\":[]}".utf8).write(to: corruptURL.appendingPathComponent("tasks.json"))
        let repairedFixture = try OfflineRepository(rootURL: corruptURL)
        let repairedRecords = try repairedFixture.load()
        try checks.expect(repairedRecords.isEmpty, "Failed initialization leaked its process lease")
        let schemaURL = root.appendingPathComponent("schema")
        try FileManager.default.createDirectory(at: schemaURL, withIntermediateDirectories: true)
        try Data("{\"schemaVersion\":999,\"records\":[]}".utf8).write(to: schemaURL.appendingPathComponent("tasks.json"))
        try checks.rejects("Unknown snapshot schema accepted") { _ = try OfflineRepository(rootURL: schemaURL) }
        let symlinkURL = root.appendingPathComponent("symlink-state")
        try FileManager.default.createDirectory(at: symlinkURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlinkURL.appendingPathComponent("tasks.json"),
                                                 withDestinationURL: corruptURL.appendingPathComponent("tasks.json"))
        try checks.rejects("A linked snapshot escaped the private task store") { _ = try OfflineRepository(rootURL: symlinkURL) }

        let failingRepo = try OfflineRepository(rootURL: root.appendingPathComponent("failing"))
        let failing = try OfflineCoordinator(repository: failingRepo, worker: ReceiptWorker(repository: failingRepo))
        try FileManager.default.createDirectory(at: failingRepo.rootURL.appendingPathComponent("tasks.json"), withIntermediateDirectories: false)
        do { _ = try await failing.enqueue(request("must-not-commit")); throw CheckFailure.failed("Failed persistence appeared successful") }
        catch is OfflineError { checks.count += 1 }
        let failingRecords = await failing.tasks()
        try checks.expect(failingRecords.isEmpty, "Memory advanced despite a failed durable write")
        try checks.rejects("Failed repository was not fenced") { _ = try failingRepo.load() }

        let gateRepo = try OfflineRepository(rootURL: root.appendingPathComponent("gate"))
        let gateWorker = GateWorker()
        let gate = try OfflineCoordinator(repository: gateRepo, worker: gateWorker)
        let gatedRequest = request("cancel-stale")
        _ = try await gate.enqueue(gatedRequest); _ = try await gate.enqueue(request("queued-after-cancel"))
        let activeRun = Task { try await gate.runNext() }
        try await gateWorker.waitUntilStarted()
        let concurrentRun = try await gate.runNext()
        try checks.expect(concurrentRun == nil, "Two local workers ran concurrently")
        _ = try await gate.cancel(id: gatedRequest.id)
        let overlappingAfterCancel = try await gate.runNext()
        try checks.expect(overlappingAfterCancel == nil, "New worker started before cancelled worker really exited")
        await gateWorker.release()
        let lateResult = try await activeRun.value
        let blockedLate = await gateWorker.lateReceiptBlocked
        try checks.expect(lateResult?.phase == .cancelled && lateResult?.receipts.isEmpty == true && blockedLate,
                          "Late completion/progress changed cancelled task state")
        let afterCancelledExit = try await gate.runNext()
        try checks.expect(afterCancelledExit?.phase == .completed, "Queue did not continue after old worker exited")

        let pauseRepo = try OfflineRepository(rootURL: root.appendingPathComponent("pause"))
        let pauseWorker = GateWorker()
        let pause = try OfflineCoordinator(repository: pauseRepo, worker: pauseWorker)
        let pauseRequest = request("pause")
        _ = try await pause.enqueue(pauseRequest)
        let pauseRun = Task { try await pause.runNext() }
        try await pauseWorker.waitUntilStarted()
        _ = try await pause.pause(id: pauseRequest.id)
        do { _ = try await pause.resume(id: pauseRequest.id); throw CheckFailure.failed("Resumed a still-exiting worker") }
        catch is OfflineError { checks.count += 1 }
        await pauseWorker.release(); _ = try await pauseRun.value
        _ = try await pause.resume(id: pauseRequest.id)
        let resumed = try await pause.runNext()
        try checks.expect(resumed?.phase == .completed, "Paused work did not resume explicitly")

        let timeRepo = try OfflineRepository(rootURL: root.appendingPathComponent("deadline"))
        let timeWorker = GateWorker()
        let timed = try OfflineCoordinator(repository: timeRepo, worker: timeWorker)
        let timeRequest = request("deadline", limits: .init(maxDurationSeconds: 1))
        _ = try await timed.enqueue(timeRequest)
        let timedRun = Task { try await timed.runNext() }
        try await timeWorker.waitUntilStarted()
        try await Task.sleep(nanoseconds: 1_150_000_000)
        let deadlineState = await timed.task(id: timeRequest.id)
        try checks.expect(deadlineState?.phase == .paused, "Deadline did not durably pause the task")
        await timeWorker.release()
        let lateDeadline = try await timedRun.value
        try checks.expect(lateDeadline?.phase == .paused && lateDeadline?.result == nil, "Expired result was accepted")

        for (suffix, mode) in [("receipts", ReceiptWorker.Mode.tooManyReceipts), ("oversized", .oversizedResult), ("collision", .collision), ("network", .network)] {
            let repo = try OfflineRepository(rootURL: root.appendingPathComponent(suffix))
            let executor = ReceiptWorker(repository: repo, mode: mode)
            let coordinator = try OfflineCoordinator(repository: repo, worker: executor)
            _ = try await coordinator.enqueue(request(suffix, limits: .init(maxReceipts: 2)))
            let result = try await coordinator.runNext()
            try checks.expect(result?.phase == (mode == .network ? .waitingForNetwork : .failed) && result?.result == nil,
                              "Worker budget/failure incorrectly marked completed: \(suffix)")
            try checks.expect((result?.receipts.count ?? 0) <= 2, "Progress journal exceeded its bound")
        }

        let partialRepo = try OfflineRepository(rootURL: root.appendingPathComponent("partial-network"))
        let partial = try OfflineCoordinator(repository: partialRepo, worker: ReceiptWorker(repository: partialRepo, mode: .partialNetwork))
        let partialRequest = request("partial-network")
        _ = try await partial.enqueue(partialRequest)
        let partialResult = try await partial.runNext()
        try checks.expect(partialResult?.phase == .waitingForNetwork && partialResult?.result?.output == "Read-only proposal",
                          "Partial work needing network was falsely marked completed or discarded")
        do { _ = try await partial.prepareHandoff(id: partialRequest.id); throw CheckFailure.failed("Incomplete work produced a completed handoff") }
        catch is OfflineError { checks.count += 1 }

        let callerRepo = try OfflineRepository(rootURL: root.appendingPathComponent("caller-cancel"))
        let callerWorker = GateWorker()
        let caller = try OfflineCoordinator(repository: callerRepo, worker: callerWorker)
        let callerRequest = request("caller-cancel")
        _ = try await caller.enqueue(callerRequest)
        let callerRun = Task { try await caller.runNext() }
        try await callerWorker.waitUntilStarted()
        callerRun.cancel(); await callerWorker.release()
        let callerResult = try await callerRun.value
        try checks.expect(callerResult?.phase == .paused && callerResult?.result == nil, "Caller cancellation was reported completed")

        let progressRepo = try OfflineRepository(rootURL: root.appendingPathComponent("progress-storage-failure"))
        let progressWorker = GateWorker()
        let progressCoordinator = try OfflineCoordinator(repository: progressRepo, worker: progressWorker)
        let progressRequest = request("progress-storage-failure")
        _ = try await progressCoordinator.enqueue(progressRequest)
        let progressRun = Task { try await progressCoordinator.runNext() }
        try await progressWorker.waitUntilStarted()
        let fixtureState = progressRepo.rootURL.appendingPathComponent("tasks.json")
        try FileManager.default.removeItem(at: fixtureState) // Exact, synthetic test snapshot only.
        try FileManager.default.createDirectory(at: fixtureState, withIntermediateDirectories: false)
        await progressWorker.release()
        do { _ = try await progressRun.value; throw CheckFailure.failed("Ignored progress persistence failure appeared successful") }
        catch is OfflineError { checks.count += 1 }
        let progressFailureState = await progressCoordinator.task(id: progressRequest.id)
        try checks.expect(progressFailureState?.phase != .completed && progressFailureState?.receipts.isEmpty == true,
                          "Failed progress checkpoint allowed a stale completion")
        try checks.rejects("Progress write failure did not fence the repository") { _ = try progressRepo.load() }

        print("PASS BavbavOffline core: \(checks.count) assertions; isolated fixtures, no production data or model calls")
        try await OllamaChecks.run()
    }
}
