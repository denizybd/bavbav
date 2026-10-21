import Foundation

/// A single local executor with transactional checkpoints and explicit cloud reconciliation.
public actor OfflineCoordinator {
    private let repository: OfflineRepository
    private let worker: any OfflineWorker
    private let ownerID: String
    private var records: [OfflineTaskRecord]
    private struct Execution {
        let taskID: String
        let attemptID: String
        let startedAt: Date
        let workerTask: Task<OfflineWorkResult, Error>
    }
    private var active: Execution?
    private var invalidatedAttempts = Set<String>()
    private var executionFailures: [String: OfflineError] = [:]

    public init(repository: OfflineRepository, worker: any OfflineWorker) throws {
        self.repository = repository; self.worker = worker
        ownerID = UUID().uuidString
        try repository.claimCoordinator(ownerID)
        do {
            var recovered = try repository.load()
            var changed = false
            for index in recovered.indices where recovered[index].phase == .running {
                recovered[index].phase = .paused
                recovered[index].errorMessage = "Önceki çalışma kesildi. Kayıtlar korundu; otomatik tekrar yürütülmedi."
                recovered[index].attemptID = nil
                recovered[index].updatedAt = Date()
                changed = true
            }
            if changed { try repository.save(recovered) }
            records = recovered
        } catch {
            repository.releaseCoordinator(ownerID)
            throw error
        }
    }

    deinit { repository.releaseCoordinator(ownerID) }

    public func tasks() -> [OfflineTaskRecord] { records.sorted { $0.request.createdAt < $1.request.createdAt } }
    public func task(id: String) -> OfflineTaskRecord? { records.first { $0.id == id } }

    @discardableResult public func enqueue(_ request: OfflineWorkRequest) throws -> OfflineTaskRecord {
        try request.validate()
        if let existing = records.first(where: { $0.request.deduplicationKey == request.deduplicationKey }) {
            guard existing.request.sourceThreadID == request.sourceThreadID,
                  existing.request.workspacePath == request.workspacePath,
                  existing.request.objective == request.objective,
                  existing.request.context == request.context,
                  existing.request.attachments == request.attachments else {
                throw OfflineError.invalidRequest("Deduplication key was reused for different work")
            }
            return existing
        }
        guard !records.contains(where: { $0.id == request.id }) else {
            throw OfflineError.invalidRequest("Task identity was reused")
        }
        guard records.count < repository.maxTasks else { throw OfflineError.limitExceeded("Task repository is full") }
        let record = OfflineTaskRecord(request: request)
        try commit(records + [record])
        return record
    }

    /// No eligible work, or an existing worker, returns nil. This method never replays recovered work.
    @discardableResult public func runNext() async throws -> OfflineTaskRecord? {
        guard active == nil, let index = records.indices.filter({ records[$0].phase == .queued })
            .min(by: { records[$0].request.createdAt < records[$1].request.createdAt }) else { return nil }
        guard records[index].request.cloudDisposition != .outcomeUnknown else {
            throw OfflineError.invalidTransition("Cloud outcome must be resolved first")
        }
        var preparedRequest = records[index].request
        preparedRequest.checkpointReceipts = records[index].receipts
        let request = preparedRequest
        let attempt = UUID().uuidString
        var changed = records
        changed[index].phase = .running; changed[index].attemptID = attempt
        changed[index].errorMessage = nil; changed[index].updatedAt = Date()
        try commit(changed)
        let executor = worker
        let progress: @Sendable (OfflineProgressReceipt) async throws -> Void = { [weak self] receipt in
            guard let self else { throw OfflineError.cancelled }
            try await self.recordProgress(receipt, taskID: request.id, attemptID: attempt)
        }
        let workerTask = Task { try await executor.run(request: request, progress: progress) }
        active = Execution(taskID: request.id, attemptID: attempt, startedAt: Date(), workerTask: workerTask)
        let deadlineTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(request.limits.maxDurationSeconds * 1_000_000_000)) }
            catch { return }
            await self?.expire(taskID: request.id, attemptID: attempt)
        }
        do {
            let result = try await withTaskCancellationHandler(operation: { try await workerTask.value }, onCancel: {
                workerTask.cancel()
            })
            deadlineTask.cancel()
            defer { finishExecution(attemptID: attempt) }
            if let failure = executionFailures[attempt] { throw failure }
            if Task.isCancelled, task(id: request.id)?.phase == .running {
                _ = try stop(id: request.id, phase: .paused, message: "Çağıran işlem durduruldu; görev otomatik tekrarlanmaz.")
            }
            guard let finalIndex = records.firstIndex(where: { $0.id == request.id }),
                  records[finalIndex].phase == .running, records[finalIndex].attemptID == attempt,
                  !invalidatedAttempts.contains(attempt), !Task.isCancelled else {
                return task(id: request.id)
            }
            guard result.summary.count <= 4000, result.output.count <= request.limits.maxOutputCharacters else {
                throw OfflineError.limitExceeded("Result exceeds the task output budget")
            }
            var completed = records
            for receipt in result.receipts { try append(receipt, to: &completed[finalIndex]) }
            completed[finalIndex].result = result
            completed[finalIndex].phase = result.disposition == .completed ? .completed : .waitingForNetwork
            completed[finalIndex].errorMessage = result.disposition == .waitingForNetwork ? result.summary : nil
            completed[finalIndex].attemptID = nil; completed[finalIndex].updatedAt = Date()
            try commit(completed)
            return records[finalIndex]
        } catch {
            deadlineTask.cancel()
            defer { finishExecution(attemptID: attempt) }
            if let failure = executionFailures[attempt] { throw failure }
            guard let failureIndex = records.firstIndex(where: { $0.id == request.id }),
                  records[failureIndex].phase == .running, records[failureIndex].attemptID == attempt,
                  !invalidatedAttempts.contains(attempt) else {
                return task(id: request.id)
            }
            var failed = records
            if error is CancellationError || Task.isCancelled || error as? OfflineError == .cancelled {
                failed[failureIndex].phase = .paused
            } else if let offline = error as? OfflineError, case .networkUnavailable = offline {
                failed[failureIndex].phase = .waitingForNetwork
            } else {
                failed[failureIndex].phase = .failed
            }
            failed[failureIndex].attemptID = nil
            failed[failureIndex].errorMessage = String(String(describing: error).prefix(4000))
            failed[failureIndex].updatedAt = Date()
            try commit(failed)
            return records[failureIndex]
        }
    }

    @discardableResult public func cancel(id: String) throws -> OfflineTaskRecord {
        try stop(id: id, phase: .cancelled, message: "Kullanıcı yerel çalışmayı iptal etti.")
    }

    @discardableResult public func pause(id: String) throws -> OfflineTaskRecord {
        try stop(id: id, phase: .paused, message: "Yerel çalışma duraklatıldı; otomatik tekrar yürütülmez.")
    }

    @discardableResult public func resume(id: String) throws -> OfflineTaskRecord {
        guard let index = records.firstIndex(where: { $0.id == id }),
              [.paused, .failed, .waitingForNetwork].contains(records[index].phase) else {
            throw OfflineError.invalidTransition("Only paused/failed/waiting work can resume")
        }
        guard active?.taskID != id else { throw OfflineError.invalidTransition("Previous execution is still stopping") }
        var updated = records
        updated[index].phase = updated[index].request.cloudDisposition == .outcomeUnknown ? .awaitingCloudResolution : .queued
        updated[index].errorMessage = nil; updated[index].updatedAt = Date()
        try commit(updated)
        return records[index]
    }

    @discardableResult public func resolveCloud(id: String, disposition: OfflineCloudDisposition) throws -> OfflineTaskRecord {
        guard disposition != .outcomeUnknown, let index = records.firstIndex(where: { $0.id == id }),
              records[index].phase == .awaitingCloudResolution else {
            throw OfflineError.invalidTransition("Explicit cloud resolution is required")
        }
        var updated = records
        updated[index].request.cloudDisposition = disposition
        updated[index].phase = .queued; updated[index].updatedAt = Date()
        try commit(updated)
        return records[index]
    }

    /// Persist a fork's actual destination before its turn RPC, including when the RPC acknowledgement is lost.
    @discardableResult public func retargetUnboundCloudIntent(id: String, sourceThreadID: String,
                                                             workspacePath: String) throws -> OfflineTaskRecord {
        guard id.hasPrefix("cloud-intent-"), let index = records.firstIndex(where: { $0.id == id }),
              records[index].phase == .awaitingCloudResolution,
              records[index].request.cloudDisposition == .outcomeUnknown,
              records[index].request.sourceTurnID == nil else {
            throw OfflineError.invalidTransition("Only an unbound pending cloud intent can be retargeted")
        }
        if records[index].request.sourceThreadID == sourceThreadID && records[index].request.workspacePath == workspacePath {
            return records[index]
        }
        var updated = records
        updated[index].request.sourceThreadID = sourceThreadID
        updated[index].request.workspacePath = workspacePath
        try updated[index].request.validate()
        updated[index].updatedAt = Date()
        try commit(updated)
        return records[index]
    }

    /// Binds the durable pre-submission intent to the exact turn acknowledged by the cloud server.
    @discardableResult public func bindCloudTurn(id: String, sourceThreadID: String, turnID: String) throws -> OfflineTaskRecord {
        guard !sourceThreadID.isEmpty, sourceThreadID.count <= 256, !turnID.isEmpty, turnID.count <= 256,
              id.hasPrefix("cloud-intent-"), let index = records.firstIndex(where: { $0.id == id }),
              records[index].phase == .awaitingCloudResolution,
              records[index].request.cloudDisposition == .outcomeUnknown else {
            throw OfflineError.invalidTransition("Cloud intent must be pending before a turn can be bound")
        }
        if let existing = records[index].request.sourceTurnID {
            guard existing == turnID, records[index].request.sourceThreadID == sourceThreadID else {
                throw OfflineError.invalidTransition("Cloud intent is already bound to a different turn")
            }
            return records[index]
        }
        var updated = records
        updated[index].request.sourceThreadID = sourceThreadID
        updated[index].request.sourceTurnID = turnID
        updated[index].updatedAt = Date()
        try commit(updated)
        return records[index]
    }

    /// A thread-wide status is insufficient: only an exact, non-nil turn identity is reconciled.
    /// Success removes the monitoring checkpoint, never the Codex conversation/history.
    @discardableResult public func reconcileCloudTurn(sourceThreadID: String, turnID: String,
                                                     succeeded: Bool) throws -> [OfflineTaskRecord] {
        guard !sourceThreadID.isEmpty, !turnID.isEmpty else {
            throw OfflineError.invalidRequest("Cloud reconciliation requires an exact thread and turn identity")
        }
        let matching = Set(records.filter {
            $0.id.hasPrefix("cloud-intent-") && $0.phase == .awaitingCloudResolution
                && $0.request.cloudDisposition == .outcomeUnknown
                && $0.request.sourceThreadID == sourceThreadID && $0.request.sourceTurnID == turnID
        }.map(\.id))
        guard !matching.isEmpty else { return [] }
        if succeeded {
            try commit(records.filter { !matching.contains($0.id) })
            return []
        }
        var updated = records
        for index in updated.indices where matching.contains(updated[index].id) {
            updated[index].request.cloudDisposition = .confirmedStopped
            updated[index].phase = .paused
            updated[index].attemptID = nil
            updated[index].errorMessage = "Bulut işleminin sona erdiği doğrulandı. Yerel kontrol noktası hazır; otomatik yürütülmedi."
            updated[index].updatedAt = Date()
        }
        try commit(updated)
        return records.filter { matching.contains($0.id) }
    }

    public func prepareHandoff(id: String) throws -> OfflineHandoffReport {
        guard let index = records.firstIndex(where: { $0.id == id }),
              [.completed, .handedBack].contains(records[index].phase), let result = records[index].result else {
            throw OfflineError.invalidTransition("Only completed local work can be handed back")
        }
        if let existing = records[index].handoff { return existing }
        let request = records[index].request
        let report = OfflineHandoffReport(id: UUID().uuidString, taskID: id, sourceThreadID: request.sourceThreadID,
                                          modelID: OfflinePlugin.modelID, objective: request.objective,
                                          summary: result.summary, output: result.output,
                                          receipts: records[index].receipts, createdAt: Date())
        var updated = records
        updated[index].handoff = report; updated[index].updatedAt = Date()
        try commit(updated)
        return report
    }

    /// Call only after the host/user accepted the prepared composer input. This does not send it.
    @discardableResult public func acceptHandoff(id: String, reportID: String) throws -> OfflineTaskRecord {
        guard let index = records.firstIndex(where: { $0.id == id }),
              [.completed, .handedBack].contains(records[index].phase), records[index].handoff?.id == reportID else {
            throw OfflineError.invalidTransition("Prepared handoff identity does not match")
        }
        if records[index].phase == .handedBack { return records[index] }
        var updated = records
        updated[index].phase = .handedBack; updated[index].handoffAcceptedAt = Date(); updated[index].updatedAt = Date()
        try commit(updated)
        return records[index]
    }

    private func commit(_ candidate: [OfflineTaskRecord]) throws {
        try repository.save(candidate)
        records = candidate
    }

    private func append(_ receipt: OfflineProgressReceipt, to record: inout OfflineTaskRecord) throws {
        try receipt.validate()
        if let existing = record.receipts.first(where: { $0.id == receipt.id }) {
            guard existing == receipt else { throw OfflineError.invalidRequest("Receipt identity collision") }
            return
        }
        guard record.receipts.count < record.request.limits.maxReceipts else {
            throw OfflineError.limitExceeded("Progress receipt budget exhausted")
        }
        record.receipts.append(receipt); record.updatedAt = Date()
    }

    private func recordProgress(_ receipt: OfflineProgressReceipt, taskID: String, attemptID: String) throws {
        guard let execution = active, execution.taskID == taskID, execution.attemptID == attemptID,
              !invalidatedAttempts.contains(attemptID), let index = records.firstIndex(where: { $0.id == taskID }),
              records[index].phase == .running, records[index].attemptID == attemptID else {
            throw OfflineError.staleExecution
        }
        guard Date().timeIntervalSince(execution.startedAt) <= records[index].request.limits.maxDurationSeconds else {
            throw OfflineError.limitExceeded("Execution time budget exhausted")
        }
        var updated = records
        try append(receipt, to: &updated[index])
        do { try commit(updated) }
        catch {
            invalidatedAttempts.insert(attemptID)
            executionFailures[attemptID] = (error as? OfflineError) ?? .storageFailure("Progress checkpoint failed")
            active?.workerTask.cancel()
            throw error
        }
    }

    private func stop(id: String, phase: OfflineTaskPhase, message: String) throws -> OfflineTaskRecord {
        guard let index = records.firstIndex(where: { $0.id == id }),
              ![.completed, .handedBack, .cancelled].contains(records[index].phase) else {
            throw OfflineError.invalidTransition("Task is already terminal or missing")
        }
        if let execution = active, execution.taskID == id {
            invalidatedAttempts.insert(execution.attemptID)
            execution.workerTask.cancel()
        }
        var updated = records
        updated[index].phase = phase; updated[index].attemptID = nil
        updated[index].errorMessage = message; updated[index].updatedAt = Date()
        try commit(updated)
        return records[index]
    }

    private func expire(taskID: String, attemptID: String) {
        guard active?.taskID == taskID, active?.attemptID == attemptID,
              task(id: taskID)?.phase == .running else { return }
        invalidatedAttempts.insert(attemptID)
        active?.workerTask.cancel()
        if let index = records.firstIndex(where: { $0.id == taskID }) {
            var updated = records
            updated[index].phase = .paused; updated[index].attemptID = nil
            updated[index].errorMessage = "Yerel çalışma süre sınırında durduruldu."
            updated[index].updatedAt = Date()
            // A failed write leaves the durable running record; recovery will pause it, never replay it.
            do { try commit(updated) }
            catch { executionFailures[attemptID] = (error as? OfflineError) ?? .storageFailure("Deadline checkpoint failed") }
        }
    }

    private func finishExecution(attemptID: String) {
        if active?.attemptID == attemptID { active = nil }
        invalidatedAttempts.remove(attemptID)
        executionFailures.removeValue(forKey: attemptID)
    }
}
