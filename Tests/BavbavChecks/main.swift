import BavbavCore
import Foundation

private enum CheckFailure: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        }
    }
}

private struct Item: Identifiable, Equatable {
    let id: String
}

private struct TurnOutcome: Sendable {
    let status: String
    let error: String?
}

private final class EventEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private var agentTurnIDs = Set<String>()

    func record(_ event: CodexServerEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .agentMessageDelta(_, let turnID, _, let delta) where !delta.isEmpty:
            agentTurnIDs.insert(turnID)
        case .itemCompleted(_, let turnID, let message) where message.role == .agent:
            agentTurnIDs.insert(turnID)
        default:
            break
        }
    }

    func sawAgentOutput(for turnID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return agentTurnIDs.contains(turnID)
    }
}

private actor TurnProbe {
    private var completed: [String: TurnOutcome] = [:]
    private var waiters: [String: CheckedContinuation<TurnOutcome?, Never>] = [:]

    func record(_ event: CodexServerEvent) {
        guard case .turnCompleted(_, let turnID, let status, let error) = event else { return }
        let outcome = TurnOutcome(status: status, error: error)
        if let waiter = waiters.removeValue(forKey: turnID) {
            waiter.resume(returning: outcome)
        } else {
            completed[turnID] = outcome
        }
    }

    func wait(for turnID: String, timeoutSeconds: UInt64) async -> TurnOutcome? {
        if let outcome = completed.removeValue(forKey: turnID) { return outcome }
        return await withCheckedContinuation { continuation in
            waiters[turnID] = continuation
            Task {
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                expire(turnID)
            }
        }
    }

    private func expire(_ turnID: String) {
        guard let waiter = waiters.removeValue(forKey: turnID) else { return }
        waiter.resume(returning: nil)
    }
}

private actor InteractionProbe {
    private var requests: [String: CodexInteractionRequest] = [:]
    private var waiters: [String: CheckedContinuation<CodexInteractionRequest?, Never>] = [:]

    func record(_ event: CodexServerEvent) {
        guard case .interactionRequested(let request) = event,
              let turnID = request.turnID
        else { return }
        if let waiter = waiters.removeValue(forKey: turnID) {
            waiter.resume(returning: request)
        } else {
            requests[turnID] = request
        }
    }

    func wait(for turnID: String, timeoutSeconds: UInt64) async -> CodexInteractionRequest? {
        if let request = requests.removeValue(forKey: turnID) { return request }
        return await withCheckedContinuation { continuation in
            waiters[turnID] = continuation
            Task {
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                expire(turnID)
            }
        }
    }

    private func expire(_ turnID: String) {
        guard let waiter = waiters.removeValue(forKey: turnID) else { return }
        waiter.resume(returning: nil)
    }
}

enum RolloutConversationChecks {
    static func run() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bavbav-rollout-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("fixture.jsonl")
        func event(_ id: String, thread: String = "root", type: String = "AgentMessage", text: String = "Merhaba dünya") throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": "2026-09-11T00:00:00.000Z",
                "payload": ["type": "item_completed", "thread_id": thread,
                    "item": ["id": id, "type": type, "content": [["type": "Text", "text": text]]]]], options: [.sortedKeys])
            data.append(10)
            return data
        }
        func require(_ value: Bool, _ reason: String) throws {
            if !value { throw NSError(domain: "RolloutChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]) }
        }
        var data = try event("first", type: "UserMessage")
        data.append(try event("child", thread: "child"))
        data.append(try event("secret", type: "Reasoning", text: "Do not render private reasoning"))
        data.append(try event("second"))
        try data.write(to: path)
        let reader = RolloutConversationReader()
        let initial = try await reader.read(path: path.path, threadID: "root")
        try require(initial.map(\.id) == ["first", "second"], "only this thread's public messages are read")
        let repeated = try await reader.read(path: path.path, threadID: "root")
        try require(repeated == initial, "unchanged log has no duplicates")
        let third = try event("third", text: String(repeating: "ğ", count: 600))
        let file = try FileHandle(forWritingTo: path)
        try file.seekToEnd()
        try file.write(contentsOf: third.dropLast())
        let partial = try await reader.read(path: path.path, threadID: "root")
        try require(partial == initial, "partial last line waits for completion")
        try file.write(contentsOf: Data([10])); try file.close()
        let appended = try await reader.read(path: path.path, threadID: "root")
        try require(appended.map(\.id) == ["first", "second", "third"], "incremental UTF-8 message becomes visible")
        let merged = RolloutConversationReader.merge([appended[1]], with: appended)
        try require(merged.map(\.id) == ["first", "second", "third"], "indexed overlap preserves chronology and identity")
        try require(RolloutConversationReader.merge(appended, with: appended) == appended, "caught-up projection does not duplicate messages")
        try (try event("replacement")).write(to: path)
        let replaced = try await reader.read(path: path.path, threadID: "root")
        try require(replaced.map(\.id) == ["replacement"], "truncated log discards old cache")
        try (try event("atomic-replacement", text: String(repeating: "a", count: 1_000))).write(to: path, options: .atomic)
        let atomic = try await reader.read(path: path.path, threadID: "root")
        try require(atomic.map(\.id) == ["atomic-replacement"], "larger atomic replacement resets the file cursor")
        if let live = ProcessInfo.processInfo.environment["BAVBAV_READ_ONLY_ROLLOUT"],
           let thread = ProcessInfo.processInfo.environment["BAVBAV_READ_ONLY_THREAD"] {
            let messages = try await reader.read(path: live, threadID: thread)
            print("READ-ONLY ROLLOUT: \(messages.count) public messages; latest timestamp \(messages.last?.timestamp?.description ?? "unknown")")
        }
        let sentAt = Date(timeIntervalSince1970: 100)
        let local = CodexMessage(id: "local", role: .user, text: "same", timestamp: sentAt)
        let old = CodexMessage(id: "old", role: .user, text: "same", timestamp: sentAt.addingTimeInterval(-10))
        var pending = [OptimisticUserMessage(threadID: "root", localID: "local", text: "same")]
        let waiting = MessageReconciler.refreshedHistory([old], current: [old, local], threadID: "root", pending: &pending)
        try require(waiting.map(\.id) == ["old", "local"] && pending[0].serverID == nil, "old identical prompt cannot swallow pending send")
        let echo = CodexMessage(id: "echo", role: .user, text: "same", timestamp: sentAt)
        let confirmed = MessageReconciler.refreshedHistory([old, echo], current: waiting, threadID: "root", pending: &pending)
        try require(confirmed.map(\.id) == ["old", "echo"] && pending[0].serverID == "echo", "new persisted echo replaces optimistic row exactly once")
        let repeatedEcho = MessageReconciler.refreshedHistory([old, echo], current: confirmed, threadID: "root", pending: &pending)
        try require(repeatedEcho == confirmed, "repeated refresh does not duplicate send")
        print("✓ rollout fallback: identity, isolation, partial append, UTF-8, chronology, truncation")
    }
}

@main
struct BavbavChecks {
    static func main() async {
        do {
            try checkOrdering()
            try checkInteraction()
            try checkRuntimeModels()
            try checkMessageReconciliation()
            try await RolloutConversationChecks.run()
            print("✓ ordering")
            print("✓ keyboard interaction")
            print("✓ runtime settings models")
            print("✓ optimistic message echo reconciliation")

            if CommandLine.arguments.contains("--protocol-fixture") {
                try await checkProtocolInteractions()
                print("✓ approval + question protocol round-trips")
                print("✓ full-access new + existing thread protocol")
                try await checkWriterForkProtocol()
                print("✓ active-writer fork handoff protocol")
                try await checkSteerProtocol()
                print("✓ active-turn steer protocol")
            }

            if CommandLine.arguments.contains("--integration") {
                try await checkCodexIntegration()
                print("✓ Codex authenticated handshake")
                print("✓ Codex model + history metadata read")
                print("✓ Codex model catalog + usage limits read")
                if CommandLine.arguments.contains("--integration-history") {
                    print("✓ Codex bounded message history read")
                }
                if CommandLine.arguments.contains("--integration-all-history") {
                    print("✓ all recent Codex histories readable")
                }
                if CommandLine.arguments.contains("--integration-activity") {
                    print("✓ Codex full activity timeline read")
                }
                if CommandLine.arguments.contains("--integration-turn") {
                    print("✓ Codex ephemeral message round-trip")
                }
                if CommandLine.arguments.contains("--integration-fork-active") {
                    print("✓ active desktop thread can be forked for Bavbav")
                }
            }
            print("ALL CHECKS PASSED")
        } catch {
            fputs("CHECK FAILED: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func checkOrdering() throws {
        let items = [Item(id: "a"), Item(id: "b"), Item(id: "c")]
        let ordered = StableOrdering.reconcile(items, preferredIDs: ["c", "a", "stale"])
        try require(ordered.map(\.id) == ["c", "a", "b"], "ordering reconciliation")
        try require(
            StableOrdering.moved(items, from: 0, delta: -1).items.map(\.id) == ["a", "b", "c"],
            "top boundary"
        )
        try require(
            StableOrdering.moved(items, from: 1, delta: 1).items.map(\.id) == ["a", "c", "b"],
            "move down"
        )
    }

    private static func checkInteraction() throws {
        var shortPress = ListInteractionState(selectedID: "bombom")
        try require(shortPress.beginSpace(visibleIDs: ["bavbav", "bombom"]) == .none, "space down")
        try require(shortPress.releaseSpace() == .activate("bombom"), "short space activation")

        var longPress = ListInteractionState(selectedID: "lawuk")
        _ = longPress.beginSpace(visibleIDs: ["bavbav", "bombom", "lawuk"])
        try require(
            longPress.crossLongPressThreshold(visibleIDs: ["bavbav", "bombom", "lawuk"]) == .enteredReorder("lawuk"),
            "long space threshold"
        )
        try require(longPress.isReordering, "reorder latch")
        try require(longPress.releaseSpace() == .none, "long release")
        try require(
            longPress.beginSpace(visibleIDs: ["bavbav", "bombom", "lawuk"]) == .committed,
            "reorder commit"
        )
    }

    private static func checkRuntimeModels() throws {
        let ordinary = CodexRateLimitWindow(
            usedPercent: 37,
            durationMinutes: 300,
            resetsAt: nil
        )
        try require(ordinary.remainingPercent == 63, "remaining rate calculation")
        let clamped = CodexRateLimitWindow(
            usedPercent: 170,
            durationMinutes: 10_080,
            resetsAt: nil
        )
        try require(clamped.usedPercent == 100, "rate limit upper clamp")
        try require(clamped.remainingPercent == 0, "clamped remaining rate")
    }

    private static func checkMessageReconciliation() throws {
        let localID = "local-1"
        var messages = [CodexMessage(id: localID, role: .user, text: "aynı mesaj")]
        var pending: OptimisticUserMessage? = OptimisticUserMessage(
            threadID: "thread-a",
            localID: localID,
            text: "aynı mesaj"
        )
        let started = CodexMessage(id: "server-1", role: .user, text: "aynı mesaj")
        try require(
            MessageReconciler.mergeUserEcho(
                messages: &messages,
                incoming: started,
                threadID: "thread-a",
                pending: &pending
            ),
            "server user echo did not match optimistic message"
        )
        try require(messages.count == 1, "user message was duplicated on item/started")
        try require(messages[0].id == "server-1", "server message id did not replace local id")

        let completed = CodexMessage(id: "server-1", role: .user, text: "aynı mesaj")
        try require(
            MessageReconciler.mergeUserEcho(
                messages: &messages,
                incoming: completed,
                threadID: "thread-a",
                pending: &pending
            ),
            "item/completed did not match its started item"
        )
        try require(messages.count == 1, "user message was duplicated on item/completed")

        pending = nil
        let intentionalRepeat = CodexMessage(id: "server-2", role: .user, text: "aynı mesaj")
        try require(
            !MessageReconciler.mergeUserEcho(
                messages: &messages,
                incoming: intentionalRepeat,
                threadID: "thread-a",
                pending: &pending
            ),
            "intentional repeated message was incorrectly collapsed"
        )

        pending = OptimisticUserMessage(threadID: "thread-a", localID: "local-2", text: "fork")
        pending?.threadID = "thread-fork"
        var forkMessages = [CodexMessage(id: "local-2", role: .user, text: "fork")]
        try require(
            MessageReconciler.mergeUserEcho(
                messages: &forkMessages,
                incoming: CodexMessage(id: "server-fork", role: .user, text: "fork"),
                threadID: "thread-fork",
                pending: &pending
            ),
            "forked first message did not reconcile"
        )
        try require(forkMessages.count == 1, "forked first message was duplicated")

        var queuedMessages = [
            CodexMessage(id: "queued-local-1", role: .user, text: "same steer"),
            CodexMessage(id: "queued-local-2", role: .user, text: "same steer")
        ]
        var queued = [
            OptimisticUserMessage(threadID: "thread-steer", localID: "queued-local-1", text: "same steer"),
            OptimisticUserMessage(threadID: "thread-steer", localID: "queued-local-2", text: "same steer")
        ]
        for serverID in ["queued-server-1", "queued-server-2"] {
            try require(
                MessageReconciler.mergeUserEcho(
                    messages: &queuedMessages,
                    incoming: CodexMessage(id: serverID, role: .user, text: "same steer"),
                    threadID: "thread-steer",
                    pending: &queued
                ),
                "queued steer echo was not reconciled"
            )
        }
        try require(queuedMessages.count == 2, "identical queued steer messages were collapsed")
        try require(
            Set(queuedMessages.map(\.id)) == Set(["queued-server-1", "queued-server-2"]),
            "queued steer ids were not persisted"
        )
    }

    private static func checkCodexIntegration() async throws {
        let client = CodexAppServer()
        do {
            let health = try await client.connect()
            try require(health.authenticated, "Codex account is not authenticated")
            try require(health.historyAvailable, "Codex history is unavailable")
            try require(health.modelAvailable, "No Codex model is available")
            try require(!health.codexHome.isEmpty, "Codex home metadata is unavailable")
            let repeatedHealth = try await client.connect()
            try require(
                repeatedHealth.codexHome == health.codexHome,
                "Codex reconnect metadata changed"
            )

            let models = try await client.listModels(limit: 100)
            try require(!models.isEmpty, "Codex returned no selectable models")
            try require(
                models.contains(where: { !$0.supportedReasoningEfforts.isEmpty }),
                "Codex models exposed no reasoning effort choices"
            )
            let limits = try await client.readRateLimits()
            try require(
                limits.primary != nil || limits.secondary != nil,
                "Codex returned no rate-limit windows"
            )
            _ = try await client.readAccountUsage()

            // This deliberately verifies only metadata addressability. Reading
            // an arbitrary first thread's entire rollout makes the connectivity
            // check depend on the user's history size.
            // Runtime'ın kullandığı tam tek sayfayı da doğrula.
            let threadLimit = CommandLine.arguments.contains("--integration-all-history") ? 2_000 : 80
            let threads = try await client.listThreads(limit: threadLimit)
            try require(!threads.isEmpty, "Codex returned no recent threads")
            if let first = threads.first {
                try await client.probeThread(id: first.id)
            }
            if CommandLine.arguments.contains("--integration-history") {
                var verifiedHistory = false
                for thread in threads {
                    if try await client.probeThread(id: thread.id) == "paginated" {
                        _ = try await client.readThread(id: thread.id, maxMessages: 40)
                        verifiedHistory = true
                        break
                    }
                }
                try require(verifiedHistory, "No paginated Codex thread was available for bounded history verification")
            }
            if CommandLine.arguments.contains("--integration-all-history") {
                try await checkAllRecentHistories(client: client, threads: threads)
            }
            if CommandLine.arguments.contains("--integration-activity") {
                var verifiedItems: [CodexMessage] = []
                for activityThread in threads.prefix(8) where activityThread.hasMessages {
                    let candidate = try await client.readThreadActivity(id: activityThread.id)
                    if candidate.contains(where: { !$0.kind.isConversation }) {
                        verifiedItems = candidate
                        break
                    }
                }
                try require(
                    verifiedItems.contains(where: { !$0.kind.isConversation }),
                    "Codex activity timeline exposed no operational items"
                )
                let operationalKinds = Set(verifiedItems.filter { !$0.kind.isConversation }.map(\.kind.rawValue))
                print("activity kinds: \(operationalKinds.sorted().joined(separator: ", "))")
            }
            if CommandLine.arguments.contains("--integration-refresh") {
                for cycle in 1...4 {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    let refreshed = try await client.listThreads(limit: 80)
                    try require(!refreshed.isEmpty, "Codex refresh cycle \(cycle) returned no threads")
                    print("✓ Codex refresh cycle \(cycle)")
                }
            }
            if CommandLine.arguments.contains("--integration-turn") {
                try await checkEphemeralTurn(client: client, models: models)
            }
            if CommandLine.arguments.contains("--integration-fork-active") {
                try await checkActiveThreadFork(client: client)
            }
            await client.shutdown()
        } catch {
            await client.shutdown()
            throw error
        }
    }

    private static func checkAllRecentHistories(
        client: CodexAppServer,
        threads: [CodexThread]
    ) async throws {
        var failures: [String] = []
        var modeCounts: [String: Int] = [:]
        for thread in threads {
            let mode = (try? await client.probeThread(id: thread.id)) ?? "unknown"
            modeCounts[mode, default: 0] += 1
            do {
                let messages = try await client.readThread(id: thread.id, maxMessages: 40)
                if thread.hasMessages, messages.isEmpty {
                    failures.append("\(thread.id.prefix(8)) [\(mode)]: history returned no visible messages")
                }
            } catch {
                failures.append("\(thread.id.prefix(8)) [\(mode)]: \(error.localizedDescription)")
            }
        }
        let summary = modeCounts.keys.sorted().map { "\($0)=\(modeCounts[$0] ?? 0)" }.joined(separator: ", ")
        print("history records: \(threads.count); modes: \(summary)")
        if !failures.isEmpty {
            failures.prefix(12).forEach { fputs("history failure: \($0)\n", stderr) }
            throw CheckFailure.failed("\(failures.count) of \(threads.count) recent histories were unreadable")
        }
    }

    private static func checkEphemeralTurn(
        client: CodexAppServer,
        models: [CodexModelDescriptor]
    ) async throws {
        let model = models.first(where: { $0.model.contains("luna") })
            ?? models.first(where: \.isDefault)
            ?? models[0]
        let effort = model.supportedReasoningEfforts.first(where: { $0.id == "minimal" })?.id
            ?? model.supportedReasoningEfforts.first(where: { $0.id == "low" })?.id
            ?? model.defaultReasoningEffort
        let probe = TurnProbe()
        let evidence = EventEvidence()
        await client.setEventHandler { event in
            evidence.record(event)
            Task { await probe.record(event) }
        }
        let thread = try await client.startThread(
            cwd: FileManager.default.temporaryDirectory.path,
            model: model.model,
            ephemeral: true,
            sandbox: "read-only",
            approvalPolicy: "never"
        )
        let turn = try await client.startTurn(
            threadID: thread.id,
            text: "Reply with exactly BAVBAV_OK. Do not call tools.",
            model: model.model,
            effort: effort,
            clientUserMessageID: "bavbav-check-\(UUID().uuidString)",
            cwd: FileManager.default.temporaryDirectory.path,
            executionMode: .readOnly
        )
        guard let outcome = await probe.wait(for: turn.id, timeoutSeconds: 90) else {
            throw CheckFailure.failed("Ephemeral Codex turn timed out")
        }
        try require(
            outcome.status == "completed",
            "Ephemeral Codex turn ended as \(outcome.status): \(outcome.error ?? "unknown")"
        )
        try require(
            evidence.sawAgentOutput(for: turn.id),
            "Ephemeral Codex turn produced no streamed agent output"
        )
        await client.setEventHandler(nil)
    }

    private static func checkProtocolInteractions() async throws {
        let client = CodexAppServer()
        let turns = TurnProbe()
        let interactions = InteractionProbe()
        do {
            let health = try await client.connect()
            try require(health.authenticated, "Fixture client did not authenticate")
            await client.setEventHandler { event in
                Task {
                    await turns.record(event)
                    await interactions.record(event)
                }
            }
            let thread = try await client.startThread(
                cwd: "/tmp/fixture",
                ephemeral: true,
                sandbox: "workspace-write",
                approvalPolicy: "on-request"
            )

            let scenarios: [(String, CodexInteractionKind, CodexInteractionResponse)] = [
                ("COMMAND", .commandApproval, .option("accept")),
                ("FILE", .fileApproval, .option("decline")),
                ("PERMISSION", .permissionApproval, .option("permissionTurn")),
                ("QUESTION", .userInput, .answers(["choice": ["alpha"]])),
                ("MCP", .mcpForm, .form(action: "accept", content: [
                    "age": .integer(7),
                    "enabled": .boolean(true),
                    "tags": .stringArray(["a", "b"])
                ]))
            ]

            for (scenario, expectedKind, response) in scenarios {
                let turn = try await client.startTurn(
                    threadID: thread.id,
                    text: scenario,
                    clientUserMessageID: "fixture-\(scenario.lowercased())",
                    cwd: thread.cwd,
                    executionMode: .workspace
                )
                guard let request = await interactions.wait(for: turn.id, timeoutSeconds: 5) else {
                    throw CheckFailure.failed("No \(scenario) interaction arrived")
                }
                try require(request.kind == expectedKind, "Wrong \(scenario) interaction kind")
                if scenario == "QUESTION" {
                    try require(request.questions.first?.allowsOther == true, "Question custom input missing")
                }
                if scenario == "MCP" {
                    let fields = Dictionary(uniqueKeysWithValues: request.questions.map { ($0.id, $0) })
                    try require(fields["age"]?.valueType == .integer, "MCP integer field lost")
                    try require(fields["enabled"]?.valueType == .boolean, "MCP boolean field lost")
                    try require(fields["tags"]?.allowsMultiple == true, "MCP multi-select field lost")
                }
                try await client.resolveInteraction(requestID: request.requestID, response: response)
                guard let outcome = await turns.wait(for: turn.id, timeoutSeconds: 5) else {
                    throw CheckFailure.failed("No \(scenario) completion arrived")
                }
                try require(
                    outcome.status == "completed",
                    "\(scenario) response rejected: \(outcome.error ?? "unknown")"
                )
            }

            let namedThread = try await client.startThread(
                cwd: "/tmp/full-access-fixture",
                ephemeral: true,
                sandbox: "danger-full-access",
                approvalPolicy: "never"
            )
            try await client.setThreadName(id: namedThread.id, name: "Named fixture chat")
            let fullAccessTurn = try await client.startTurn(
                threadID: "full-access-existing",
                text: "FULL_ACCESS",
                clientUserMessageID: "fixture-full-access",
                cwd: "/tmp/full-access-fixture",
                executionMode: .fullAccess
            )
            guard let fullAccessOutcome = await turns.wait(
                for: fullAccessTurn.id,
                timeoutSeconds: 5
            ) else {
                throw CheckFailure.failed("No full-access completion arrived")
            }
            try require(
                fullAccessOutcome.status == "completed",
                "Full-access protocol settings were rejected"
            )
            await client.setEventHandler(nil)
            await client.shutdown()
        } catch {
            await client.shutdown()
            throw error
        }
    }

    private static func checkWriterForkProtocol() async throws {
        let client = CodexAppServer()
        do {
            _ = try await client.connect()
            do {
                _ = try await client.startTurn(
                    threadID: "desktop-owned",
                    text: "not accepted",
                    cwd: "/tmp/fixture",
                    executionMode: .readOnly
                )
                throw CheckFailure.failed("Active writer conflict was not surfaced")
            } catch let error as CodexClientError {
                try require(error.isActiveWriterConflict, "Active writer conflict was not recognized")
            }
            let fork = try await client.forkThread(
                id: "desktop-owned",
                cwd: "/tmp/fixture",
                ephemeral: true
            )
            try require(fork.thread.id == "fixture-fork", "Forked thread id was lost")
            try require(fork.runtime.model == "fake-model", "Forked model was not detected")
            try require(fork.runtime.effort == "low", "Forked effort was not detected")
            await client.shutdown()
        } catch {
            await client.shutdown()
            throw error
        }
    }

    private static func checkSteerProtocol() async throws {
        let client = CodexAppServer()
        let turns = TurnProbe()
        do {
            _ = try await client.connect()
            await client.setEventHandler { event in
                Task { await turns.record(event) }
            }
            let thread = try await client.startThread(
                cwd: "/tmp/fixture",
                ephemeral: true,
                sandbox: "workspace-write",
                approvalPolicy: "on-request"
            )
            let turn = try await client.startTurn(
                threadID: thread.id,
                text: "STEER_BASE",
                clientUserMessageID: "fixture-steer-base",
                cwd: thread.cwd,
                executionMode: .workspace
            )
            let steeredTurnID = try await client.steerTurn(
                threadID: thread.id,
                turnID: turn.id,
                text: "STEER_FOLLOWUP",
                clientUserMessageID: "fixture-steer-followup"
            )
            try require(steeredTurnID == turn.id, "Steer created or returned a different turn")
            guard let outcome = await turns.wait(for: turn.id, timeoutSeconds: 5) else {
                throw CheckFailure.failed("Steered turn did not complete")
            }
            try require(outcome.status == "completed", "Steered turn ended as \(outcome.status)")
            await client.setEventHandler(nil)
            await client.shutdown()
        } catch {
            await client.shutdown()
            throw error
        }
    }

    private static func checkActiveThreadFork(client: CodexAppServer) async throws {
        guard let threadID = ProcessInfo.processInfo.environment["BAVBAV_ACTIVE_THREAD_ID"],
              !threadID.isEmpty else {
            throw CheckFailure.failed("BAVBAV_ACTIVE_THREAD_ID is required")
        }
        let runtime = try await client.readPersistedRuntime(threadID: threadID)
        try require(runtime.model != nil, "Persisted active-thread model was not detected")
        try require(runtime.effort != nil, "Persisted active-thread effort was not detected")
        let fork = try await client.forkThread(id: threadID, ephemeral: true)
        try require(fork.thread.id != threadID, "thread/fork returned the source thread")
        try require(fork.runtime.model != nil, "thread/fork returned no model")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CheckFailure.failed(message) }
    }
}
