import Foundation
import BavbavOffline

enum OfflineLiveCheck {
    private actor SyntheticTrace: OfflineHTTPTransport {
        let transport = OfflineLoopbackTransport()
        func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> (Data, HTTPURLResponse) {
            let result = try await transport.send(request, maximumResponseBytes: maximumResponseBytes)
            if request.url?.path == "/api/chat", CommandLine.arguments.contains("--trace-synthetic") {
                // This flag is confined to this synthetic fixture; production
                // conversations and credential-bearing inputs never use it.
                print("SYNTHETIC MODEL RESPONSE: " + String(decoding: result.0, as: UTF8.self))
            }
            return result
        }
    }
    static func run() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Bavbav.OfflineLive.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) } // Unique synthetic fixture only.
        let workspace = directory.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let marker = "BAVBAV-LOCAL-" + UUID().uuidString
        let file = workspace.appendingPathComponent("input.txt")
        let original = Data("Doğrulama kodu: \(marker)\nSayı: 37\n".utf8)
        try original.write(to: file)
        let worker = try OllamaOfflineWorker(transport: SyntheticTrace())
        let models = try await worker.discoverModels()
        guard models.contains(OfflinePlugin.modelID) else { throw OfflineError.workerFailure("Pinned model missing from isolated runtime") }
        let repository = try OfflineRepository(rootURL: directory.appendingPathComponent("tasks"))
        let coordinator = try OfflineCoordinator(repository: repository, worker: worker)
        let request = OfflineWorkRequest(deduplicationKey: "live-synthetic", sourceThreadID: "synthetic-only",
            workspacePath: workspace.path,
            objective: "Önce read_file aracıyla input.txt dosyasını oku. Sonra finish eyleminde dosyadaki doğrulama kodunu eksiksiz aynen yaz; kodu dosyayı okumadan bilemezsin. Dosyaları değiştirme.",
            limits: OfflineLimits(maxOutputCharacters: 8_000, maxSteps: 4, maxDurationSeconds: 240))
        _ = try await coordinator.enqueue(request)
        guard let result = try await coordinator.runNext(), result.phase == .completed,
              result.result?.output.contains(marker) == true,
              result.receipts.contains(where: { $0.kind.contains("read") }),
              try Data(contentsOf: file) == original else {
            let record = await coordinator.task(id: request.id)
            throw OfflineError.workerFailure("Real local read/answer validation failed: \(record?.errorMessage ?? record?.result?.output ?? "no output")")
        }
        let report = try await coordinator.prepareHandoff(id: request.id)
        guard report.text.contains(marker), report.modelID == OfflinePlugin.modelID else {
            throw OfflineError.workerFailure("Local handoff report missing verified result")
        }
        if let position = CommandLine.arguments.firstIndex(of: "--offline-report"),
           CommandLine.arguments.indices.contains(position + 1) {
            let value: [String: Any] = ["success": true, "model": OfflinePlugin.modelID,
                "endpoint": "http://127.0.0.1:11439", "realInference": true, "realFileRead": true,
                "sourceUnchanged": true, "syntheticDataOnly": true, "productionChatUsed": false,
                "cloudMessagesSent": 0, "receipts": result.receipts.count, "result": result.result?.output ?? ""]
            try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: CommandLine.arguments[position + 1]), options: .atomic)
        }
        print("OFFLINE LIVE CHECK PASSED: real pinned Qwen3 14B on repository-owned Ollama; actual file read and nonce answer, source unchanged, durable handoff report; synthetic data only, no cloud/account interaction")
    }
}
