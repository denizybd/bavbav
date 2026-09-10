import Foundation

/// FileHandle may invoke its readability callback again before the Task created
/// by the previous callback reaches the actor. Serializing the actual reads and
/// numbering chunks lets the actor restore wire order deterministically.
private final class OrderedChunkReader: @unchecked Sendable {
    private let lock = NSLock()
    private var nextSequence = 0

    func read(from handle: FileHandle) -> (sequence: Int, data: Data) {
        lock.lock()
        defer { lock.unlock() }
        let data = handle.availableData
        let sequence = nextSequence
        nextSequence += 1
        return (sequence, data)
    }
}

public actor CodexAppServer {
    /// User-owned conversations shown by the Bavbav UI. Codex defaults an
    /// omitted source filter to `cli` and `vscode`; `appServer` is included so
    /// conversations created by Bavbav remain visible as writing support lands.
    public static let userFacingSources = ["cli", "vscode", "appServer"]
    private static let rpcTraceEnabled = ProcessInfo.processInfo.environment["BAVBAV_RPC_TRACE"] == "1"

    private typealias RPCContinuation = CheckedContinuation<[String: Any], Error>
    private typealias ConnectionContinuation = CheckedContinuation<CodexHealth, Error>

    private struct PendingRequest {
        let continuation: RPCContinuation
        var timeoutTask: Task<Void, Never>?
    }

    private struct ServerMetadata {
        var codexHome = ""
        var platform = "macos"
        var userAgent = "Codex"
    }

    private struct ThreadMetadata {
        let historyMode: String
    }

    private struct PendingServerRequest {
        let method: String
        let params: [String: Any]
    }

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errorOutput: FileHandle?
    private var receiveBuffer = Data()
    private var receiveSearchOffset = 0
    private var pendingReceiveChunks: [Int: Data] = [:]
    private var nextReceiveSequence = 0
    private var nextRequestID = 1
    private var pending: [Int: PendingRequest] = [:]
    private var lastErrorText = ""
    private var initialized = false
    private var processGeneration = 0
    private var serverMetadata = ServerMetadata()
    private var threadMetadata: [String: ThreadMetadata] = [:]
    private var connecting = false
    private var connectionWaiters: [ConnectionContinuation] = []
    private var eventHandler: (@Sendable (CodexServerEvent) -> Void)?
    private var resumedThreadIDs = Set<String>()
    private var pendingServerRequests: [CodexRequestID: PendingServerRequest] = [:]
    private var runtimeByThreadID: [String: CodexThreadRuntime] = [:]
    private var rolloutPathByThreadID: [String: String] = [:]
    private let conversationRollout = RolloutConversationReader()

    private let journalWorker: Bool
    private var journalThreadID: String?
    private var journalOutput = ""
    private var journalFinished = false
    private var journalFailure: String?

    public init(journalWorker: Bool = false) { self.journalWorker = journalWorker }

    /// Dedicated ephemeral worker; never resumes or adds prompts to a user chat.
    public func extractJournal(prompt: String, cwd: String) async throws -> [JournalCandidate] {
        guard journalWorker else { throw JournalError.extractionFailed("Note extraction requires a separate connection.") }
        try await ensureConnected()
        journalOutput = ""; journalFinished = false; journalFailure = nil
        let result = try await request(method: "thread/start", params: [
            "cwd": cwd, "ephemeral": true, "sandbox": "read-only", "approvalPolicy": "never",
            "baseInstructions": JournalRules.instructions, "developerInstructions": JournalRules.instructions,
            "environments": [], "dynamicTools": [], "selectedCapabilityRoots": [],
            "config": ["web_search": "disabled", "model_reasoning_effort": "low",
                       "features.shell_tool": false, "features.unified_exec": false,
                       "features.apps": false, "features.multi_agent": false, "agents.enabled": false,
                       "features.hooks": false, "features.memories": false, "mcp_servers": [:]] as [String: Any]
        ], timeout: 30)
        guard let row = result["thread"] as? [String: Any], let id = row["id"] as? String else {
            throw JournalError.extractionFailed("Could not start note extraction.")
        }
        journalThreadID = id
        _ = try await request(method: "turn/start", params: [
            "threadId": id, "input": [["type": "text", "text": prompt]],
            "approvalPolicy": "never", "sandboxPolicy": ["type": "readOnly", "networkAccess": false],
            "effort": "low", "outputSchema": JournalRules.schema, "environments": []
        ], timeout: 30)
        let deadline = Date().addingTimeInterval(120)
        while !journalFinished && journalFailure == nil && Date() < deadline {
            try Task.checkCancellation()
            guard process?.isRunning == true else { throw CodexClientError.disconnected }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if let journalFailure { throw JournalError.extractionFailed(journalFailure) }
        guard journalFinished, !journalOutput.isEmpty else {
            throw JournalError.extractionFailed("Note extraction timed out and will be retried.")
        }
        return try JSONDecoder().decode(JournalExtraction.self, from: Data(journalOutput.utf8)).notes
    }

    /// Recover only a known pending turn after relaunch. No resuming/writer takeover.
    public func readJournalTurn(threadID: String, turnID: String) async throws -> (messages: [CodexMessage], complete: Bool) {
        try await ensureConnected()
        var cursor: String?
        var visited = Set<String>()
        for _ in 0..<12 {
            var params: [String: Any] = ["threadId": threadID, "limit": 25, "sortDirection": "desc", "itemsView": "summary"]
            if let cursor { params["cursor"] = cursor }
            let result = try await request(method: "thread/turns/list", params: params, timeout: 12)
            let turns = result["data"] as? [[String: Any]] ?? []
            if let turn = turns.first(where: { $0["id"] as? String == turnID }) {
                let messages = (turn["items"] as? [[String: Any]] ?? []).compactMap(Self.parseMessage).filter { $0.kind.isConversation }
                let status = turn["status"] as? String
                let finished = status == "completed" || status == "failed" || status == "interrupted"
                return (status == "completed" ? messages : messages.filter { $0.role == .user }, finished)
            }
            guard let next = result["nextCursor"] as? String, visited.insert(next).inserted else { break }
            cursor = next
        }
        throw JournalError.extractionFailed("The source turn for this pending journal entry could not be read yet.")
    }

    deinit {
        process?.terminate()
    }

    public func connect() async throws -> CodexHealth {
        if connecting {
            return try await withCheckedThrowingContinuation { continuation in
                connectionWaiters.append(continuation)
            }
        }
        if initialized, process?.isRunning == true {
            return try await healthCheck()
        }

        connecting = true
        do {
            let health = try await establishConnection()
            finishConnecting(with: .success(health))
            return health
        } catch {
            resetTransport(terminate: true, pendingError: CodexClientError.disconnected)
            finishConnecting(with: .failure(error))
            throw error
        }
    }

    private func establishConnection() async throws -> CodexHealth {
        if process != nil {
            resetTransport(terminate: true, pendingError: CodexClientError.disconnected)
        }
        try launchProcess()

        let initResult = try await request(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "bavbav_native",
                    "title": "Bavbav",
                    "version": "0.2.9"
                ],
                "capabilities": [
                    "experimentalApi": true
                ]
            ],
            timeout: 12
        )
        try sendNotification(method: "initialized", params: [:])
        initialized = true

        serverMetadata = ServerMetadata(
            codexHome: initResult["codexHome"] as? String ?? "",
            platform: initResult["platformOs"] as? String ?? "macos",
            userAgent: initResult["userAgent"] as? String ?? "Codex"
        )
        return try await performHealthCheck()
    }

    public func healthCheck() async throws -> CodexHealth {
        try await ensureConnected()
        return try await performHealthCheck()
    }

    public func setEventHandler(_ handler: (@Sendable (CodexServerEvent) -> Void)?) {
        eventHandler = handler
    }

    public func resolveInteraction(
        requestID: CodexRequestID,
        response: CodexInteractionResponse
    ) throws {
        guard let pendingRequest = pendingServerRequests[requestID] else {
            throw CodexClientError.invalidResponse("The interaction request is no longer pending")
        }

        let result: [String: Any]
        switch pendingRequest.method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            guard case .option(let decision) = response,
                  ["accept", "acceptForSession", "decline", "cancel"].contains(decision)
            else {
                throw CodexClientError.invalidResponse("Invalid approval decision")
            }
            result = ["decision": decision]

        case "execCommandApproval", "applyPatchApproval":
            guard case .option(let decision) = response else {
                throw CodexClientError.invalidResponse("Invalid legacy approval decision")
            }
            switch decision {
            case "accept": result = ["decision": "approved"]
            case "acceptForSession": result = ["decision": "approved_for_session"]
            case "decline":
                result = ["decision": ["denied": ["rejection": "User declined in Bavbav."]]]
            case "cancel": result = ["decision": "abort"]
            default:
                throw CodexClientError.invalidResponse("Invalid legacy approval decision")
            }

        case "item/permissions/requestApproval":
            guard case .option(let decision) = response else {
                throw CodexClientError.invalidResponse("Invalid permission decision")
            }
            switch decision {
            case "permissionTurn", "permissionSession":
                result = [
                    "permissions": pendingRequest.params["permissions"] as? [String: Any] ?? [:],
                    "scope": decision == "permissionSession" ? "session" : "turn"
                ]
            case "decline", "cancel":
                result = ["permissions": [:], "scope": "turn"]
            default:
                throw CodexClientError.invalidResponse("Invalid permission decision")
            }

        case "item/tool/requestUserInput":
            guard case .answers(let answers) = response else {
                throw CodexClientError.invalidResponse("User answer is missing")
            }
            result = [
                "answers": answers.mapValues { ["answers": $0] }
            ]

        case "mcpServer/elicitation/request":
            switch response {
            case .form(let action, let content):
                result = action == "accept"
                    ? ["action": action, "content": content.mapValues(\.jsonValue)]
                    : ["action": action, "content": NSNull()]
            case .option(let action) where ["accept", "decline", "cancel"].contains(action):
                result = ["action": action, "content": NSNull()]
            default:
                throw CodexClientError.invalidResponse("Invalid MCP interaction response")
            }

        default:
            throw CodexClientError.invalidResponse("Unsupported interaction request")
        }

        try writeJSON(["id": requestID.jsonValue, "result": result])
        pendingServerRequests.removeValue(forKey: requestID)
        eventHandler?(.interactionResolved(
            requestID: requestID,
            threadID: pendingRequest.params["threadId"] as? String
                ?? pendingRequest.params["conversationId"] as? String
        ))
    }

    private func performHealthCheck() async throws -> CodexHealth {
        async let accountCall = request(
            method: "account/read",
            params: ["refreshToken": false],
            timeout: 10
        )
        async let modelCall = request(
            method: "model/list",
            params: ["limit": 1, "includeHidden": false],
            timeout: 10
        )
        async let historyCall = request(
            method: "thread/list",
            params: Self.threadListParams(limit: 1),
            timeout: 20
        )

        let (account, models, history) = try await (accountCall, modelCall, historyCall)
        let accountObject = account["account"] as? [String: Any]
        let requiresAuth = account["requiresOpenaiAuth"] as? Bool ?? true
        let authenticated = !requiresAuth || accountObject != nil
        let modelData = models["data"] as? [[String: Any]] ?? []
        let historyData = history["data"] as? [[String: Any]]

        return CodexHealth(
            codexHome: serverMetadata.codexHome,
            platform: serverMetadata.platform,
            userAgent: serverMetadata.userAgent,
            accountType: accountObject?["type"] as? String,
            authenticated: authenticated,
            historyAvailable: historyData != nil,
            modelAvailable: !modelData.isEmpty
        )
    }

    public func listThreads(limit: Int = 200, cwd: String? = nil) async throws -> [CodexThread] {
        try await ensureConnected()
        guard limit > 0 else { return [] }

        let canonicalCWD = cwd.map(ProjectCatalog.canonicalPath)
        var threads: [CodexThread] = []
        var cursor: String?
        var seenCursors = Set<String>()

        while threads.count < limit {
            let pageSize = min(100, limit - threads.count)
            let result = try await request(
                method: "thread/list",
                params: Self.threadListParams(limit: pageSize, cursor: cursor, cwd: canonicalCWD),
                timeout: 30
            )
            guard let rows = result["data"] as? [[String: Any]] else {
                throw CodexClientError.invalidResponse("thread/list response is missing data")
            }

            for row in rows {
                guard let thread = Self.parseThread(row) else { continue }
                threadMetadata[thread.id] = Self.parseThreadMetadata(row)
                threads.append(thread)
                if threads.count == limit { break }
            }

            guard
                !rows.isEmpty,
                let nextCursor = result["nextCursor"] as? String,
                !nextCursor.isEmpty,
                seenCursors.insert(nextCursor).inserted
            else { break }
            cursor = nextCursor
        }
        return threads
    }

    public func listModels(limit: Int = 100) async throws -> [CodexModelDescriptor] {
        try await ensureConnected()
        guard limit > 0 else { return [] }

        var models: [CodexModelDescriptor] = []
        var cursor: String?
        var seenCursors = Set<String>()

        while models.count < limit {
            var params: [String: Any] = [
                "limit": min(100, limit - models.count),
                "includeHidden": false
            ]
            if let cursor { params["cursor"] = cursor }
            let result = try await request(method: "model/list", params: params, timeout: 12)
            guard let rows = result["data"] as? [[String: Any]] else {
                throw CodexClientError.invalidResponse("model/list response is missing data")
            }
            models.append(contentsOf: rows.compactMap(Self.parseModel))

            guard
                !rows.isEmpty,
                let nextCursor = result["nextCursor"] as? String,
                !nextCursor.isEmpty,
                seenCursors.insert(nextCursor).inserted
            else { break }
            cursor = nextCursor
        }
        return Array(models.prefix(limit))
    }

    /// Refresh a long-running UI's catalog without restarting its turn transport.
    /// This short-lived connection never resumes a thread or starts a turn.
    public static func readFreshModelCatalog() async throws -> [CodexModelDescriptor] {
        let catalogClient = CodexAppServer()
        do {
            let models = try await catalogClient.listModels(limit: 100)
            await catalogClient.shutdown()
            return models
        } catch {
            await catalogClient.shutdown()
            throw error
        }
    }

    public func readRateLimits() async throws -> CodexRateLimits {
        try await ensureConnected()
        let result = try await request(
            method: "account/rateLimits/read",
            params: nil,
            timeout: 12
        )
        guard let limits = Self.parsePreferredRateLimits(result) else {
            throw CodexClientError.invalidResponse("account/rateLimits/read response is missing limits")
        }
        return limits
    }

    public func readAccountUsage(threadID: String? = nil) async throws -> CodexAccountUsage {
        try await ensureConnected()
        let params = threadID.map { ["threadId": $0] }
        let result = try await request(
            method: "account/usage/read",
            params: params,
            timeout: 12
        )
        guard let summary = result["summary"] as? [String: Any] else {
            throw CodexClientError.invalidResponse("account/usage/read response is missing summary")
        }
        let dailyRows = result["dailyUsageBuckets"] as? [[String: Any]] ?? []
        let daily = dailyRows.compactMap { row -> CodexDailyUsage? in
            guard
                let startDate = row["startDate"] as? String,
                let tokens = Self.int64Value(row["tokens"])
            else { return nil }
            return CodexDailyUsage(startDate: startDate, tokens: tokens)
        }
        return CodexAccountUsage(
            lifetimeTokens: Self.int64Value(summary["lifetimeTokens"]),
            peakDailyTokens: Self.int64Value(summary["peakDailyTokens"]),
            currentStreakDays: Self.intValue(summary["currentStreakDays"]),
            daily: daily
        )
    }

    @discardableResult
    public func resumeThread(
        id: String,
        executionMode: CodexExecutionMode = .workspace
    ) async throws -> [String: Any] {
        try await ensureConnected()
        if resumedThreadIDs.contains(id) { return [:] }
        var params: [String: Any] = ["threadId": id, "excludeTurns": true]
        switch executionMode {
        case .workspace:
            break
        case .readOnly:
            params["sandbox"] = "read-only"
            params["approvalPolicy"] = "never"
        case .fullAccess:
            params["sandbox"] = "danger-full-access"
            params["approvalPolicy"] = "never"
        }
        let result = try await request(
            method: "thread/resume",
            params: params,
            timeout: 30
        )
        resumedThreadIDs.insert(id)
        runtimeByThreadID[id] = Self.parseRuntime(result)
        return result
    }

    public func forkThread(
        id: String,
        cwd: String? = nil,
        model: String? = nil,
        ephemeral: Bool = false,
        executionMode: CodexExecutionMode = .workspace
    ) async throws -> CodexThreadFork {
        try await ensureConnected()
        var params: [String: Any] = [
            "threadId": id,
            "ephemeral": ephemeral,
            "excludeTurns": true,
        ]
        switch executionMode {
        case .workspace:
            params["sandbox"] = "workspace-write"
            params["approvalPolicy"] = "on-request"
        case .readOnly:
            params["sandbox"] = "read-only"
            params["approvalPolicy"] = "never"
        case .fullAccess:
            params["sandbox"] = "danger-full-access"
            params["approvalPolicy"] = "never"
        }
        if let cwd, !cwd.isEmpty { params["cwd"] = ProjectCatalog.canonicalPath(cwd) }
        if let model, !model.isEmpty { params["model"] = model }

        let result = try await request(method: "thread/fork", params: params, timeout: 30)
        guard
            let row = result["thread"] as? [String: Any],
            let thread = Self.parseThread(row)
        else {
            throw CodexClientError.invalidResponse("thread/fork response is missing thread")
        }
        let runtime = Self.parseRuntime(result)
        resumedThreadIDs.insert(thread.id)
        threadMetadata[thread.id] = Self.parseThreadMetadata(row)
        runtimeByThreadID[thread.id] = runtime
        return CodexThreadFork(thread: thread, runtime: runtime)
    }

    /// Returns the most recently persisted model and effort without claiming
    /// the thread's writer slot. This keeps Cmd+4 accurate even when the Codex
    /// desktop app currently owns the live stream.
    public func readPersistedRuntime(threadID: String) async throws -> CodexThreadRuntime {
        try await ensureConnected()
        if let cached = runtimeByThreadID[threadID], cached != .unknown { return cached }

        let path: String?
        if let cachedPath = rolloutPathByThreadID[threadID] {
            path = cachedPath
        } else {
            let codexHome = serverMetadata.codexHome
            path = await Task.detached(priority: .utility) {
                Self.findRolloutPath(codexHome: codexHome, threadID: threadID)
            }.value
            if let path { rolloutPathByThreadID[threadID] = path }
        }

        guard let path else { return .unknown }
        let runtime = await Task.detached(priority: .utility) {
            Self.readLatestRuntime(path: path)
        }.value
        runtimeByThreadID[threadID] = runtime
        return runtime
    }

    public func startTurn(
        threadID: String,
        text: String,
        model: String? = nil,
        effort: String? = nil,
        clientUserMessageID: String? = nil,
        cwd: String? = nil,
        executionMode: CodexExecutionMode = .workspace,
        attachments: [ComposerAttachment] = [],
        collaborationMode: CodexCollaborationMode? = nil
    ) async throws -> CodexTurnStart {
        // Validate durable attachments before claiming the writer slot. A
        // missing screenshot must leave the draft recoverable, not send a
        // successful-looking text-only turn.
        let userInput = try ComposerInput.items(text: text, attachments: attachments)
        try await ensureConnected()
        _ = try await resumeThread(id: threadID, executionMode: executionMode)

        var params: [String: Any] = [
            "threadId": threadID,
            "clientUserMessageId": clientUserMessageID ?? UUID().uuidString,
            "input": userInput
        ]
        switch executionMode {
        case .workspace:
            var sandbox: [String: Any] = [
                "type": "workspaceWrite",
                "networkAccess": false
            ]
            if let cwd, !cwd.isEmpty {
                sandbox["writableRoots"] = [ProjectCatalog.canonicalPath(cwd)]
                params["cwd"] = ProjectCatalog.canonicalPath(cwd)
            }
            params["approvalPolicy"] = "on-request"
            params["sandboxPolicy"] = sandbox
        case .readOnly:
            params["approvalPolicy"] = "never"
            params["sandboxPolicy"] = [
                "type": "readOnly",
                "networkAccess": false
            ]
        case .fullAccess:
            params["approvalPolicy"] = "never"
            params["sandboxPolicy"] = ["type": "dangerFullAccess"]
        }
        if let model, !model.isEmpty { params["model"] = model }
        if let effort, !effort.isEmpty { params["effort"] = effort }
        if let collaborationMode {
            params["collaborationMode"] = try await collaborationSettings(
                threadID: threadID, mode: collaborationMode, model: model, effort: effort
            )
        }

        let result = try await request(method: "turn/start", params: params, timeout: 30)
        guard
            let turn = result["turn"] as? [String: Any],
            let id = turn["id"] as? String
        else {
            throw CodexClientError.invalidResponse("turn/start response is missing turn")
        }
        return CodexTurnStart(id: id, status: turn["status"] as? String ?? "inProgress")
    }

    /// Adds user guidance to the currently active turn without starting a new
    /// turn. App Server requires the exact active turn id as a precondition.
    public func steerTurn(
        threadID: String,
        turnID: String,
        text: String,
        clientUserMessageID: String? = nil,
        attachments: [ComposerAttachment] = []
    ) async throws -> String {
        let userInput = try ComposerInput.items(text: text, attachments: attachments)
        try await ensureConnected()
        var params: [String: Any] = [
            "threadId": threadID,
            "expectedTurnId": turnID,
            "input": userInput
        ]
        if let clientUserMessageID, !clientUserMessageID.isEmpty {
            params["clientUserMessageId"] = clientUserMessageID
        }

        let result = try await request(method: "turn/steer", params: params, timeout: 30)
        guard let returnedTurnID = result["turnId"] as? String else {
            throw CodexClientError.invalidResponse("turn/steer response is missing turnId")
        }
        return returnedTurnID
    }

    private func collaborationSettings(
        threadID: String,
        mode: CodexCollaborationMode,
        model: String?,
        effort: String?
    ) async throws -> [String: Any] {
        let explicitModel = model.flatMap { $0.isEmpty ? nil : $0 }
        let explicitEffort = effort.flatMap { $0.isEmpty ? nil : $0 }
        let runtime: CodexThreadRuntime
        if explicitModel != nil, explicitEffort != nil {
            // Both settings are already authoritative. In particular, a new
            // chat may not have a turn_context yet: do not scan its rollout or
            // the entire sessions directory just to discard the result.
            runtime = .unknown
        } else {
            runtime = try await readPersistedRuntime(threadID: threadID)
        }
        var resolvedModel = explicitModel ?? runtime.model
        var resolvedEffort = explicitEffort
        if resolvedEffort == nil, resolvedModel == runtime.model {
            resolvedEffort = runtime.effort
        }
        if resolvedModel == nil || resolvedEffort == nil {
            let models = try await listModels()
            if resolvedModel == nil { resolvedModel = models.first(where: \.isDefault)?.model }
            if resolvedEffort == nil,
               let descriptor = models.first(where: { $0.model == resolvedModel || $0.id == resolvedModel }) {
                resolvedEffort = descriptor.defaultReasoningEffort
            }
        }
        guard let resolvedModel, !resolvedModel.isEmpty else {
            throw CodexClientError.invalidResponse("No compatible model is available for this mode. Select a model first.")
        }
        return [
            "mode": mode.rawValue,
            "settings": [
                "model": resolvedModel,
                "reasoning_effort": resolvedEffort as Any? ?? NSNull(),
                // Explicit null asks Codex to supply the mode's own built-in
                // instructions. An empty string would not mean the same thing.
                "developer_instructions": NSNull()
            ] as [String: Any]
        ]
    }

    /// Reads stored goal state without resuming the chat or claiming its writer.
    public func readThreadGoal(threadID: String) async throws -> CodexThreadGoal? {
        try await ensureConnected()
        let result = try await request(method: "thread/goal/get", params: ["threadId": threadID], timeout: 15)
        guard let raw = result["goal"], !(raw is NSNull) else { return nil }
        return try Self.parseGoal(raw, threadID: threadID)
    }

    /// Called only when the user explicitly saves a goal in the composer menu.
    /// Omission of a token budget deliberately leaves it server-owned.
    public func setThreadGoal(
        threadID: String,
        objective: String,
        tokenBudget: Int64? = nil
    ) async throws -> CodexThreadGoal {
        let objective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !objective.isEmpty, objective.unicodeScalars.count <= 4_000 else {
            throw CodexClientError.invalidResponse("The goal must contain 1–4,000 characters.")
        }
        if let tokenBudget, tokenBudget <= 0 {
            throw CodexClientError.invalidResponse("The goal token limit must be greater than zero.")
        }
        try await ensureConnected()
        var params: [String: Any] = ["threadId": threadID, "objective": objective, "status": "active"]
        if let tokenBudget { params["tokenBudget"] = tokenBudget }
        let result = try await request(method: "thread/goal/set", params: params, timeout: 15)
        guard let raw = result["goal"] else {
            throw CodexClientError.invalidResponse("thread/goal/set response is missing goal")
        }
        return try Self.parseGoal(raw, threadID: threadID)
    }

    @discardableResult
    public func clearThreadGoal(threadID: String) async throws -> Bool {
        try await ensureConnected()
        let result = try await request(method: "thread/goal/clear", params: ["threadId": threadID], timeout: 15)
        guard let cleared = result["cleared"] as? Bool else {
            throw CodexClientError.invalidResponse("thread/goal/clear response is missing result")
        }
        return cleared
    }

    private static func parseGoal(_ raw: Any, threadID: String) throws -> CodexThreadGoal {
        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let goal = try? JSONDecoder().decode(CodexThreadGoal.self, from: data),
              goal.threadID == threadID else {
            throw CodexClientError.invalidResponse("Invalid conversation goal response")
        }
        return goal
    }

    public func startThread(
        cwd: String,
        model: String? = nil,
        ephemeral: Bool = false,
        sandbox: String? = nil,
        approvalPolicy: String? = nil
    ) async throws -> CodexThread {
        try await ensureConnected()
        var params: [String: Any] = [
            "cwd": ProjectCatalog.canonicalPath(cwd),
            "ephemeral": ephemeral
        ]
        if let model, !model.isEmpty { params["model"] = model }
        if let sandbox, !sandbox.isEmpty { params["sandbox"] = sandbox }
        if let approvalPolicy, !approvalPolicy.isEmpty {
            params["approvalPolicy"] = approvalPolicy
        }
        let result = try await request(method: "thread/start", params: params, timeout: 30)
        guard
            let row = result["thread"] as? [String: Any],
            let thread = Self.parseThread(row)
        else {
            throw CodexClientError.invalidResponse("thread/start response is missing thread")
        }
        resumedThreadIDs.insert(thread.id)
        threadMetadata[thread.id] = Self.parseThreadMetadata(row)
        let runtime = Self.parseRuntime(result)
        if let model = runtime.model, !model.isEmpty {
            runtimeByThreadID[thread.id] = runtime
        }
        return thread
    }

    public func setThreadName(id: String, name: String) async throws {
        try await ensureConnected()
        _ = try await request(
            method: "thread/name/set",
            params: ["threadId": id, "name": name],
            timeout: 15
        )
    }

    public func readThread(id: String, maxMessages: Int? = nil) async throws -> [CodexMessage] {
        let indexed = try await readIndexedThread(id: id, maxMessages: maxMessages)
        guard maxMessages == nil || maxMessages! > 0 else { return [] }
        var path = rolloutPathByThreadID[id]
        if path == nil, !serverMetadata.codexHome.isEmpty {
            let home = serverMetadata.codexHome
            path = await Task.detached(priority: .utility) { Self.findRolloutPath(codexHome: home, threadID: id) }.value
            if let path { rolloutPathByThreadID[id] = path }
        }
        guard let path else { return indexed }
        do {
            let persisted = try await conversationRollout.read(path: path, threadID: id)
            let merged = RolloutConversationReader.merge(indexed, with: persisted)
            return maxMessages.map { Array(merged.suffix($0)) } ?? merged
        } catch is CancellationError { throw CancellationError() }
        catch { return indexed } // A missing/unreadable log must not hide API history.
    }

    private func readIndexedThread(id: String, maxMessages: Int?) async throws -> [CodexMessage] {
        try await ensureConnected()
        if let maxMessages, maxMessages <= 0 { return [] }
        let metadata: ThreadMetadata
        if let cached = threadMetadata[id] {
            metadata = cached
        } else {
            metadata = try await readThreadMetadata(id: id)
        }

        do {
            // Summary pages contain the display conversation without shipping
            // persisted command output and other potentially enormous items.
            let messages = try await readMessagesByTurnSummary(
                threadID: id,
                messageLimit: maxMessages
            )
            if !messages.isEmpty || metadata.historyMode == "paginated" { return messages }
            return try await readMessagesByLegacyThread(threadID: id, messageLimit: maxMessages)
        } catch where Self.isUnsupportedPagination(error) {
            if metadata.historyMode == "paginated" {
                // Some transitional app-server versions expose item pagination
                // but not turn summaries for paginated records.
                return try await readMessagesByItemPage(
                    threadID: id,
                    messageLimit: maxMessages
                )
            }
            return try await readMessagesByLegacyThread(
                threadID: id,
                messageLimit: maxMessages
            )
        }
    }

    /// Loads persisted items, including reasoning and subagents not included in
    /// compact summaries. The UI discards technical rows when commands are hidden.
    public func readThreadActivity(id: String) async throws -> [CodexMessage] {
        try await ensureConnected()
        let metadata: ThreadMetadata
        if let cached = threadMetadata[id] {
            metadata = cached
        } else {
            metadata = try await readThreadMetadata(id: id)
        }

        if metadata.historyMode == "paginated" {
            return try await readMessagesByItemPage(threadID: id, messageLimit: nil)
        }
        do {
            return try await readMessagesByFullTurn(threadID: id)
        } catch where Self.isUnsupportedPagination(error) {
            do {
                return try await readMessagesByItemPage(threadID: id, messageLimit: nil)
            } catch where Self.isUnsupportedPagination(error) {
                return try await readMessagesByLegacyThread(threadID: id, messageLimit: nil)
            }
        }
    }

    /// Lightweight read used by diagnostics. It verifies that the selected
    /// Codex thread is addressable without transferring its full turn history.
    @discardableResult
    public func probeThread(id: String) async throws -> String {
        try await ensureConnected()
        return try await readThreadMetadata(id: id).historyMode
    }

    private func readThreadMetadata(id: String) async throws -> ThreadMetadata {
        let result = try await request(
            method: "thread/read",
            params: ["threadId": id, "includeTurns": false],
            timeout: 12
        )
        guard let thread = result["thread"] as? [String: Any], thread["id"] as? String == id else {
            throw CodexClientError.invalidResponse("thread/read response is missing the expected thread")
        }
        let metadata = Self.parseThreadMetadata(thread)
        threadMetadata[id] = metadata
        return metadata
    }

    /// Reads newest persisted items in bounded pages. Unlike
    /// `thread/read(includeTurns: true)`, this never hydrates a complete rollout.
    private func readMessagesByItemPage(
        threadID: String,
        messageLimit: Int?
    ) async throws -> [CodexMessage] {
        let maximumPages = 256
        var newestFirst: [CodexMessage] = []
        var cursor: String?
        var seenCursors = Set<String>()

        for pageIndex in 0..<maximumPages {
            try Task.checkCancellation()
            var params: [String: Any] = [
                "threadId": threadID,
                "limit": 100,
                "sortDirection": "desc"
            ]
            if let cursor { params["cursor"] = cursor }

            let result = try await request(
                method: "thread/items/list",
                params: params,
                timeout: 12
            )
            guard let entries = result["data"] as? [[String: Any]] else {
                throw CodexClientError.invalidResponse("thread/items/list response is missing data")
            }

            for entry in entries {
                guard
                    let item = entry["item"] as? [String: Any],
                    let message = Self.parseMessage(item)
                else { continue }
                newestFirst.append(message)
                if let messageLimit, newestFirst.count >= messageLimit {
                    return Array(newestFirst.prefix(messageLimit).reversed())
                }
            }

            guard
                !entries.isEmpty,
                let nextCursor = result["nextCursor"] as? String,
                !nextCursor.isEmpty,
                seenCursors.insert(nextCursor).inserted
            else { break }
            if pageIndex == maximumPages - 1 {
                throw CodexClientError.invalidResponse("Conversation items exceed the safe pagination limit")
            }
            cursor = nextCursor
        }
        return Array(newestFirst.reversed())
    }

    /// Legacy rollouts do not necessarily support item paging. A turn summary
    /// contains only display-oriented items, so each response stays bounded even
    /// when the underlying rollout contains very large tool logs.
    private func readMessagesByTurnSummary(
        threadID: String,
        messageLimit: Int?
    ) async throws -> [CodexMessage] {
        let maximumPages = 256
        var newestFirstTurns: [[String: Any]] = []
        var visibleMessageCount = 0
        var cursor: String?
        var seenCursors = Set<String>()

        for pageIndex in 0..<maximumPages {
            try Task.checkCancellation()
            var params: [String: Any] = [
                "threadId": threadID,
                "limit": 100,
                "sortDirection": "desc",
                "itemsView": "summary"
            ]
            if let cursor { params["cursor"] = cursor }

            let result = try await request(
                method: "thread/turns/list",
                params: params,
                timeout: 12
            )
            guard let turns = result["data"] as? [[String: Any]] else {
                throw CodexClientError.invalidResponse("thread/turns/list response is missing data")
            }

            newestFirstTurns.append(contentsOf: turns)
            visibleMessageCount += turns.reduce(into: 0) { count, turn in
                let items = turn["items"] as? [[String: Any]] ?? []
                count += items.reduce(into: 0) { itemCount, item in
                    if Self.parseMessage(item) != nil { itemCount += 1 }
                }
            }
            if let messageLimit, visibleMessageCount >= messageLimit { break }

            guard
                !turns.isEmpty,
                let nextCursor = result["nextCursor"] as? String,
                !nextCursor.isEmpty,
                seenCursors.insert(nextCursor).inserted
            else { break }
            if pageIndex == maximumPages - 1 {
                throw CodexClientError.invalidResponse("Conversation history exceeds the safe pagination limit")
            }
            cursor = nextCursor
        }

        var chronological: [CodexMessage] = []
        for turn in newestFirstTurns.reversed() {
            let items = turn["items"] as? [[String: Any]] ?? []
            chronological.append(contentsOf: items.compactMap(Self.parseMessage))
        }
        if let messageLimit { return Array(chronological.suffix(messageLimit)) }
        return chronological
    }

    private func readMessagesByFullTurn(threadID: String) async throws -> [CodexMessage] {
        let maximumPages = 512
        var newestFirstTurns: [[String: Any]] = []
        var cursor: String?
        var seenCursors = Set<String>()

        for pageIndex in 0..<maximumPages {
            try Task.checkCancellation()
            var params: [String: Any] = [
                "threadId": threadID,
                "limit": 20,
                "sortDirection": "desc",
                "itemsView": "full"
            ]
            if let cursor { params["cursor"] = cursor }
            let result = try await request(
                method: "thread/turns/list",
                params: params,
                timeout: 30
            )
            guard let turns = result["data"] as? [[String: Any]] else {
                throw CodexClientError.invalidResponse("thread/turns/list response is missing data")
            }
            newestFirstTurns.append(contentsOf: turns)

            guard
                !turns.isEmpty,
                let nextCursor = result["nextCursor"] as? String,
                !nextCursor.isEmpty,
                seenCursors.insert(nextCursor).inserted
            else { break }
            if pageIndex == maximumPages - 1 {
                throw CodexClientError.invalidResponse("Full activity history exceeds the safe pagination limit")
            }
            cursor = nextCursor
        }

        return newestFirstTurns.reversed().flatMap { turn in
            (turn["items"] as? [[String: Any]] ?? []).compactMap(Self.parseMessage)
        }
    }

    private func readMessagesByLegacyThread(
        threadID: String,
        messageLimit: Int?
    ) async throws -> [CodexMessage] {
        let result = try await request(
            method: "thread/read",
            params: ["threadId": threadID, "includeTurns": true],
            timeout: 30
        )
        guard let thread = result["thread"] as? [String: Any] else {
            throw CodexClientError.invalidResponse("thread/read response is missing thread")
        }
        let turns = thread["turns"] as? [[String: Any]] ?? []
        let messages = turns.flatMap { turn in
            (turn["items"] as? [[String: Any]] ?? []).compactMap(Self.parseMessage)
        }
        if let messageLimit { return Array(messages.suffix(messageLimit)) }
        return messages
    }

    private static func parseMessage(_ item: [String: Any]) -> CodexMessage? {
        guard var message = parseMessageContent(item) else { return nil }
        let images = MessageImagePayload.images(in: item)
        if !images.isEmpty { message.images = images }
        for key in ["createdAt", "created_at", "timestamp", "createdAtMs"] {
            guard let value = item[key] else { continue }
            if let number = value as? NSNumber {
                let raw = number.doubleValue
                message.timestamp = Date(timeIntervalSince1970: key.hasSuffix("Ms") || raw > 100_000_000_000 ? raw / 1000 : raw)
            } else if let string = value as? String {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                message.timestamp = formatter.date(from: string)
                if message.timestamp == nil {
                    formatter.formatOptions = [.withInternetDateTime]
                    message.timestamp = formatter.date(from: string)
                }
            }
            if message.timestamp != nil { break }
        }
        return message
    }

    private static func parseMessageContent(_ item: [String: Any]) -> CodexMessage? {
        guard let type = item["type"] as? String else { return nil }
        let id = item["id"] as? String ?? UUID().uuidString
        switch type {
        case "userMessage":
            let content = item["content"] as? [[String: Any]] ?? []
            let text = content.compactMap { part -> String? in
                switch part["type"] as? String {
                case "text":
                    return part["text"] as? String
                case "image":
                    let url = part["url"] as? String ?? "attached image"
                    return url.hasPrefix("data:") ? "[IMAGE]" : "[IMAGE] \(url)"
                case "localImage":
                    return "[LOCAL IMAGE] \(part["path"] as? String ?? "attached image")"
                case "audio":
                    return "[AUDIO] \(part["url"] as? String ?? "attached audio")"
                case "localAudio":
                    return "[LOCAL AUDIO] \(part["path"] as? String ?? "attached audio")"
                case "skill":
                    return "[SKILL] \(part["name"] as? String ?? "skill")"
                case "mention":
                    return "[MENTION] \(part["name"] as? String ?? part["path"] as? String ?? "file")"
                default:
                    return nil
                }
            }.joined(separator: "\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return CodexMessage(id: id, role: .user, text: text)
        case "hookPrompt":
            let fragments = item["fragments"] as? [[String: Any]] ?? []
            return operationalMessage(
                id: id,
                kind: .system,
                label: "HOOK PROMPT",
                body: fragments.compactMap { $0["text"] as? String }.joined(separator: "\n")
            )
        case "agentMessage":
            guard
                let text = item["text"] as? String,
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            let phase = item["phase"] as? String
            return CodexMessage(
                id: id,
                role: .agent,
                text: text,
                kind: .agent,
                title: phase == "commentary" ? "CODEX · WORKING" : nil,
                status: phase
            )
        case "plan":
            return operationalMessage(id: id, kind: .plan, label: "PLAN", body: item["text"] as? String)
        case "commandExecution":
            let command = item["command"] as? String ?? "command"
            let status = item["status"] as? String ?? "unknown"
            let output = (item["aggregatedOutput"] as? String)
                .map { boundedText($0, limit: 20_000) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let body = (["$ \(command)", output].compactMap { $0 }).joined(separator: "\n")
            return operationalMessage(
                id: id,
                kind: .command,
                label: "COMMAND",
                body: body,
                status: status
            )
        case "fileChange":
            let changes = item["changes"] as? [[String: Any]] ?? []
            let lines = changes.compactMap { change -> String? in
                guard let path = change["path"] as? String else { return nil }
                let kindObject = change["kind"] as? [String: Any]
                let kind = (change["kind"] as? String
                    ?? kindObject?["type"] as? String
                    ?? "change").uppercased()
                let diff = (change["diff"] as? String).map { boundedText($0, limit: 20_000) }
                return (["\(kind) · \(path)", diff].compactMap { $0 }).joined(separator: "\n")
            }
            return operationalMessage(
                id: id,
                kind: .fileChange,
                label: "FILE CHANGE",
                body: lines.joined(separator: "\n\n"),
                status: item["status"] as? String ?? "unknown"
            )
        case "mcpToolCall":
            let server = item["server"] as? String ?? "MCP"
            let tool = item["tool"] as? String ?? "tool"
            let arguments = renderJSON(item["arguments"])
            let result = renderJSON(item["result"])
            let error = renderJSON(item["error"])
            return operationalMessage(
                id: id,
                kind: .mcpTool,
                label: "APP TOOL · \(server) / \(tool)",
                body: ([arguments, result, error].compactMap { $0 }).joined(separator: "\n"),
                status: item["status"] as? String ?? "unknown"
            )
        case "dynamicToolCall":
            let tool = item["tool"] as? String ?? "tool"
            let arguments = renderJSON(item["arguments"])
            let content = renderJSON(item["contentItems"])
            return operationalMessage(
                id: id,
                kind: .dynamicTool,
                label: "TOOL · \(tool)",
                body: ([arguments, content].compactMap { $0 }).joined(separator: "\n"),
                status: item["status"] as? String ?? "unknown"
            )
        case "collabToolCall", "collabAgentToolCall":
            let tool = item["tool"] as? String ?? "collaboration"
            let prompt = item["prompt"] as? String
            return operationalMessage(
                id: id,
                kind: .collaboration,
                label: "COLLAB · \(tool)",
                body: prompt,
                status: item["status"] as? String ?? "unknown"
            )
        case "webSearch":
            let action = item["action"] as? [String: Any]
            let queries = action?["queries"] as? [String]
            let query = item["query"] as? String
                ?? action?["query"] as? String
                ?? queries?.joined(separator: "\n")
            return operationalMessage(id: id, kind: .webSearch, label: "WEB SEARCH", body: query)
        case "imageView":
            return operationalMessage(id: id, kind: .image, label: "IMAGE VIEW", body: item["path"] as? String)
        case "imageGeneration":
            return operationalMessage(
                id: id,
                kind: .image,
                label: "IMAGE GENERATION",
                body: (item["failure"] as? [String: Any])?["message"] as? String,
                status: item["status"] as? String
            )
        case "sleep":
            let milliseconds = int64Value(item["durationMs"]) ?? 0
            return operationalMessage(
                id: id,
                kind: .toolOutput,
                label: "SLEEP",
                body: String(format: "%.1f seconds", Double(milliseconds) / 1_000),
                status: "COMPLETED"
            )
        case "subAgentActivity":
            return operationalMessage(
                id: id,
                kind: .collaboration,
                label: "SUBAGENT",
                body: renderJSON(item),
                status: item["status"] as? String
            )
        case "functionCallOutput":
            let name = item["name"] as? String ?? "tool output"
            let outputItems = item["output"] as? [[String: Any]] ?? []
            let output = item["output"] as? String
                ?? outputItems.compactMap { $0["text"] as? String }.joined(separator: "\n")
            return operationalMessage(id: id, kind: .toolOutput, label: "TOOL OUTPUT · \(name)", body: output)
        case "enteredReviewMode":
            return operationalMessage(id: id, kind: .review, label: "REVIEW STARTED", body: renderJSON(item["review"]))
        case "exitedReviewMode":
            return operationalMessage(id: id, kind: .review, label: "REVIEW", body: renderJSON(item["review"]))
        case "contextCompaction":
            return operationalMessage(id: id, kind: .compaction, label: "CONTEXT COMPACTED", body: nil)
        case "reasoning":
            let stringSummaries = item["summary"] as? [String] ?? []
            let objectSummaries = item["summary"] as? [[String: Any]] ?? []
            let text = (stringSummaries + objectSummaries.compactMap { $0["text"] as? String })
                .joined(separator: "\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return operationalMessage(id: id, kind: .reasoning, label: "REASONING SUMMARY", body: text)
        case "message":
            let role = item["role"] as? String
            let content = item["content"] as? [[String: Any]] ?? []
            let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            guard !text.isEmpty || content.contains(where: { ["image", "input_image", "inputImage", "localImage"].contains($0["type"] as? String ?? "") }) else { return nil }
            return CodexMessage(id: id, role: role == "user" ? .user : .agent, text: text)
        default:
            return nil
        }
    }

    private static func operationalMessage(
        id: String,
        kind: CodexMessageKind,
        label: String,
        body: String?,
        status: String? = nil
    ) -> CodexMessage? {
        let cleanBody = body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return CodexMessage(
            id: id,
            role: .agent,
            text: cleanBody,
            kind: kind,
            title: label.uppercased(),
            status: status
        )
    }

    private static func boundedText(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return "[… earlier output hidden …]\n" + String(text.suffix(limit))
    }

    private static func renderJSON(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let text = value as? String { return boundedText(text, limit: 20_000) }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return String(describing: value) }
        return boundedText(text, limit: 20_000)
    }

    private static func parseModel(_ row: [String: Any]) -> CodexModelDescriptor? {
        guard
            let id = row["id"] as? String,
            let model = row["model"] as? String,
            let displayName = row["displayName"] as? String,
            let defaultEffort = row["defaultReasoningEffort"] as? String
        else { return nil }
        let efforts = (row["supportedReasoningEfforts"] as? [[String: Any]] ?? []).compactMap {
            option -> CodexReasoningEffort? in
            guard let value = option["reasoningEffort"] as? String else { return nil }
            return CodexReasoningEffort(
                id: value,
                description: option["description"] as? String ?? ""
            )
        }
        return CodexModelDescriptor(
            id: id,
            model: model,
            displayName: displayName,
            description: row["description"] as? String ?? "",
            isDefault: row["isDefault"] as? Bool ?? false,
            defaultReasoningEffort: defaultEffort,
            supportedReasoningEfforts: efforts
        )
    }

    private static func parsePreferredRateLimits(_ result: [String: Any]) -> CodexRateLimits? {
        if
            let byID = result["rateLimitsByLimitId"] as? [String: Any],
            let codex = byID["codex"] as? [String: Any],
            let parsed = parseRateLimits(codex)
        {
            return parsed
        }
        guard let snapshot = result["rateLimits"] as? [String: Any] else { return nil }
        return parseRateLimits(snapshot)
    }

    private static func parseRateLimits(_ snapshot: [String: Any]) -> CodexRateLimits? {
        let primary = (snapshot["primary"] as? [String: Any]).flatMap(parseRateLimitWindow)
        let secondary = (snapshot["secondary"] as? [String: Any]).flatMap(parseRateLimitWindow)
        guard primary != nil || secondary != nil else { return nil }
        return CodexRateLimits(
            limitID: snapshot["limitId"] as? String,
            limitName: snapshot["limitName"] as? String,
            planType: snapshot["planType"] as? String,
            primary: primary,
            secondary: secondary
        )
    }

    private static func parseRateLimitWindow(_ row: [String: Any]) -> CodexRateLimitWindow? {
        guard let usedPercent = intValue(row["usedPercent"]) else { return nil }
        let reset = int64Value(row["resetsAt"]).map {
            Date(timeIntervalSince1970: TimeInterval($0))
        }
        return CodexRateLimitWindow(
            usedPercent: usedPercent,
            durationMinutes: intValue(row["windowDurationMins"]),
            resetsAt: reset
        )
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let value = value as? Int { return value }
        return nil
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        return nil
    }

    private static func isUnsupportedPagination(_ error: Error) -> Bool {
        guard case CodexClientError.rpcError(let detail) = error else { return false }
        let normalized = detail.lowercased()
        return normalized.contains("not supported")
            || normalized.contains("unsupported")
            || normalized.contains("experimentalapi")
            || normalized.contains("method not found")
    }

    public func shutdown() {
        resetTransport(terminate: true, pendingError: CodexClientError.disconnected)
    }

    private static func threadListParams(
        limit: Int,
        cursor: String? = nil,
        cwd: String? = nil
    ) -> [String: Any] {
        var params: [String: Any] = [
            "limit": limit,
            "sortKey": "recency_at",
            "sortDirection": "desc",
            "archived": false,
            "sourceKinds": userFacingSources,
            // Foreground scan-and-repair can take minutes for large histories.
            // The local state DB contains the same user-facing records and lets
            // the overlay refresh without stalling its JSON-RPC connection.
            "useStateDbOnly": true
        ]
        if let cursor { params["cursor"] = cursor }
        if let cwd { params["cwd"] = cwd }
        return params
    }

    private static func parseThreadMetadata(_ row: [String: Any]) -> ThreadMetadata {
        ThreadMetadata(historyMode: row["historyMode"] as? String ?? "legacy")
    }

    private static func parseRuntime(_ row: [String: Any]) -> CodexThreadRuntime {
        CodexThreadRuntime(
            model: row["model"] as? String,
            effort: row["reasoningEffort"] as? String ?? row["effort"] as? String
        )
    }

    private static func findRolloutPath(codexHome: String, threadID: String) -> String? {
        guard !codexHome.isEmpty else { return nil }
        let root = URL(fileURLWithPath: codexHome, isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        let suffix = "-\(threadID).jsonl"
        for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(suffix) {
            return url.path
        }
        return nil
    }

    private static func readLatestRuntime(path: String) -> CodexThreadRuntime {
        guard let data = try? Data(
            contentsOf: URL(fileURLWithPath: path),
            options: [.mappedIfSafe]
        ), !data.isEmpty else { return .unknown }

        let marker = Data("\"type\":\"turn_context\"".utf8)
        var lineEnd = data.endIndex
        while lineEnd > data.startIndex {
            let searchEnd = data.index(before: lineEnd)
            let lineStart: Data.Index
            if let newline = data[data.startIndex...searchEnd].lastIndex(of: 0x0A) {
                lineStart = data.index(after: newline)
            } else {
                lineStart = data.startIndex
            }

            let line = data[lineStart..<lineEnd]
            if line.range(of: marker) != nil,
               let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
               object["type"] as? String == "turn_context",
               let payload = object["payload"] as? [String: Any] {
                let runtime = CodexThreadRuntime(
                    model: payload["model"] as? String,
                    effort: payload["effort"] as? String ?? payload["reasoningEffort"] as? String
                )
                if runtime != .unknown { return runtime }
            }

            guard lineStart > data.startIndex else { break }
            lineEnd = data.index(before: lineStart)
        }
        return .unknown
    }

    private static func parseThread(_ row: [String: Any]) -> CodexThread? {
        guard
            let id = row["id"] as? String,
            let cwd = row["cwd"] as? String
        else { return nil }

        let preview = (row["preview"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitName = (row["name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let previewTitle = preview
            .split(separator: "\n", maxSplits: 1)
            .first
            .map(String.init)
        let title = [explicitName, previewTitle]
            .compactMap { $0 }
            .first { !$0.isEmpty } ?? "Untitled chat"

        let statusObject = row["status"] as? [String: Any]
        let statusText = statusObject?["type"] as? String ?? row["status"] as? String ?? "unknown"
        let state = ThreadRunState(rawValue: statusText) ?? .unknown
        let updated = (row["recencyAt"] as? NSNumber)?.doubleValue
            ?? (row["updatedAt"] as? NSNumber)?.doubleValue
            ?? 0

        return CodexThread(
            id: id,
            projectID: row["projectId"] as? String,
            cwd: ProjectCatalog.canonicalPath(cwd),
            title: title,
            preview: preview,
            updatedAt: Date(timeIntervalSince1970: updated),
            state: state,
            hasMessages: !preview.isEmpty
        )
    }

    private func launchProcess() throws {
        if process?.isRunning == true { return }
        if process != nil {
            resetTransport(terminate: false, pendingError: CodexClientError.disconnected)
        }

        let executable = try Self.resolveCodexExecutable()
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        processGeneration &+= 1
        let generation = processGeneration

        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        if journalWorker {
            // Process-local restrictions: never edit the user's Codex configuration.
            process.arguments! += ["-c", "mcp_servers={}", "-c", "web_search=\"disabled\"",
                "-c", "features.shell_tool=false", "-c", "features.unified_exec=false",
                "-c", "features.apps=false", "-c", "features.multi_agent=false", "-c", "agents.enabled=false",
                "-c", "features.hooks=false", "-c", "features.memories=false", "-c", "features.remote_plugin=false",
                "-c", "features.shell_snapshot=false"]
        }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdout = stdoutPipe.fileHandleForReading
        let stderr = stderrPipe.fileHandleForReading
        let stdoutReader = OrderedChunkReader()
        stdout.readabilityHandler = { [weak self] handle in
            let chunk = stdoutReader.read(from: handle)
            let data = chunk.data
            guard !data.isEmpty else { return }
            Task {
                await self?.ingest(
                    data,
                    generation: generation,
                    sequence: chunk.sequence
                )
            }
        }
        stderr.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.rememberError(data, generation: generation) }
        }
        process.terminationHandler = { [weak self] task in
            Task {
                await self?.processEnded(
                    status: task.terminationStatus,
                    generation: generation
                )
            }
        }

        do {
            try process.run()
        } catch {
            stdout.readabilityHandler = nil
            stderr.readabilityHandler = nil
            throw CodexClientError.processFailed(error.localizedDescription)
        }

        self.process = process
        self.input = stdinPipe.fileHandleForWriting
        self.output = stdout
        self.errorOutput = stderr
    }

    private static func resolveCodexExecutable() throws -> URL {
        var candidates: [String] = []
        if let override = ProcessInfo.processInfo.environment["BAVBAV_CODEX_BIN"], !override.isEmpty {
            candidates.append(override)
        }
        candidates.append(contentsOf: [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ])
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw CodexClientError.executableNotFound
    }

    private func finishConnecting(with result: Result<CodexHealth, Error>) {
        connecting = false
        let waiters = connectionWaiters
        connectionWaiters.removeAll()
        for waiter in waiters {
            switch result {
            case .success(let health): waiter.resume(returning: health)
            case .failure(let error): waiter.resume(throwing: error)
            }
        }
    }

    private func resetTransport(terminate: Bool, pendingError: Error) {
        initialized = false
        processGeneration &+= 1
        resumedThreadIDs.removeAll(keepingCapacity: false)

        let oldProcess = process
        oldProcess?.terminationHandler = nil
        output?.readabilityHandler = nil
        errorOutput?.readabilityHandler = nil

        if terminate, oldProcess?.isRunning == true {
            oldProcess?.terminate()
        }
        try? input?.close()
        try? output?.close()
        try? errorOutput?.close()

        process = nil
        input = nil
        output = nil
        errorOutput = nil
        receiveBuffer.removeAll(keepingCapacity: false)
        receiveSearchOffset = 0
        pendingReceiveChunks.removeAll(keepingCapacity: false)
        nextReceiveSequence = 0
        lastErrorText = ""
        failAllPending(with: pendingError)
    }

    private func ensureConnected() async throws {
        if !initialized || process?.isRunning != true {
            _ = try await connect()
        }
    }

    private func request(
        method: String,
        params: [String: Any]?,
        timeout: TimeInterval
    ) async throws -> [String: Any] {
        guard process?.isRunning == true else { throw CodexClientError.disconnected }
        let id = nextRequestID
        nextRequestID += 1
        trace("send id=\(id) method=\(method)")

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = PendingRequest(continuation: continuation, timeoutTask: nil)
            do {
                var object: [String: Any] = ["method": method, "id": id]
                if let params { object["params"] = params }
                try writeJSON(object)
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
                return
            }

            let timeoutTask = Task { [weak self] in
                let nanoseconds = UInt64(timeout * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                await self?.timeoutRequest(id: id, method: method)
            }
            pending[id]?.timeoutTask = timeoutTask
        }
    }

    private func sendNotification(method: String, params: [String: Any]) throws {
        try writeJSON(["method": method, "params": params])
    }

    private func writeJSON(_ object: [String: Any]) throws {
        guard let input else { throw CodexClientError.disconnected }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    private func ingest(_ data: Data, generation: Int, sequence: Int) {
        guard generation == processGeneration else { return }
        pendingReceiveChunks[sequence] = data
        while let next = pendingReceiveChunks.removeValue(forKey: nextReceiveSequence) {
            nextReceiveSequence += 1
            ingestOrdered(next, sequence: nextReceiveSequence - 1)
        }
    }

    private func ingestOrdered(_ data: Data, sequence: Int) {
        trace("recv seq=\(sequence) bytes=\(data.count) buffered=\(receiveBuffer.count)")
        receiveBuffer.append(data)
        while receiveSearchOffset < receiveBuffer.count {
            let searchStart = receiveBuffer.index(
                receiveBuffer.startIndex,
                offsetBy: receiveSearchOffset
            )
            guard let newlineIndex = receiveBuffer[searchStart...].firstIndex(of: 0x0A) else {
                receiveSearchOffset = receiveBuffer.count
                // FileHandle can occasionally deliver the final JSON object
                // without scheduling a separate callback for its trailing LF.
                // Accept a syntactically complete object; a later lone LF is
                // harmless and will be discarded as an empty line.
                if data.count < 16_384,
                   (try? JSONSerialization.jsonObject(with: receiveBuffer)) is [String: Any] {
                    let completeLine = receiveBuffer
                    receiveBuffer.removeAll(keepingCapacity: true)
                    receiveSearchOffset = 0
                    handleLine(completeLine)
                }
                break
            }

            let line = receiveBuffer.subdata(in: receiveBuffer.startIndex..<newlineIndex)
            receiveBuffer.removeSubrange(receiveBuffer.startIndex...newlineIndex)
            receiveSearchOffset = 0
            guard !line.isEmpty else { continue }
            handleLine(line)
        }
    }

    private func handleLine(_ line: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if let method = message["method"] as? String {
            trace("event id=\(String(describing: message["id"])) method=\(method)")
            if let requestID = message["id"] {
                if journalWorker {
                    journalFailure = "The note extractor sent an unexpected tool or permission request and was stopped."
                    // No approval, form, or external tool request may escape into the UI.
                    return
                }
                handleServerRequest(
                    method: method,
                    requestID: requestID,
                    params: message["params"] as? [String: Any] ?? [:]
                )
            } else {
                handleNotification(
                    method: method,
                    params: message["params"] as? [String: Any] ?? [:]
                )
            }
            return
        }
        guard let idNumber = message["id"] as? NSNumber else { return }
        let id = idNumber.intValue
        guard let request = pending.removeValue(forKey: id) else { return }
        trace("response id=\(id) bytes=\(line.count)")
        request.timeoutTask?.cancel()

        if let error = message["error"] as? [String: Any] {
            request.continuation.resume(throwing: CodexClientError.rpcError(
                error["message"] as? String ?? "unknown RPC error"
            ))
        } else if let result = message["result"] as? [String: Any] {
            request.continuation.resume(returning: result)
        } else {
            request.continuation.resume(throwing: CodexClientError.invalidResponse("Missing result field"))
        }
    }

    private func handleNotification(method: String, params: [String: Any]) {
        if journalWorker, params["threadId"] as? String == journalThreadID {
            if method == "item/completed", let item = params["item"] as? [String: Any],
               item["type"] as? String == "agentMessage", let text = item["text"] as? String {
                if text.utf8.count <= 32_000 { journalOutput = text }
                else { journalFailure = "Note extraction exceeded the output limit." }
            }
            if method == "turn/completed", let turn = params["turn"] as? [String: Any] {
                journalFinished = turn["status"] as? String == "completed"
                if !journalFinished {
                    journalFailure = (turn["error"] as? [String: Any])?["message"] as? String ?? "Note extraction could not be completed."
                }
            }
        }
        switch method {
        case "turn/started":
            guard
                let threadID = params["threadId"] as? String,
                let turn = params["turn"] as? [String: Any],
                let turnID = turn["id"] as? String
            else { return }
            eventHandler?(.turnStarted(threadID: threadID, turnID: turnID))

        case "item/agentMessage/delta":
            guard
                let threadID = params["threadId"] as? String,
                let turnID = params["turnId"] as? String,
                let itemID = params["itemId"] as? String,
                let delta = params["delta"] as? String
            else { return }
            eventHandler?(.agentMessageDelta(
                threadID: threadID,
                turnID: turnID,
                itemID: itemID,
                delta: delta
            ))

        case "item/started":
            guard
                let threadID = params["threadId"] as? String,
                let turnID = params["turnId"] as? String,
                let item = params["item"] as? [String: Any],
                let message = Self.parseMessage(item)
            else { return }
            eventHandler?(.itemStarted(threadID: threadID, turnID: turnID, message: message))

        case "item/plan/delta":
            emitItemDelta(params: params, kind: .plan, title: "PLAN")

        case "item/reasoning/summaryTextDelta":
            emitItemDelta(params: params, kind: .reasoning, title: "REASONING SUMMARY")

        case "item/commandExecution/outputDelta":
            emitItemDelta(params: params, kind: .command, title: "COMMAND OUTPUT")

        case "item/fileChange/outputDelta":
            emitItemDelta(params: params, kind: .fileChange, title: "FILE CHANGE")

        case "item/fileChange/patchUpdated":
            guard
                let threadID = params["threadId"] as? String,
                let turnID = params["turnId"] as? String,
                let itemID = params["itemId"] as? String,
                let changes = params["changes"] as? [[String: Any]],
                let message = Self.parseMessage([
                    "type": "fileChange",
                    "id": itemID,
                    "changes": changes,
                    "status": "inProgress"
                ])
            else { return }
            eventHandler?(.itemCompleted(threadID: threadID, turnID: turnID, message: message))

        case "item/commandExecution/terminalInteraction":
            guard let stdinText = params["stdin"] as? String else { return }
            var enriched = params
            enriched["delta"] = "\n[STDIN] \(stdinText)"
            emitItemDelta(params: enriched, kind: .command, title: "COMMAND")

        case "item/mcpToolCall/progress":
            guard let progress = params["message"] as? String else { return }
            var enriched = params
            enriched["delta"] = "\n\(progress)"
            emitItemDelta(params: enriched, kind: .mcpTool, title: "APP TOOL")

        case "item/completed":
            guard
                let threadID = params["threadId"] as? String,
                let turnID = params["turnId"] as? String,
                let item = params["item"] as? [String: Any],
                let message = Self.parseMessage(item)
            else { return }
            eventHandler?(.itemCompleted(threadID: threadID, turnID: turnID, message: message))

        case "turn/completed":
            guard
                let threadID = params["threadId"] as? String,
                let turn = params["turn"] as? [String: Any],
                let turnID = turn["id"] as? String
            else { return }
            let errorObject = turn["error"] as? [String: Any]
            eventHandler?(.turnCompleted(
                threadID: threadID,
                turnID: turnID,
                status: turn["status"] as? String ?? "completed",
                error: errorObject?["message"] as? String
            ))

        case "turn/diff/updated":
            guard
                let threadID = params["threadId"] as? String,
                let turnID = params["turnId"] as? String,
                let diff = params["diff"] as? String
            else { return }
            eventHandler?(.turnDiffUpdated(threadID: threadID, turnID: turnID, diff: diff))

        case "turn/plan/updated":
            guard
                let threadID = params["threadId"] as? String,
                let turnID = params["turnId"] as? String
            else { return }
            let steps = (params["plan"] as? [[String: Any]] ?? []).compactMap { row -> String? in
                guard let step = row["step"] as? String else { return nil }
                return "[\((row["status"] as? String ?? "pending").uppercased())] \(step)"
            }
            let body = ([params["explanation"] as? String, steps.joined(separator: "\n")]
                .compactMap { $0 }).joined(separator: "\n\n")
            eventHandler?(.itemCompleted(
                threadID: threadID,
                turnID: turnID,
                message: CodexMessage(
                    id: "turn-plan-\(turnID)",
                    role: .agent,
                    text: body,
                    kind: .plan,
                    title: "PLAN",
                    status: "UPDATED"
                )
            ))

        case "account/rateLimits/updated":
            guard
                let snapshot = params["rateLimits"] as? [String: Any],
                let limits = Self.parseRateLimits(snapshot)
            else { return }
            eventHandler?(.rateLimitsUpdated(limits))

        case "serverRequest/resolved":
            guard let rawID = params["requestId"], let requestID = Self.parseRequestID(rawID) else { return }
            let pendingRequest = pendingServerRequests.removeValue(forKey: requestID)
            eventHandler?(.interactionResolved(
                requestID: requestID,
                threadID: params["threadId"] as? String
                    ?? pendingRequest?.params["threadId"] as? String
                    ?? pendingRequest?.params["conversationId"] as? String
            ))

        case "warning":
            guard let message = params["message"] as? String else { return }
            eventHandler?(.warning(threadID: params["threadId"] as? String, message: message))

        case "configWarning":
            let summary = params["summary"] as? String ?? "Codex configuration warning"
            let detail = params["details"] as? String
            eventHandler?(.warning(
                threadID: nil,
                message: [summary, detail].compactMap { $0 }.joined(separator: "\n")
            ))

        case "error":
            let error = params["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "Codex runtime error"
            eventHandler?(.warning(threadID: params["threadId"] as? String, message: message))

        case "model/rerouted":
            let from = params["fromModel"] as? String ?? "model"
            let to = params["toModel"] as? String ?? "model"
            let reason = params["reason"] as? String
            eventHandler?(.warning(
                threadID: params["threadId"] as? String,
                message: (["Model rerouted: \(from) → \(to)", reason].compactMap { $0 }).joined(separator: "\n")
            ))

        case "model/verification":
            eventHandler?(.warning(
                threadID: params["threadId"] as? String,
                message: "Codex requires account verification."
            ))

        case "model/safetyBuffering/updated":
            guard params["showBufferingUi"] as? Bool == true else { return }
            let reasons = params["reasons"] as? [String] ?? []
            eventHandler?(.warning(
                threadID: params["threadId"] as? String,
                message: (["Model safety buffer active", reasons.joined(separator: "\n")]
                    .filter { !$0.isEmpty }).joined(separator: "\n")
            ))

        default:
            break
        }
    }

    private func emitItemDelta(
        params: [String: Any],
        kind: CodexMessageKind,
        title: String
    ) {
        guard
            let threadID = params["threadId"] as? String,
            let turnID = params["turnId"] as? String,
            let itemID = params["itemId"] as? String,
            let delta = params["delta"] as? String
        else { return }
        eventHandler?(.itemTextDelta(
            threadID: threadID,
            turnID: turnID,
            itemID: itemID,
            kind: kind,
            title: title,
            delta: delta
        ))
    }

    private func handleServerRequest(
        method: String,
        requestID: Any,
        params: [String: Any]
    ) {
        guard let parsedID = Self.parseRequestID(requestID) else {
            trace("server request has unsupported id")
            return
        }
        if let interaction = Self.parseInteractionRequest(
            method: method,
            requestID: parsedID,
            params: params
        ) {
            pendingServerRequests[parsedID] = PendingServerRequest(method: method, params: params)
            eventHandler?(.interactionRequested(interaction))
            return
        }

        do {
            try writeJSON([
                "id": parsedID.jsonValue,
                "error": [
                    "code": -32_601,
                    "message": "Bavbav does not support this server request."
                ]
            ])
        } catch {
            trace("server request rejection failed: \(error.localizedDescription)")
        }
    }

    private static func parseInteractionRequest(
        method: String,
        requestID: CodexRequestID,
        params: [String: Any]
    ) -> CodexInteractionRequest? {
        guard let threadID = params["threadId"] as? String
            ?? params["conversationId"] as? String
        else { return nil }
        let turnID = params["turnId"] as? String
        let itemID = params["itemId"] as? String ?? params["callId"] as? String
        let reason = params["reason"] as? String

        switch method {
        case "item/commandExecution/requestApproval", "execCommandApproval":
            let network = params["networkApprovalContext"] as? [String: Any]
            let host = network?["host"] as? String
            let protocolName = network?["protocol"] as? String
            let command = params["command"] as? String
                ?? (params["command"] as? [String])?.joined(separator: " ")
                ?? "No command details provided"
            let cwd = params["cwd"] as? String
            let options = approvalOptions(available: params["availableDecisions"])
            return CodexInteractionRequest(
                requestID: requestID,
                threadID: threadID,
                turnID: turnID,
                itemID: itemID,
                kind: .commandApproval,
                title: host == nil ? "COMMAND APPROVAL" : "NETWORK APPROVAL",
                summary: host.map { "\(protocolName?.uppercased() ?? "NET") · \($0)" } ?? command,
                detail: ([reason, cwd.map { "CWD · \($0)" }, host == nil ? nil : "$ \(command)"].compactMap { $0 }).joined(separator: "\n"),
                options: options,
                defaultOptionID: options.contains(where: { $0.id == "decline" }) ? "decline" : options.first?.id
            )

        case "item/fileChange/requestApproval", "applyPatchApproval":
            let root = params["grantRoot"] as? String
            let legacyChanges = renderJSON(params["fileChanges"])
            return CodexInteractionRequest(
                requestID: requestID,
                threadID: threadID,
                turnID: turnID,
                itemID: itemID,
                kind: .fileApproval,
                title: "FILE CHANGE APPROVAL",
                summary: root.map { "Write access · \($0)" } ?? "Codex wants to modify files.",
                detail: ([reason, legacyChanges].compactMap { $0 }).joined(separator: "\n").isEmpty
                    ? "Change details are available in the chat's command view."
                    : ([reason, legacyChanges].compactMap { $0 }).joined(separator: "\n"),
                options: standardApprovalOptions,
                defaultOptionID: "decline"
            )

        case "item/permissions/requestApproval":
            return CodexInteractionRequest(
                requestID: requestID,
                threadID: threadID,
                turnID: turnID,
                itemID: itemID,
                kind: .permissionApproval,
                title: "PERMISSION REQUEST",
                summary: reason ?? "Codex is requesting additional permissions.",
                detail: renderJSON(params["permissions"]) ?? "No permission details provided",
                options: [
                    CodexInteractionOption(id: "permissionTurn", label: "ALLOW THIS TURN", detail: "Grant the requested permissions for this turn only"),
                    CodexInteractionOption(id: "permissionSession", label: "ALLOW SESSION", detail: "Grant the requested permissions for this session"),
                    CodexInteractionOption(id: "decline", label: "DENY", detail: "Continue without granting permissions")
                ],
                defaultOptionID: "decline"
            )

        case "item/tool/requestUserInput":
            let questions = parseToolQuestions(params["questions"] as? [[String: Any]] ?? [])
            return CodexInteractionRequest(
                requestID: requestID,
                threadID: threadID,
                turnID: turnID,
                itemID: itemID,
                kind: .userInput,
                title: "CODEX QUESTION",
                summary: questions.first?.prompt ?? "Codex is waiting for your answer.",
                detail: "W/S SELECT · SPACE CONFIRM · ENTER CUSTOM",
                options: [],
                questions: questions
            )

        case "mcpServer/elicitation/request":
            let mode = params["mode"] as? String ?? "form"
            let server = params["serverName"] as? String ?? "MCP"
            let message = params["message"] as? String ?? "The app is requesting additional information."
            if mode == "url" {
                let url = params["url"] as? String ?? ""
                return CodexInteractionRequest(
                    requestID: requestID,
                    threadID: threadID,
                    turnID: turnID,
                    itemID: itemID,
                    kind: .mcpURL,
                    title: "APP AUTH · \(server)",
                    summary: message,
                    detail: url,
                    options: [
                        CodexInteractionOption(id: "accept", label: "CONTINUE", detail: "Continue the connection flow"),
                        CodexInteractionOption(id: "decline", label: "DECLINE", detail: "Decline the request"),
                        CodexInteractionOption(id: "cancel", label: "CANCEL TURN", detail: "Cancel the request and stop the turn")
                    ],
                    defaultOptionID: "decline"
                )
            }
            let questions = parseMCPQuestions(params["requestedSchema"] as? [String: Any] ?? [:])
            return CodexInteractionRequest(
                requestID: requestID,
                threadID: threadID,
                turnID: turnID,
                itemID: itemID,
                kind: .mcpForm,
                title: "APP INPUT · \(server)",
                summary: message,
                detail: "Information is sent only to the requesting app.",
                options: questions.isEmpty ? [
                    CodexInteractionOption(id: "accept", label: "ACCEPT", detail: "Accept the request"),
                    CodexInteractionOption(id: "decline", label: "DECLINE", detail: "Decline the request")
                ] : [],
                questions: questions,
                defaultOptionID: questions.isEmpty ? "decline" : nil
            )

        default:
            return nil
        }
    }

    private static var standardApprovalOptions: [CodexInteractionOption] {
        [
            CodexInteractionOption(id: "accept", label: "ALLOW ONCE", detail: "Allow this action once"),
            CodexInteractionOption(id: "acceptForSession", label: "ALLOW SESSION", detail: "Allow similar actions for this session"),
            CodexInteractionOption(id: "decline", label: "DENY", detail: "Deny the action and continue the turn"),
            CodexInteractionOption(id: "cancel", label: "STOP TURN", detail: "Deny the action and stop the turn")
        ]
    }

    private static func approvalOptions(available: Any?) -> [CodexInteractionOption] {
        guard let values = available as? [Any], !values.isEmpty else { return standardApprovalOptions }
        let allowed = Set(values.compactMap { value -> String? in
            if let value = value as? String { return value }
            if let object = value as? [String: Any] { return object.keys.first }
            return nil
        })
        let filtered = standardApprovalOptions.filter { allowed.contains($0.id) }
        return filtered.isEmpty ? standardApprovalOptions : filtered
    }

    private static func parseToolQuestions(_ rows: [[String: Any]]) -> [CodexInteractionQuestion] {
        rows.compactMap { row in
            guard let id = row["id"] as? String, let prompt = row["question"] as? String else { return nil }
            let options = (row["options"] as? [[String: Any]] ?? []).compactMap { option -> CodexInteractionOption? in
                guard let label = option["label"] as? String else { return nil }
                return CodexInteractionOption(
                    id: label,
                    label: label,
                    detail: option["description"] as? String ?? ""
                )
            }
            return CodexInteractionQuestion(
                id: id,
                header: row["header"] as? String ?? "QUESTION",
                prompt: prompt,
                options: options,
                allowsOther: row["isOther"] as? Bool ?? false,
                isSecret: row["isSecret"] as? Bool ?? false
            )
        }
    }

    private static func parseMCPQuestions(_ schema: [String: Any]) -> [CodexInteractionQuestion] {
        let properties = schema["properties"] as? [String: Any] ?? [:]
        let required = Set(schema["required"] as? [String] ?? [])
        return properties.keys.sorted().compactMap { key in
            guard let field = properties[key] as? [String: Any] else { return nil }
            let rawType = field["type"] as? String ?? "string"
            let optionSource = rawType == "array"
                ? (field["items"] as? [String: Any] ?? [:])
                : field
            var options: [CodexInteractionOption]
            if let oneOf = optionSource["oneOf"] as? [[String: Any]] {
                options = oneOf.compactMap { option in
                    guard let value = option["const"] as? String else { return nil }
                    return CodexInteractionOption(
                        id: value,
                        label: option["title"] as? String ?? value,
                        detail: ""
                    )
                }
            } else {
                options = (optionSource["enum"] as? [String] ?? []).map {
                    CodexInteractionOption(id: $0, label: $0, detail: "")
                }
            }
            if rawType == "boolean" {
                options = [
                    CodexInteractionOption(id: "true", label: "TRUE", detail: ""),
                    CodexInteractionOption(id: "false", label: "FALSE", detail: "")
                ]
            }
            let valueType: CodexInteractionValueType
            switch rawType {
            case "integer": valueType = .integer
            case "number": valueType = .number
            case "boolean": valueType = .boolean
            case "array": valueType = .stringArray
            default: valueType = .string
            }
            return CodexInteractionQuestion(
                id: key,
                header: field["title"] as? String ?? key.uppercased(),
                prompt: field["description"] as? String ?? "Enter a value for \(key).",
                options: options,
                allowsOther: options.isEmpty,
                isSecret: field["format"] as? String == "password" || field["writeOnly"] as? Bool == true,
                valueType: valueType,
                allowsMultiple: rawType == "array",
                isRequired: required.contains(key)
            )
        }
    }

    private static func parseRequestID(_ value: Any) -> CodexRequestID? {
        if let value = value as? String { return .string(value) }
        if let value = value as? NSNumber { return .integer(value.intValue) }
        if let value = value as? Int { return .integer(value) }
        return nil
    }

    private func timeoutRequest(id: Int, method: String) {
        guard let request = pending.removeValue(forKey: id) else { return }
        trace("timeout id=\(id) method=\(method)")
        request.timeoutTask?.cancel()
        let timeoutError = CodexClientError.timeout(method)
        request.continuation.resume(throwing: timeoutError)

        // JSON-RPC has no general cancellation method. Closing this transport
        // prevents an expired, potentially huge response from continuing to
        // consume CPU and memory; the next public operation reconnects.
        eventHandler?(.transportClosed(message: timeoutError.localizedDescription))
        resetTransport(terminate: true, pendingError: CodexClientError.disconnected)
    }

    private func rememberError(_ data: Data, generation: Int) {
        guard generation == processGeneration else { return }
        guard let text = String(data: data, encoding: .utf8) else { return }
        lastErrorText = String((lastErrorText + text).suffix(4_000))
    }

    private func processEnded(status: Int32, generation: Int) {
        guard generation == processGeneration else { return }
        trace("process ended status=\(status)")
        let detail = lastErrorText
            .split(separator: "\n")
            .suffix(2)
            .joined(separator: " ")
        let error = CodexClientError.processFailed(
            detail.isEmpty ? "exit code \(status)" : detail
        )
        eventHandler?(.transportClosed(
            message: error.localizedDescription
        ))
        resetTransport(terminate: false, pendingError: error)
    }

    private func failAllPending(with error: Error) {
        let requests = pending.values
        pending.removeAll()
        requests.forEach {
            $0.timeoutTask?.cancel()
            $0.continuation.resume(throwing: error)
        }
        pendingServerRequests.removeAll(keepingCapacity: false)
    }

    private func trace(_ message: String) {
        guard Self.rpcTraceEnabled else { return }
        fputs("[Bavbav RPC] \(message)\n", stderr)
    }
}

private extension CodexRequestID {
    var jsonValue: Any {
        switch self {
        case .integer(let value): value
        case .string(let value): value
        }
    }
}

private extension CodexFormValue {
    var jsonValue: Any {
        switch self {
        case .string(let value): value
        case .integer(let value): value
        case .number(let value): value
        case .boolean(let value): value
        case .stringArray(let value): value
        }
    }
}
