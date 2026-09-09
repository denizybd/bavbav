import Foundation

private struct PendingFixture {
    let scenario: String
    let threadID: String
    let turnID: String
}

private var pending: [String: PendingFixture] = [:]
private var activeTurns: [String: String] = [:]
private var turnCounter = 0
private var recordedItems: [String: [[String: Any]]] = [:]
private var standaloneRows: [String: [String: Any]] = [:]
private var threadNames: [String: String] = [:]
private var composerGoals: [String: [String: Any]] = [:]
private let outputLock = NSLock()

private func recordComposerRequest(_ message: [String: Any]) {
    guard ProcessInfo.processInfo.environment["BAVBAV_COMPOSER_CHECK"] == "1",
          let path = ProcessInfo.processInfo.environment["BAVBAV_COMPOSER_REQUEST_LOG"],
          var data = try? JSONSerialization.data(withJSONObject: message) else { return }
    data.append(0x0A)
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    guard let handle = FileHandle(forWritingAtPath: path) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: data)
}

private func completeComposerTurn(threadID: String, turnID: String, input: [[String: Any]], marker: String) {
    send(["method": "item/completed", "params": ["threadId": threadID, "turnId": turnID,
        "item": ["id": "\(turnID)-\(marker)-user", "type": "userMessage", "content": input]]])
    send(["method": "item/completed", "params": ["threadId": threadID, "turnId": turnID,
        "item": ["id": "\(turnID)-\(marker)-agent", "type": "agentMessage", "text": "BAVBAV_COMPOSER_\(marker)_OK", "phase": "final_answer"]]])
    send(["method": "turn/completed", "params": ["threadId": threadID,
        "turn": ["id": turnID, "status": "completed", "items": [], "error": NSNull()]]])
    activeTurns.removeValue(forKey: threadID)
}

private let visibilityItems: [[String: Any]] = [
    ["id": "v-user", "type": "userMessage", "content": [["type": "text", "text": "Hello"]]],
    ["id": "v-reason", "type": "reasoning", "summary": ["Thinking fixture"]],
    ["id": "v-command", "type": "commandExecution", "command": "echo fixture", "status": "completed", "aggregatedOutput": "fixture"],
    ["id": "v-subagent", "type": "subAgentActivity", "status": "completed", "text": "Agent fixture"],
    ["id": "v-agent", "type": "agentMessage", "text": "Answer fixture"]
]

private func performanceItems(_ threadID: String) -> [[String: Any]] {
    let history: [[String: Any]] = (0..<120).map { index in
        let text = "\(threadID) message \(index)\n" + String(repeating: "Long history reading fixture. ", count: 12)
        return ["id": "\(threadID)-message-\(index)", "type": "agentMessage", "text": text]
    }
    return history + (recordedItems[threadID] ?? [])
}

private func send(_ object: [String: Any]) {
    if object["method"] as? String == "item/completed",
       let params = object["params"] as? [String: Any],
       let threadID = params["threadId"] as? String,
       let item = params["item"] as? [String: Any] {
        var items = recordedItems[threadID] ?? []
        items.removeAll { ($0["id"] as? String) == (item["id"] as? String) }
        items.append(item)
        recordedItems[threadID] = items
    }
    guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
    data.append(0x0A)
    outputLock.lock()
    defer { outputLock.unlock() }
    try? FileHandle.standardOutput.write(contentsOf: data)
}

private func modelRow() -> [String: Any] {
    [
        "id": "fake-model",
        "model": "fake-model",
        "displayName": "Fake Model",
        "description": "Protocol fixture",
        "isDefault": true,
        "defaultReasoningEffort": "low",
        "supportedReasoningEfforts": [["reasoningEffort": "low", "description": "Low"]]
    ]
}

private func threadRow(id: String, cwd: String) -> [String: Any] {
    [
        "id": id,
        "cwd": cwd,
        "name": threadNames[id] ?? "Fixture",
        "preview": "fixture",
        "recencyAt": 1_788_000_000,
        "status": ["type": "idle"],
        "historyMode": "paginated"
    ]
}

private func requestID(_ value: Any?) -> Any? {
    if let number = value as? NSNumber { return number }
    return value as? String
}

private func fixtureRequest(
    scenario: String,
    requestID: String,
    threadID: String,
    turnID: String
) -> [String: Any] {
    let common: [String: Any] = [
        "threadId": threadID,
        "turnId": turnID,
        "itemId": "item-\(turnID)",
        "startedAtMs": 1_788_000_000_000 as Int64
    ]
    switch scenario {
    case "COMMAND":
        return [
            "id": requestID,
            "method": "item/commandExecution/requestApproval",
            "params": common.merging([
                "command": "touch outside.txt",
                "cwd": "/tmp/fixture",
                "reason": "Fixture command approval"
            ]) { _, new in new }
        ]
    case "FILE":
        return [
            "id": requestID,
            "method": "item/fileChange/requestApproval",
            "params": common.merging([
                "grantRoot": "/tmp/outside",
                "reason": "Fixture file approval"
            ]) { _, new in new }
        ]
    case "PERMISSION":
        return [
            "id": requestID,
            "method": "item/permissions/requestApproval",
            "params": common.merging([
                "cwd": "/tmp/fixture",
                "reason": "Fixture extra permissions",
                "permissions": ["network": ["enabled": true]]
            ]) { _, new in new }
        ]
    case "QUESTION":
        return [
            "id": requestID,
            "method": "item/tool/requestUserInput",
            "params": common.merging([
                "isBlocking": true,
                "questions": [[
                    "id": "choice",
                    "header": "CHOICE",
                    "question": "Choose one",
                    "isOther": true,
                    "options": [["label": "alpha", "description": "First"]]
                ]]
            ]) { _, new in new }
        ]
    default:
        return [
            "id": requestID,
            "method": "mcpServer/elicitation/request",
            "params": [
                "threadId": threadID,
                "turnId": turnID,
                "serverName": "fixture-app",
                "mode": "form",
                "message": "Complete fixture form",
                "requestedSchema": [
                    "type": "object",
                    "required": ["age", "enabled", "tags"],
                    "properties": [
                        "age": ["type": "integer", "title": "Age"],
                        "enabled": ["type": "boolean", "title": "Enabled"],
                        "tags": [
                            "type": "array",
                            "title": "Tags",
                            "items": ["type": "string", "enum": ["a", "b"]]
                        ]
                    ]
                ]
            ]
        ]
    }
}

private func responseIsValid(_ result: [String: Any], scenario: String) -> Bool {
    switch scenario {
    case "COMMAND": return result["decision"] as? String == "accept"
    case "FILE": return result["decision"] as? String == "decline"
    case "PERMISSION":
        return result["scope"] as? String == "turn"
            && result["permissions"] is [String: Any]
    case "QUESTION":
        let answers = result["answers"] as? [String: Any]
        let choice = answers?["choice"] as? [String: Any]
        return choice?["answers"] as? [String] == ["alpha"]
    default:
        guard result["action"] as? String == "accept",
              let content = result["content"] as? [String: Any],
              let age = content["age"] as? NSNumber,
              let enabled = content["enabled"] as? NSNumber,
              let tags = content["tags"] as? [String]
        else { return false }
        return age.intValue == 7 && enabled.boolValue && tags == ["a", "b"]
    }
}

while let line = readLine() {
    guard let data = line.data(using: .utf8),
          let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { continue }

    if let method = message["method"] as? String {
        guard let id = requestID(message["id"]) else { continue }
        let params = message["params"] as? [String: Any] ?? [:]
        recordComposerRequest(message)
        switch method {
        case "thread/goal/set" where ProcessInfo.processInfo.environment["BAVBAV_COMPOSER_CHECK"] == "1":
            let threadID = params["threadId"] as? String ?? "fixture-thread"
            let goal: [String: Any] = ["threadId": threadID, "objective": params["objective"] as? String ?? "",
                "status": params["status"] as? String ?? "active", "tokenBudget": params["tokenBudget"] ?? NSNull(),
                "tokensUsed": 0, "timeUsedSeconds": 0, "createdAt": 1_788_000_000, "updatedAt": 1_788_000_000]
            composerGoals[threadID] = goal
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
                send(["id": id, "result": ["goal": goal]])
            }
        case "thread/goal/get" where ProcessInfo.processInfo.environment["BAVBAV_COMPOSER_CHECK"] == "1":
            let threadID = params["threadId"] as? String ?? "fixture-thread"
            send(["id": id, "result": ["goal": composerGoals[threadID] as Any? ?? NSNull()]])
        case "thread/goal/clear" where ProcessInfo.processInfo.environment["BAVBAV_COMPOSER_CHECK"] == "1":
            let threadID = params["threadId"] as? String ?? "fixture-thread"
            let existed = composerGoals.removeValue(forKey: threadID) != nil
            send(["id": id, "result": ["cleared": existed]])
        case "initialize":
            send(["id": id, "result": [
                "codexHome": "/tmp/bavbav-fixture-home",
                "platformOs": "macos",
                "userAgent": "Bavbav Fixture"
            ]])
        case "account/read":
            send(["id": id, "result": ["requiresOpenaiAuth": false]])
        case "model/list":
            send(["id": id, "result": ["data": [modelRow()], "nextCursor": NSNull()]])
        case "thread/list":
            let listedThreadID = ProcessInfo.processInfo.environment["BAVBAV_FIXTURE_ACTIVE_WRITER"] == "1"
                ? "desktop-owned"
                : "fixture-thread"
            var rows = [threadRow(id: listedThreadID, cwd: "/tmp/fixture")]
            rows.append(contentsOf: standaloneRows.values)
            if ProcessInfo.processInfo.environment["BAVBAV_FIXTURE_TWO_THREADS"] == "1" {
                rows.append(threadRow(id: "fixture-history-thread", cwd: "/tmp/fixture"))
            }
            if ProcessInfo.processInfo.environment["BAVBAV_RENAME_CHECK"] == "1" {
                rows.append(threadRow(id: "fixture-standalone", cwd: "/tmp/rename-standalone"))
                // Snapshot before rename, deliver after its acknowledgment to
                // exercise an in-flight catalog response with an obsolete name.
                let response: [String: Any] = ["id": id, "result": ["data": rows, "nextCursor": NSNull()]]
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { send(response) }
                continue
            }
            send(["id": id, "result": [
                "data": rows,
                "nextCursor": NSNull()
            ]])
        case "thread/start":
            if ProcessInfo.processInfo.environment["BAVBAV_JOURNAL_CHECK"] == "1", params["ephemeral"] as? Bool == true {
                let config = params["config"] as? [String: Any]
                guard params["sandbox"] as? String == "read-only", params["approvalPolicy"] as? String == "never",
                      params["baseInstructions"] is String, params["developerInstructions"] is String,
                      config?["features.shell_tool"] as? Bool == false,
                      config?["features.apps"] as? Bool == false,
                      config?["web_search"] as? String == "disabled",
                      (params["environments"] as? [Any])?.isEmpty == true else {
                    send(["id": id, "error": ["code": -32602, "message": "unsafe journal worker settings"]]); continue
                }
                send(["id": id, "result": ["thread": threadRow(id: "ephemeral-journal", cwd: params["cwd"] as? String ?? "/tmp")]])
                continue
            }
            if ProcessInfo.processInfo.environment["BAVBAV_STANDALONE_CHECK"] == "1" {
                let threadID = "standalone-\(standaloneRows.count + 1)"
                var row = threadRow(id: threadID, cwd: params["cwd"] as? String ?? "")
                row["name"] = "Chat \(standaloneRows.count + 1)"
                row["recencyAt"] = 1_788_000_001 + standaloneRows.count
                standaloneRows[threadID] = row
                send(["id": id, "result": ["thread": row]])
                continue
            }
            if params["cwd"] as? String == "/tmp/full-access-fixture",
               (params["sandbox"] as? String != "danger-full-access"
                || params["approvalPolicy"] as? String != "never") {
                send(["id": id, "error": [
                    "code": -32_602,
                    "message": "full access thread settings missing"
                ]])
                continue
            }
            send(["id": id, "result": ["thread": threadRow(
                id: "fixture-thread",
                cwd: params["cwd"] as? String ?? "/tmp/fixture"
            )]])
        case "thread/resume":
            if ProcessInfo.processInfo.environment["BAVBAV_STANDALONE_CHECK"] == "1",
               let threadID = params["threadId"] as? String, let row = standaloneRows[threadID] {
                send(["id": id, "result": ["thread": row, "model": "fake-model", "reasoningEffort": "low"]])
                continue
            }
            if params["threadId"] as? String == "full-access-existing",
               (params["sandbox"] as? String != "danger-full-access"
                || params["approvalPolicy"] as? String != "never") {
                send(["id": id, "error": [
                    "code": -32_602,
                    "message": "full access resume settings missing"
                ]])
                continue
            }
            if params["threadId"] as? String == "desktop-owned" {
                send(["id": id, "error": [
                    "code": -32_000,
                    "message": "thread already has an active writer"
                ]])
            } else {
                send(["id": id, "result": [
                    "thread": threadRow(id: params["threadId"] as? String ?? "fixture-thread", cwd: "/tmp/fixture"),
                    "model": "fake-model",
                    "reasoningEffort": "low"
                ]])
            }
        case "thread/name/set":
            if let threadID = params["threadId"] as? String, let name = params["name"] as? String {
                if name == "RENAME_FAIL", ProcessInfo.processInfo.environment["BAVBAV_RENAME_CHECK"] == "1" {
                    send(["id": id, "error": ["code": -32000, "message": "fixture rename rejected"]])
                    continue
                }
                threadNames[threadID] = name
                if standaloneRows[threadID] != nil { standaloneRows[threadID]?["name"] = name }
            }
            send(["id": id, "result": [:]])
        case "thread/read" where ProcessInfo.processInfo.environment["BAVBAV_STANDALONE_CHECK"] == "1":
            let threadID = params["threadId"] as? String ?? "fixture-thread"
            send(["id": id, "result": ["thread": standaloneRows[threadID] ?? threadRow(id: threadID, cwd: "/tmp/fixture")]])
        case "thread/read" where ProcessInfo.processInfo.environment["BAVBAV_COMPOSER_CHECK"] == "1":
            let threadID = params["threadId"] as? String ?? "fixture-thread"
            send(["id": id, "result": ["thread": threadRow(id: threadID, cwd: "/tmp/fixture")]])
        case "thread/turns/list" where ProcessInfo.processInfo.environment["BAVBAV_COMPOSER_CHECK"] == "1":
            let threadID = params["threadId"] as? String ?? "fixture-thread"
            send(["id": id, "result": ["data": [["id": "composer-history", "items": recordedItems[threadID] ?? []]], "nextCursor": NSNull()]])
        case "thread/items/list" where ProcessInfo.processInfo.environment["BAVBAV_COMPOSER_CHECK"] == "1":
            let threadID = params["threadId"] as? String ?? "fixture-thread"
            send(["id": id, "result": ["data": (recordedItems[threadID] ?? []).reversed().map { ["item": $0] }, "nextCursor": NSNull()]])
        case "thread/turns/list" where ProcessInfo.processInfo.environment["BAVBAV_STANDALONE_CHECK"] == "1":
            let threadID = params["threadId"] as? String ?? "fixture-thread"
            send(["id": id, "result": ["data": [["id": "standalone-turn", "items": recordedItems[threadID] ?? []]], "nextCursor": NSNull()]])
        case "thread/items/list" where ProcessInfo.processInfo.environment["BAVBAV_STANDALONE_CHECK"] == "1":
            let threadID = params["threadId"] as? String ?? "fixture-thread"
            send(["id": id, "result": ["data": (recordedItems[threadID] ?? []).reversed().map { ["item": $0] }, "nextCursor": NSNull()]])
        case "thread/read" where ProcessInfo.processInfo.environment["BAVBAV_PERFORMANCE_CHECK"] == "1":
            let threadID = params["threadId"] as? String ?? "fixture-thread"
            send(["id": id, "result": ["thread": threadRow(id: threadID, cwd: "/tmp/fixture")]])
        case "thread/turns/list" where ProcessInfo.processInfo.environment["BAVBAV_PERFORMANCE_CHECK"] == "1":
            let threadID = params["threadId"] as? String ?? "fixture-thread"
            send(["id": id, "result": ["data": [["id": "performance-turn", "items": performanceItems(threadID)]], "nextCursor": NSNull()]])
        case "thread/items/list" where ProcessInfo.processInfo.environment["BAVBAV_PERFORMANCE_CHECK"] == "1":
            let threadID = params["threadId"] as? String ?? "fixture-thread"
            send(["id": id, "result": ["data": performanceItems(threadID).reversed().map { ["item": $0] }, "nextCursor": NSNull()]])
        case "thread/read" where ProcessInfo.processInfo.environment["BAVBAV_COMMANDS_CHECK"] == "1" || ProcessInfo.processInfo.environment["BAVBAV_RENAME_CHECK"] == "1":
            send(["id": id, "result": ["thread": threadRow(id: params["threadId"] as? String ?? "fixture-thread", cwd: "/tmp/fixture")]])
        case "thread/turns/list" where ProcessInfo.processInfo.environment["BAVBAV_COMMANDS_CHECK"] == "1" || ProcessInfo.processInfo.environment["BAVBAV_RENAME_CHECK"] == "1":
            send(["id": id, "result": ["data": [["id": "visibility-turn", "items": visibilityItems]], "nextCursor": NSNull()]])
        case "thread/items/list" where ProcessInfo.processInfo.environment["BAVBAV_COMMANDS_CHECK"] == "1" || ProcessInfo.processInfo.environment["BAVBAV_RENAME_CHECK"] == "1":
            send(["id": id, "result": ["data": visibilityItems.reversed().map { ["item": $0] }, "nextCursor": NSNull()]])
        case "thread/turns/list" where ProcessInfo.processInfo.environment["BAVBAV_BACKGROUND_CHECK"] == "1":
            let threadID = params["threadId"] as? String ?? "fixture-thread"
            send(["id": id, "result": ["data": [[
                "id": "recorded-turn", "items": recordedItems[threadID] ?? []
            ]], "nextCursor": NSNull()]])
        case "thread/items/list" where ProcessInfo.processInfo.environment["BAVBAV_BACKGROUND_CHECK"] == "1":
            let threadID = params["threadId"] as? String ?? "fixture-thread"
            let entries = (recordedItems[threadID] ?? []).reversed().map { ["item": $0] }
            send(["id": id, "result": ["data": entries, "nextCursor": NSNull()]])
        case "thread/fork":
            send(["id": id, "result": [
                "thread": threadRow(id: "fixture-fork", cwd: params["cwd"] as? String ?? "/tmp/fixture"),
                "model": params["model"] as? String ?? "fake-model",
                "reasoningEffort": "low",
                "modelProvider": "fake",
                "approvalPolicy": "on-request",
                "approvalsReviewer": "user",
                "cwd": params["cwd"] as? String ?? "/tmp/fixture",
                "sandbox": "workspace-write"
            ]])
        case "turn/start":
            turnCounter += 1
            let turnID = "fixture-turn-\(turnCounter)"
            let threadID = params["threadId"] as? String ?? "fixture-thread"
            let input = params["input"] as? [[String: Any]] ?? []
            let scenario = input.first?["text"] as? String ?? "COMMAND"
            if ProcessInfo.processInfo.environment["BAVBAV_COMPOSER_CHECK"] == "1" {
                let text = input.compactMap { $0["text"] as? String }.joined(separator: "\n")
                if text.contains("COMPOSER_FAIL") {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                        send(["id": id, "error": ["code": -32000, "message": "fixture composer failure"]])
                    }
                    continue
                }
                activeTurns[threadID] = turnID
                let startedReply: [String: Any] = ["id": id, "result": ["turn": ["id": turnID, "status": "inProgress"]]]
                if text.contains("COMPOSER_DELAY_ACK_HOLD") {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { send(startedReply) }
                } else { send(startedReply) }
                send(["method": "turn/started", "params": ["threadId": threadID,
                    "turn": ["id": turnID, "status": "inProgress", "items": []]]])
                if text.contains("COMPOSER_INTERACTION_HELD") {
                    let requestID = "composer-question-\(turnCounter)"
                    pending[requestID] = PendingFixture(scenario: "QUESTION", threadID: threadID, turnID: turnID)
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                        send(fixtureRequest(scenario: "QUESTION", requestID: requestID, threadID: threadID, turnID: turnID))
                    }
                } else if text.contains("COMPOSER_HOLD") || text.contains("COMPOSER_DELAY_ACK_HOLD") {
                    send(["method": "item/completed", "params": ["threadId": threadID, "turnId": turnID,
                        "item": ["id": "\(turnID)-hold-user", "type": "userMessage", "content": input]]])
                } else {
                    completeComposerTurn(threadID: threadID, turnID: turnID, input: input, marker: "START")
                }
                continue
            }
            if ProcessInfo.processInfo.environment["BAVBAV_JOURNAL_CHECK"] == "1", threadID == "ephemeral-journal" {
                guard let schema = params["outputSchema"] as? [String: Any], schema["additionalProperties"] as? Bool == false,
                      params["approvalPolicy"] as? String == "never",
                      (params["sandboxPolicy"] as? [String: Any])?["type"] as? String == "readOnly" else {
                    send(["id": id, "error": ["code": -32602, "message": "journal turn restrictions/schema missing"]]); continue
                }
                let raw = String(scenario.dropFirst("JOURNAL_INPUT_JSON\n".count))
                let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
                let source = (object?["messages"] as? [[String: Any]])?.first
                let output: [String: Any] = ["notes": [[
                    "summary": "Mısır seyahati yapıldı.", "kind": "event", "eventKey": "misir seyahati",
                    "eventDay": NSNull(), "dateQuote": NSNull(), "confidence": 0.98, "duplicateOf": NSNull(),
                    "sources": [["messageID": source?["id"] as? String ?? "", "quote": source?["text"] as? String ?? ""]]
                ]]]
                let encoded = String(decoding: try! JSONSerialization.data(withJSONObject: output), as: UTF8.self)
                send(["id": id, "result": ["turn": ["id": turnID, "status": "inProgress"]]])
                // Immediate completion exercises notification/result ordering.
                send(["method": "item/completed", "params": ["threadId": threadID, "turnId": turnID,
                    "item": ["id": "journal-answer", "type": "agentMessage", "text": encoded]]])
                send(["method": "turn/completed", "params": ["threadId": threadID,
                    "turn": ["id": turnID, "status": "completed", "error": NSNull()]]])
                continue
            }
            if scenario == "VISIBILITY_LIVE", ProcessInfo.processInfo.environment["BAVBAV_COMMANDS_CHECK"] == "1" {
                send(["id": id, "result": ["turn": ["id": turnID, "status": "inProgress"]]])
                send(["method": "turn/started", "params": ["threadId": threadID, "turn": ["id": turnID, "status": "inProgress"]]])
                send(["method": "item/completed", "params": ["threadId": threadID, "turnId": turnID,
                    "item": ["id": "live-user", "type": "userMessage", "content": [["type": "text", "text": scenario]]]]])
                send(["method": "item/reasoning/summaryTextDelta", "params": ["threadId": threadID, "turnId": turnID,
                    "itemId": "live-reason", "delta": "Live thought"]])
                send(["method": "item/completed", "params": ["threadId": threadID, "turnId": turnID,
                    "item": ["id": "live-subagent", "type": "subAgentActivity", "text": "Live agent", "status": "completed"]]])
                send(["method": "item/started", "params": ["threadId": threadID, "turnId": turnID,
                    "item": ["id": "live-command", "type": "commandExecution", "command": "echo fixture", "status": "inProgress"]]])
                send(["method": "item/commandExecution/outputDelta", "params": ["threadId": threadID, "turnId": turnID,
                    "itemId": "live-command", "delta": "technical output"]])
                send(["method": "item/agentMessage/delta", "params": ["threadId": threadID, "turnId": turnID,
                    "itemId": "live-answer", "delta": "Live answer"]])
                continue
            }
            if scenario == "FULL_ACCESS" {
                let sandbox = params["sandboxPolicy"] as? [String: Any]
                guard params["approvalPolicy"] as? String == "never",
                      sandbox?["type"] as? String == "dangerFullAccess" else {
                    send(["id": id, "error": [
                        "code": -32_602,
                        "message": "full access turn settings missing"
                    ]])
                    continue
                }
                send(["id": id, "result": ["turn": ["id": turnID, "status": "inProgress"]]])
                send(["method": "turn/started", "params": [
                    "threadId": threadID,
                    "turn": ["id": turnID, "status": "inProgress", "items": []]
                ]])
                send(["method": "turn/completed", "params": [
                    "threadId": threadID,
                    "turn": ["id": turnID, "status": "completed", "items": [], "error": NSNull()]
                ]])
                continue
            }
            if scenario == "STEER_BASE" {
                let userItem: [String: Any] = [
                    "type": "userMessage",
                    "id": "server-user-\(turnCounter)",
                    "content": [["type": "text", "text": scenario]]
                ]
                activeTurns[threadID] = turnID
                send(["id": id, "result": ["turn": ["id": turnID, "status": "inProgress"]]])
                send(["method": "turn/started", "params": [
                    "threadId": threadID,
                    "turn": ["id": turnID, "status": "inProgress", "items": []]
                ]])
                send(["method": "item/started", "params": [
                    "threadId": threadID, "turnId": turnID, "item": userItem
                ]])
                send(["method": "item/completed", "params": [
                    "threadId": threadID, "turnId": turnID, "item": userItem
                ]])
                continue
            }
            if scenario == "ECHO" {
                let userItem: [String: Any] = [
                    "type": "userMessage",
                    "createdAt": 1_788_000_000,
                    "id": "server-user-\(turnCounter)",
                    "content": [["type": "text", "text": scenario]]
                ]
                let agentItem: [String: Any] = [
                    "type": "agentMessage",
                    "createdAtMs": 1_788_000_001_000 as Int64,
                    "id": "server-agent-\(turnCounter)",
                    "text": "BAVBAV_ECHO_OK",
                    "phase": "final_answer"
                ]
                send(["id": id, "result": ["turn": ["id": turnID, "status": "inProgress"]]])
                send(["method": "turn/started", "params": [
                    "threadId": threadID,
                    "turn": ["id": turnID, "status": "inProgress", "items": []]
                ]])
                send(["method": "item/started", "params": [
                    "threadId": threadID, "turnId": turnID, "item": userItem
                ]])
                send(["method": "item/completed", "params": [
                    "threadId": threadID, "turnId": turnID, "item": userItem
                ]])
                send(["method": "item/started", "params": [
                    "threadId": threadID, "turnId": turnID, "item": agentItem
                ]])
                send(["method": "item/completed", "params": [
                    "threadId": threadID, "turnId": turnID, "item": agentItem
                ]])
                send(["method": "turn/completed", "params": [
                    "threadId": threadID,
                    "turn": ["id": turnID, "status": "completed", "items": [], "error": NSNull()]
                ]])
                continue
            }
            activeTurns[threadID] = turnID
            let serverRequestID = "fixture-request-\(turnCounter)"
            pending[serverRequestID] = PendingFixture(
                scenario: scenario,
                threadID: threadID,
                turnID: turnID
            )
            send(["id": id, "result": ["turn": ["id": turnID, "status": "inProgress"]]])
            send(["method": "turn/started", "params": [
                "threadId": threadID,
                "turn": ["id": turnID, "status": "inProgress", "items": []]
            ]])
            send(fixtureRequest(
                scenario: scenario,
                requestID: serverRequestID,
                threadID: threadID,
                turnID: turnID
            ))
        case "turn/steer":
            let threadID = params["threadId"] as? String ?? "fixture-thread"
            let expectedTurnID = params["expectedTurnId"] as? String ?? ""
            guard activeTurns[threadID] == expectedTurnID else {
                send(["id": id, "error": [
                    "code": -32_000,
                    "message": "expected turn does not match active turn"
                ]])
                continue
            }
            let input = params["input"] as? [[String: Any]] ?? []
            let text = input.first?["text"] as? String ?? ""
            if ProcessInfo.processInfo.environment["BAVBAV_COMPOSER_CHECK"] == "1" {
                if input.compactMap({ $0["text"] as? String }).joined().contains("COMPOSER_FAIL") {
                    send(["id": id, "error": ["code": -32000, "message": "fixture composer steer failure"]])
                } else {
                    send(["id": id, "result": ["turnId": expectedTurnID]])
                    completeComposerTurn(threadID: threadID, turnID: expectedTurnID, input: input, marker: "STEER")
                }
                continue
            }
            let userItem: [String: Any] = [
                "type": "userMessage",
                "id": "server-steer-user-\(turnCounter)",
                "content": [["type": "text", "text": text]]
            ]
            let agentItem: [String: Any] = [
                "type": "agentMessage",
                "id": "server-steer-agent-\(turnCounter)",
                "text": "BAVBAV_STEER_OK",
                "phase": "final_answer"
            ]
            send(["id": id, "result": ["turnId": expectedTurnID]])
            send(["method": "item/started", "params": [
                "threadId": threadID, "turnId": expectedTurnID, "item": userItem
            ]])
            send(["method": "item/completed", "params": [
                "threadId": threadID, "turnId": expectedTurnID, "item": userItem
            ]])
            send(["method": "item/started", "params": [
                "threadId": threadID, "turnId": expectedTurnID, "item": agentItem
            ]])
            send(["method": "item/completed", "params": [
                "threadId": threadID, "turnId": expectedTurnID, "item": agentItem
            ]])
            send(["method": "turn/completed", "params": [
                "threadId": threadID,
                "turn": ["id": expectedTurnID, "status": "completed", "items": [], "error": NSNull()]
            ]])
            activeTurns.removeValue(forKey: threadID)
        default:
            send(["id": id, "error": ["code": -32_601, "message": "fixture method not found"]])
        }
        continue
    }

    guard let id = message["id"] as? String,
          let fixture = pending.removeValue(forKey: id),
          let result = message["result"] as? [String: Any]
    else { continue }
    let valid = responseIsValid(result, scenario: fixture.scenario)
    activeTurns.removeValue(forKey: fixture.threadID)
    send(["method": "serverRequest/resolved", "params": [
        "requestId": id,
        "threadId": fixture.threadID
    ]])
    send(["method": "turn/completed", "params": [
        "threadId": fixture.threadID,
        "turn": [
            "id": fixture.turnID,
            "status": valid ? "completed" : "failed",
            "items": [],
            "error": valid ? NSNull() : ["message": "Invalid fixture response"]
        ]
    ]])
}
