import AppKit
import BavbavCore
import SwiftUI

@MainActor final class AccountFixtureRPC {
    let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private var buffer = Data(), nextID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private(set) var ready = false
    init(node: String, fixture: String) throws {
        process.executableURL = URL(fileURLWithPath: node); process.arguments = [fixture]
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            Task { @MainActor in self?.receive(bytes) }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        try process.run()
    }
    private func receive(_ bytes: Data) {
        buffer.append(bytes)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
            guard let frame = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if frame["type"] as? String == "ready" { ready = true }
            guard let id = frame["id"] as? Int, let query = pending.removeValue(forKey: id) else { continue }
            if let error = frame["error"] as? String { query.resume(throwing: CodexClientError.rpcError(error)) }
            else { query.resume(returning: frame["result"] as? [String: Any] ?? [:]) }
        }
    }
    func call(_ role: String, _ method: String, _ args: [String: Any]) async throws -> [String: Any] {
        nextID += 1; let id = nextID
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                var bytes = try JSONSerialization.data(withJSONObject: ["id": id, "role": role, "method": method, "args": args]); bytes.append(10)
                try input.fileHandleForWriting.write(contentsOf: bytes)
            } catch { pending.removeValue(forKey: id)?.resume(throwing: error) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.pending.removeValue(forKey: id)?.resume(throwing: CodexClientError.timeout(method)) }
        }
    }
    func close() async {
        try? input.fileHandleForWriting.close()
        for _ in 0..<100 { if !process.isRunning { break }; try? await Task.sleep(nanoseconds: 30_000_000) }
        output.fileHandleForReading.readabilityHandler = nil; errors.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }
}

@MainActor enum SharedAccountCheck {
    static func require(_ condition: @autoclosure () -> Bool, _ detail: String) throws { if !condition() { throw CodexClientError.invalidResponse(detail) } }
    static func wait(_ label: String, seconds: Double = 20, _ check: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !check() { if Date() > deadline { throw CodexClientError.timeout(label) }; try await Task.sleep(nanoseconds: 40_000_000) }
    }
    static func run(node: String, fixture: String, output: URL, live: Bool = false, interactive: Bool = false) async -> Bool {
        let suite = "Bavbav.AccountCheck.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        var rpc: AccountFixtureRPC?, a: SharedAccountChat?, b: SharedAccountChat?
        var report: [String: Any] = ["success": false, "productionDataUsed": live, "productionAppUpdated": false, "realSecondMac": false, "liveInference": live]
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let wire = try AccountFixtureRPC(node: node, fixture: fixture); rpc = wire
            try await wait("paired localhost broker startup") { wire.ready }
            let first = SharedAccountChat(defaults: defaults) { method, args in try await wire.call("deniz", method, args) }; a = first; first.start()
            if live {
                try await wait("existing ChatGPT account ready", seconds: 40) { first.localReady }
                try await wait("Noise connection ready") { first.peerAvailable == false && first.role == "deniz" }
                try await Task.sleep(nanoseconds: 800_000_000)
                let request = UUID().uuidString.lowercased()
                _ = try await wire.call("emir", "accountSend", ["id": request, "conversation": UUID().uuidString.lowercased(), "owner": "deniz", "text": "Yalnızca BAVBAV_HESAP_TESTI_OK yaz."])
                var phase = "", answer = ""
                for _ in 0..<150 {
                    let events = try await wire.call("emir", "accountPoll", ["after": 0])["events"] as? [[String: Any]] ?? []
                    if let last = events.last(where: { $0["id"] as? String == request }) { phase = last["phase"] as? String ?? ""; answer = last["text"] as? String ?? "" }
                    if ["completed", "failed", "interrupted"].contains(phase) { break }; try await Task.sleep(nanoseconds: 400_000_000)
                }
                try require(phase == "completed" && answer.contains("BAVBAV_HESAP_TESTI_OK"), "Live account inference did not complete: \(phase): \(answer): \(first.error ?? "")")
                report["realOwnerAccountReply"] = answer; report["requester"] = "emir (localhost fixture)"; report["owner"] = "deniz"; report["success"] = true
            } else {
                var failNextPoll = false
                let second = SharedAccountChat(defaults: defaults) { method, args in
                    if method == "accountPoll", failNextPoll { failNextPoll = false; throw CodexClientError.disconnected }
                    return try await wire.call("emir", method, args)
                }; b = second; second.start()
                try await wait("both local fixture accounts ready") { first.localReady && second.localReady && second.peerAvailable }
                try require(first.sharing && !second.sharing, "Emir's account was shared without opting in")
                second.owner = "deniz"; second.draft = "Emir Deniz hesabıyla konuşuyor"
                let window = SharedAccountWindow(service: second); window.show()
                try await Task.sleep(nanoseconds: 350_000_000)
                try render(output.appendingPathComponent("account-chat-ready.png"))
                if interactive { try await wait("external send button click", seconds: 240) { !second.messages.isEmpty } }
                else { second.send(); second.send() }
                try await wait("remote-owner streamed reply", seconds: 30) { second.messages.last?.phase == "completed" }
                try require(second.messages.count == 2 && second.messages.last?.text == "YANIT: Emir Deniz hesabıyla konuşuyor", "A single send was duplicated or response text was lost")
                try require(second.messages.allSatisfy { $0.owner == "deniz" } && second.messages.first?.author == "emir", "Requester and billing owner were confused")
                try require(second.draft.isEmpty && second.activeID == nil, "Acknowledged draft or completed turn remained busy")
                try render(output.appendingPathComponent("account-chat-reply.png"))
                report["oneActionRemoteReply"] = true; report["physicalUIAction"] = interactive
                second.sharing = true
                try await wait("Emir opted in") { first.peerAvailable }
                first.owner = "emir"; first.draft = "Deniz Emir hesabıyla konuşuyor"; first.send()
                try await wait("reverse account reply") { first.messages.last?.phase == "completed" }
                try require(first.messages.last?.owner == "emir", "Reverse selection used the wrong account")
                report["bothDirections"] = true
                first.sharing = false
                try await wait("share disabled") { !second.peerAvailable }
                second.draft = "Bu taslak korunmalı"; let count = second.messages.count; second.send()
                try require(second.messages.count == count && second.draft == "Bu taslak korunmalı", "Unavailable owner consumed a draft or fell back to another account")
                first.sharing = true; try await wait("sharing restored") { second.peerAvailable }
                second.draft = "ACCOUNT_HOLD"; second.send()
                try await wait("held request running") { first.hostingRequester == "emir" && second.activeID != nil }
                second.cancel(); try await wait("cancelled request") { second.activeID == nil }
                try require(second.messages.last?.phase == "interrupted", "Stop did not retire the remote request")
                report["stopAndRevocation"] = true
                try await Task.sleep(nanoseconds: 1000_000_000)
                second.draft = "ACCOUNT_HOLD"; second.send()
                try await wait("held request before IPC failure") { first.hostingRequester == "emir" && second.activeID != nil }
                failNextPoll = true
                try await wait("IPC failure retires pending message") { second.activeID == nil && second.messages.last?.phase == "failed" && first.hostingRequester == nil }
                try await wait("IPC recovery readiness") { second.peerAvailable }
                second.draft = "Bağlantı sonrası yeni mesaj"; second.send()
                try await wait("new request after IPC recovery") { second.messages.last?.phase == "completed" }
                try require(second.messages.last?.text == "YANIT: Bağlantı sonrası yeni mesaj", "IPC recovery lost the next reply or retried a stopped message")
                report["engineIPCRecovery"] = true
                second.draft = "ACCOUNT_TOOL_REQUEST"; second.send()
                try await wait("unexpected tool request denied") { second.messages.last?.phase == "failed" && second.activeID == nil }
                report["hostToolsDenied"] = true; report["success"] = true
                NSApp.windows.filter { $0.identifier?.rawValue == "bavbav.account-chat" }.forEach { $0.orderOut(nil) }
                withExtendedLifetime(window) {}
            }
        } catch { report["error"] = error.localizedDescription }
        await a?.shutdown(); await b?.shutdown(); await rpc?.close()
        defaults.removePersistentDomain(forName: suite)
        let filename = live ? "live-account-report.json" : interactive ? "interactive-account-report.json" : "account-report.json"
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(filename), options: .atomic)
        print(String(data: (try? JSONSerialization.data(withJSONObject: report)) ?? Data(), encoding: .utf8) ?? "")
        return report["success"] as? Bool == true
    }
    private static func render(_ url: URL) throws {
        guard let view = NSApp.windows.first(where: { $0.identifier?.rawValue == "bavbav.account-chat" })?.contentView else { throw CodexClientError.invalidResponse("Account window missing") }
        view.layoutSubtreeIfNeeded(); guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CodexClientError.invalidResponse("Account window render failed") }
        view.cacheDisplay(in: view.bounds, to: bitmap); try bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}
