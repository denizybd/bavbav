import Foundation
import BavbavOffline

enum OllamaChecks {
    private struct CheckFailure: Error { let message: String }
    private actor Recorder {
        var receipts: [OfflineProgressReceipt] = []
        func append(_ value: OfflineProgressReceipt) { receipts.append(value) }
        func count() -> Int { receipts.count }
        func values() -> [OfflineProgressReceipt] { receipts }
    }
    private actor Stub: OfflineHTTPTransport {
        var actions: [String]
        var calls: [URLRequest] = []
        var chatCalls = 0
        var doneReason: String? = nil
        var malformedEnvelope = false
        var redirectResponse = false
        var beforeChat: (@Sendable (Int) async throws -> Void)?
        init(_ actions: [String], fillUnusedFrameFields: Bool = true) {
            // Only synthetic responses receive unused-field placeholders. Active
            // tool inputs and summary/output are never invented, even here.
            self.actions = actions.map { text in
                guard fillUnusedFrameFields,
                      var object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                      let action = object["action"] as? String else { return text }
                if !["read_file", "propose_change"].contains(action), object["path"] == nil { object["path"] = "." }
                if action != "search_text", object["query"] == nil { object["query"] = "." }
                if action != "propose_change", object["newText"] == nil { object["newText"] = "" }
                guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return text }
                return String(decoding: data, as: UTF8.self)
            }
        }
        func configure(doneReason: String? = nil, malformedEnvelope: Bool = false, redirectResponse: Bool = false,
                       beforeChat: (@Sendable (Int) async throws -> Void)? = nil) {
            self.doneReason = doneReason; self.malformedEnvelope = malformedEnvelope; self.redirectResponse = redirectResponse; self.beforeChat = beforeChat
        }
        func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> (Data, HTTPURLResponse) {
            try Task.checkCancellation()
            calls.append(request)
            var body: Data
            if request.url?.path == "/api/tags" {
                body = Data("{\"models\":[{\"name\":\"huihui_ai/qwen3-abliterated:14b-v2\"}]}".utf8)
            } else if request.url?.path == "/api/generate" { body = Data("{\"done\":true}".utf8) }
            else {
                chatCalls += 1
                try await beforeChat?(chatCalls)
                if malformedEnvelope { body = Data("not JSON".utf8) }
                else {
                    guard !actions.isEmpty else { throw CheckFailure(message: "Unexpected model step") }
                    var object: [String: Any] = ["message": ["role": "assistant", "content": actions.removeFirst()], "done": true]
                    if let doneReason { object["done_reason"] = doneReason }
                    body = try JSONSerialization.data(withJSONObject: object)
                }
            }
            let url = redirectResponse ? URL(string: "https://example.com/api/chat")! : request.url!
            return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        func snapshots() -> [URLRequest] { calls }
        func count() -> Int { chatCalls }
    }

    @discardableResult static func run() async throws -> Int {
        var assertions = 0
        func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try value() else { throw CheckFailure(message: message) }; assertions += 1
        }
        func rejected(_ message: String, _ operation: () throws -> Void) throws {
            do { try operation(); throw CheckFailure(message: message) }
            catch is CheckFailure { throw CheckFailure(message: message) }
            catch { assertions += 1 }
        }
        func rejectedAsync(_ message: String, _ operation: () async throws -> Void) async throws {
            do { try await operation(); throw CheckFailure(message: message) }
            catch is CheckFailure { throw CheckFailure(message: message) }
            catch { assertions += 1 }
        }

        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("bavbav-offline-worker-\(UUID().uuidString)", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("bavbav-offline-outside-\(UUID().uuidString).txt")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture); try? FileManager.default.removeItem(at: outside) }
        let original = "first line\nBavbav green\nthird line\n"
        try Data(original.utf8).write(to: fixture.appendingPathComponent("main.swift"))
        try Data("keep private".utf8).write(to: fixture.appendingPathComponent(".env"))
        try Data("credential".utf8).write(to: fixture.appendingPathComponent("credentials.json"))
        try Data([0, 1, 2, 255]).write(to: fixture.appendingPathComponent("binary.bin"))
        try Data("pdf placeholder".utf8).write(to: fixture.appendingPathComponent("document.pdf"))
        let sampleKey = "sk-" + String(repeating: "f", count: 24)
        let sampleBearer = "Bearer " + String(repeating: "b", count: 24)
        try Data("sample = \(sampleKey)\nauthorization = \(sampleBearer)\n".utf8).write(to: fixture.appendingPathComponent("sample.txt"))
        try Data("-----BEGIN PRIVATE KEY-----\nnot-a-real-key\n-----END PRIVATE KEY-----".utf8).write(to: fixture.appendingPathComponent("material.txt"))
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: fixture.appendingPathComponent("escape.txt"), withDestinationURL: outside)
        try FileManager.default.createDirectory(at: fixture.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try Data("dependency".utf8).write(to: fixture.appendingPathComponent("node_modules/a.txt"))
        var tools = try OfflineFileTools(workspacePath: fixture.path)
        let listing = try tools.listFiles()
        try expect(listing.content.contains("main.swift"), "Allowed source listed")
        try expect(!listing.content.contains(".env") && !listing.content.contains("credentials") && !listing.content.contains("escape") && !listing.content.contains("node_modules"), "Secret/dependency/symlink paths excluded")
        let read = try tools.readFile(path: "main.swift", startLine: 2, maxLines: 1)
        try expect(read.content == "2: Bavbav green", "Bounded line read")
        try expect(read.evidence.contains("sha256") && read.evidence.contains("\"truncated\":true"), "Read evidence records source hash and excerpt limits")
        let search = try tools.searchText(query: "GREEN")
        try expect(search.content.contains("main.swift:2"), "Bounded case-insensitive search")
        try expect(search.evidence.contains("bounded allowed UTF-8"), "Search explicitly records incomplete coverage")
        let proposal = try tools.proposeChange(path: "main.swift", newText: "replacement")
        try expect(proposal.evidence.contains("\"applied\":false") && proposal.evidence.contains("sourceSHA256"), "Proposal is evidence-only with source identity")
        try expect(try String(contentsOf: fixture.appendingPathComponent("main.swift"), encoding: .utf8) == original, "Proposal never changes source")
        try rejected("Parent traversal must fail") { _ = try tools.readFile(path: "../" + outside.lastPathComponent) }
        try rejected("Absolute model path must fail") { _ = try tools.readFile(path: outside.path) }
        try rejected("Symlink must fail") { _ = try tools.readFile(path: "escape.txt") }
        try rejected("Hidden secret must fail") { _ = try tools.readFile(path: ".env") }
        try rejected("Named secret must fail") { _ = try tools.readFile(path: "credentials.json") }
        try rejected("Binary must fail") { _ = try tools.readFile(path: "binary.bin") }
        try rejected("PDF attachment must not silently become text") { _ = try tools.attachment(path: "document.pdf") }
        try rejected("PDF file tool must not silently become text") { _ = try tools.readFile(path: "document.pdf") }
        try rejected("External attachment must fail") { _ = try tools.attachment(path: outside.path) }
        let redacted = try tools.readFile(path: "sample.txt")
        try expect(!redacted.content.contains(sampleKey) && !redacted.content.contains(sampleBearer) && redacted.content.contains("REDACTED_SECRET"), "Source API/Bearer secrets redacted before model observation")
        try expect(redacted.evidence.contains("\"contentRedacted\":true") && !redacted.evidence.contains(sampleKey), "Raw source hash retained but no raw secret in evidence")
        try rejected("Private key material fails closed") { _ = try tools.readFile(path: "material.txt") }
        try rejected("Secret-bearing proposal not recorded") { _ = try tools.proposeChange(path: "main.swift", newText: sampleKey) }
        var tiny = try OfflineFileTools(workspacePath: fixture.path, byteBudget: 4)
        try rejected("Read byte budget enforced") { _ = try tiny.readFile(path: "main.swift") }
        try rejected("Unsafe endpoint refused") { _ = try OllamaOfflineWorker(endpoint: URL(string: "https://example.com")!) }
        try rejected("Global daemon port refused") { _ = try OllamaOfflineWorker(endpoint: URL(string: "http://127.0.0.1:11434")!) }
        try rejected("Credential URL refused") { _ = try OllamaOfflineWorker(endpoint: URL(string: "http://user:secret@127.0.0.1:11439")!) }
        try rejected("Model substitution refused") { _ = try OllamaOfflineWorker(model: "qwen3:14b") }

        func request(_ limits: OfflineLimits = OfflineLimits()) -> OfflineWorkRequest {
            OfflineWorkRequest(deduplicationKey: UUID().uuidString, sourceThreadID: "fixture-thread", workspacePath: fixture.path,
                               objective: "main.swift dosyasını oku ve uygulanmayan bir öneri sun.", limits: limits)
        }
        let recorder = Recorder()
        let stub = Stub([
            "{\"action\":\"read_file\",\"path\":\"main.swift\",\"summary\":\"Read request\",\"output\":\"Await actual tool result\"}",
            "{\"action\":\"propose_change\",\"path\":\"main.swift\",\"newText\":\"proposed only\",\"summary\":\"Proposal request\",\"output\":\"Await proposal receipt\"}",
            "{\"action\":\"finish\",\"summary\":\"Dosya incelendi\",\"output\":\"Öneri hazır, uygulanmadı.\"}"
        ])
        await stub.configure(beforeChat: { count in
            let persisted = await recorder.count()
            guard count == 1 || persisted >= count - 1 else { throw CheckFailure(message: "Model called before progress evidence was persisted") }
        })
        let worker = try OllamaOfflineWorker(transport: stub)
        let models = try await worker.discoverModels()
        try expect(models == [OllamaOfflineWorker.requiredModel], "Exact pinned model discovery")
        let result = try await worker.run(request: request()) { receipt in await recorder.append(receipt) }
        try expect(result.receipts.count == 3, "One receipt per read/proposal/result")
        try expect(result.receipts[0].kind == "tool_read" && result.receipts[1].kind == "change_proposal", "Real tool receipts precede final answer")
        try expect(result.summary.contains("dosyalara uygulanmadı"), "Report is not represented as applied changes")
        try expect(try String(contentsOf: fixture.appendingPathComponent("main.swift"), encoding: .utf8) == original, "Agent loop preserves original source")
        let calls = await stub.snapshots()
        try expect(calls.allSatisfy { $0.url?.host == "127.0.0.1" && $0.url?.port == 11439 && $0.value(forHTTPHeaderField: "Authorization") == nil }, "Only isolated loopback, no API/account credentials")
        let chat = try JSONSerialization.jsonObject(with: calls.first(where: { $0.url?.path == "/api/chat" })!.httpBody!) as! [String: Any]
        let options = chat["options"] as! [String: Any]
        try expect(options["num_ctx"] as? Int == 4096 && chat["think"] as? Bool == false && chat["stream"] as? Bool == false, "Bounded context, no hidden reasoning stream")
        let schema = chat["format"] as! [String: Any]
        let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
        try expect(schema["type"] as? String == "object" && schema["anyOf"] == nil && schema["additionalProperties"] as? Bool == false,
                   "Pinned runtime receives a single closed flat object grammar")
        try expect(Set(schema["required"] as? [String] ?? []) == Set(["action", "path", "query", "newText", "summary", "output"]),
                   "Every generated frame requires all tool fields, summary and output; active paths cannot be skipped")
        try expect(properties["summary"]?["minLength"] as? Int == 1 && properties["output"]?["minLength"] as? Int == 1,
                   "Required summary and output cannot be empty")
        try expect(Set(properties["action"]?["enum"] as? [String] ?? []) == Set(["list_files", "read_file", "search_text", "propose_change", "finish", "needs_network"])
                   && properties["command"] == nil,
                   "Flat action enum exposes only six report-only/read-only capabilities")
        try expect(properties["path"]?["minLength"] as? Int == 1 && properties["query"]?["minLength"] as? Int == 1 && properties["newText"] != nil,
                   "Tool input shapes remain bounded; runtime separately requires action-specific inputs")
        let unload = try JSONSerialization.jsonObject(with: calls.last!.httpBody!) as! [String: Any]
        try expect(calls.last?.url?.path == "/api/generate" && unload["keep_alive"] as? Int == 0 && unload["model"] as? String == OllamaOfflineWorker.requiredModel, "Only own exact model unloaded after work")

        let bad = Stub(["{\"action\":\"shell\",\"query\":\"touch hacked\"}"])
        try await rejectedAsync("Arbitrary command action refused") { _ = try await OllamaOfflineWorker(transport: bad).run(request: request()) { _ in } }
        let unknown = Stub(["{\"action\":\"finish\",\"summary\":\"x\",\"output\":\"x\",\"command\":\"rm\"}"])
        try await rejectedAsync("Unknown JSON fields refused") { _ = try await OllamaOfflineWorker(transport: unknown).run(request: request()) { _ in } }
        let malformed = Stub(["not structured JSON"])
        try await rejectedAsync("Malformed action must not become successful final") { _ = try await OllamaOfflineWorker(transport: malformed).run(request: request()) { _ in } }
        let missingSummary = Stub(["{\"action\":\"finish\",\"output\":\"Never synthesize a missing summary\"}"])
        try await rejectedAsync("Unchanged runtime validator still rejects a missing final summary") { _ = try await OllamaOfflineWorker(transport: missingSummary).run(request: request()) { _ in } }
        let missingReadPath = Stub(["{\"action\":\"read_file\",\"summary\":\"Read request\",\"output\":\"Await actual tool result\"}"])
        try await rejectedAsync("Unchanged runtime validator still rejects a missing read path") { _ = try await OllamaOfflineWorker(transport: missingReadPath).run(request: request()) { _ in } }
        let missingFrameField = Stub(["{\"action\":\"finish\",\"path\":\".\",\"summary\":\"Must fail\",\"output\":\"No production autofill\"}"], fillUnusedFrameFields: false)
        try await rejectedAsync("Production validator never autofills missing frame fields") { _ = try await OllamaOfflineWorker(transport: missingFrameField).run(request: request()) { _ in } }
        let emptyOutput = Stub(["{\"action\":\"finish\",\"summary\":\"Not complete\",\"output\":\"\"}"])
        try await rejectedAsync("Unchanged runtime validator still rejects an empty final output") { _ = try await OllamaOfflineWorker(transport: emptyOutput).run(request: request()) { _ in } }
        let truncated = Stub(["{\"action\":\"finish\",\"summary\":\"x\",\"output\":\"x\"}"])
        await truncated.configure(doneReason: "length")
        try await rejectedAsync("Truncated model result must fail") { _ = try await OllamaOfflineWorker(transport: truncated).run(request: request()) { _ in } }
        let redirected = Stub(["{\"action\":\"finish\",\"summary\":\"x\",\"output\":\"x\"}"])
        await redirected.configure(redirectResponse: true)
        try await rejectedAsync("Injected external redirect response refused") { _ = try await OllamaOfflineWorker(transport: redirected).run(request: request()) { _ in } }
        let persistFailure = Stub(["{\"action\":\"read_file\",\"path\":\"main.swift\",\"summary\":\"Read request\",\"output\":\"Await actual tool result\"}"])
        try await rejectedAsync("Persistence failure must stop model loop") {
            _ = try await OllamaOfflineWorker(transport: persistFailure).run(request: request()) { _ in throw OfflineError.storageFailure("fixture") }
        }
        let persistedFailureCalls = await persistFailure.count()
        try expect(persistedFailureCalls == 1, "No model continuation after failed evidence persistence")
        let unknownCloud = Stub([])
        var unknownRequest = request(); unknownRequest.cloudDisposition = .outcomeUnknown
        try await rejectedAsync("Unknown cloud outcome must not duplicate work") { _ = try await OllamaOfflineWorker(transport: unknownCloud).run(request: unknownRequest) { _ in } }
        let unknownCalls = await unknownCloud.snapshots()
        try expect(unknownCalls.isEmpty, "Unknown cloud outcome never contacts local runtime")
        let steps = Stub(["{\"action\":\"list_files\",\"summary\":\"List request\",\"output\":\"Await actual tool result\"}"])
        try await rejectedAsync("Step cap must not turn unfinished work into success") { _ = try await OllamaOfflineWorker(transport: steps).run(request: request(OfflineLimits(maxSteps: 1))) { _ in } }
        let missingToolMetadata = Stub(["{\"action\":\"read_file\",\"path\":\"main.swift\"}"])
        try await rejectedAsync("Universal metadata contract also fails closed for tool actions") { _ = try await OllamaOfflineWorker(transport: missingToolMetadata).run(request: request()) { _ in } }
        let loop = Stub([
            "{\"action\":\"list_files\",\"summary\":\"First list\",\"output\":\"Waiting\"}",
            "{\"action\":\"list_files\",\"summary\":\"Second list\",\"output\":\"Waiting again\"}",
            "{\"action\":\"list_files\",\"summary\":\"Different metadata cannot bypass loop fence\",\"output\":\"Still waiting\"}"
        ])
        let loopReceipts = Recorder()
        try await rejectedAsync("Third consecutive identical tool action fails instead of looping or fabricating success") {
            _ = try await OllamaOfflineWorker(transport: loop).run(request: request()) { value in await loopReceipts.append(value) }
        }
        let loopEvidence = await loopReceipts.values()
        let loopCalls = await loop.count()
        try expect(loopCalls == 3 && loopEvidence.filter { $0.kind == "tool_read" }.count == 2
                   && loopEvidence.last?.kind == "loop_stopped",
                   "Only two repeated tools run; durable third-repeat stop evidence precedes explicit failure")
        let network = Stub(["{\"action\":\"needs_network\",\"summary\":\"Güncel veri gerekli\",\"output\":\"İnternet olmadan doğrulanamadı.\"}"])
        let waiting = try await OllamaOfflineWorker(transport: network).run(request: request()) { _ in }
        try expect(waiting.receipts.last?.kind == "needs_network" && waiting.summary.contains("tamamlanamadı") && waiting.disposition == .waitingForNetwork, "Unsupported work honestly waits for network, not completed")
        let resumed = Stub(["{\"action\":\"finish\",\"summary\":\"Önceki kayıt korundu\",\"output\":\"Yeni bir işlem çalıştırılmadı.\"}"])
        var resumedRequest = request()
        resumedRequest.checkpointReceipts = [OfflineProgressReceipt(id: "checkpoint-one", kind: "tool_read", summary: "main.swift daha önce okundu", details: "sourceSHA256: prior-hash")]
        _ = try await OllamaOfflineWorker(transport: resumed).run(request: resumedRequest) { _ in }
        let resumedCalls = await resumed.snapshots()
        let resumedBody = String(decoding: resumedCalls.first!.httpBody!, as: UTF8.self)
        try expect(resumedBody.contains("checkpoint-one") && resumedBody.contains("prior-hash"), "Resume includes bounded prior receipts without replaying them as fresh work")
        let cancelled = Stub(["{\"action\":\"finish\",\"summary\":\"must not finish\",\"output\":\"must not finish\"}"])
        await cancelled.configure(beforeChat: { _ in try await Task.sleep(nanoseconds: 10_000_000_000) })
        let cancellation = Task { try await OllamaOfflineWorker(transport: cancelled).run(request: request()) { _ in } }
        for _ in 0..<100 {
            if await cancelled.count() > 0 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        cancellation.cancel()
        try await rejectedAsync("Cancellation during HTTP/model wait must not return success") { _ = try await cancellation.value }
        let cancelledCalls = await cancelled.snapshots()
        try expect(cancelledCalls.last?.url?.path == "/api/generate", "Cancellation still releases only the isolated worker model")
        let secretStub = Stub(["{\"action\":\"finish\",\"summary\":\"Özet\",\"output\":\"\(sampleKey)\"}"])
        var secretRequest = request()
        secretRequest.context = [OfflineContextMessage(role: "user", text: "\(sampleKey) and \(sampleBearer)")]
        secretRequest.objective = "Bu örnek değeri incele: " + sampleKey
        let secretResult = try await OllamaOfflineWorker(transport: secretStub).run(request: secretRequest) { _ in }
        let secretCalls = await secretStub.snapshots()
        let secretBody = String(decoding: secretCalls.first!.httpBody!, as: UTF8.self)
        try expect(!secretBody.contains(sampleKey) && !secretBody.contains(sampleBearer), "Objective/context secrets redacted before transport")
        try expect(!secretResult.output.contains(sampleKey) && secretResult.output.contains("REDACTED_SECRET"), "Final output/handoff secrets redacted")
        print("Ollama worker checks: \(assertions) assertions passed (stub transport; no daemon/model/network used).")
        return assertions
    }
}
