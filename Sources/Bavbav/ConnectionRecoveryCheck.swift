import AppKit
import BavbavCore

@MainActor
enum ConnectionRecoveryCheck {
    private struct Failure: Error { let message: String }

    static func run() async -> Bool {
        guard let fixture = ProcessInfo.processInfo.environment["BAVBAV_CODEX_BIN"],
              fixture.hasSuffix("/BavbavFakeCodex"), FileManager.default.isExecutableFile(atPath: fixture) else {
            print("CONNECTION CHECK REQUIRES LOCAL FAKE SERVER")
            return false
        }
        let suite = "Bavbav.ConnectionCheck.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let store = OverlayStore(defaults: defaults, standaloneDirectory: directory)
        defer {
            setenv("BAVBAV_CODEX_BIN", fixture, 1)
            unsetenv("BAVBAV_FIXTURE_INITIALIZE_FAILURE")
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            checks += 1
            if !condition() { throw Failure(message: message) }
        }
        func settle(_ condition: () -> Bool) async throws {
            for _ in 0..<200 {
                if condition() { return }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            throw Failure(message: "Timeout: \(store.composerError ?? store.connection.shortLabel)")
        }
        do {
            // Explicitly invalid override must fail, not launch the real Codex.
            setenv("BAVBAV_CODEX_BIN", directory.appendingPathComponent("missing-codex").path, 1)
            await store.connectAndLoad()
            try check(store.connection.shortLabel == "OFFLINE", "missing binary is reported")
            try check(store.recentChats.isEmpty && store.codexModels.isEmpty, "failed bootstrap leaves no false ready state")
            await store.refresh()
            try check(store.connection.shortLabel == "OFFLINE", "repeated failed retry terminates without recursion")

            // Simulate installation becoming available. Invoke precisely the
            // path used by the app's 15-second refresh, not manual reconnect.
            setenv("BAVBAV_CODEX_BIN", fixture, 1)
            setenv("BAVBAV_FIXTURE_INITIALIZE_FAILURE", "1", 1)
            await store.refresh()
            try check(store.connection.shortLabel == "OFFLINE", "failed handshake is reported and process cleaned up")
            unsetenv("BAVBAV_FIXTURE_INITIALIZE_FAILURE")
            await store.refresh()
            try check(store.connection.shortLabel == "CODEX", "periodic refresh recovers initial failure")
            try check(!store.codexModels.isEmpty, "recovery completes model/settings bootstrap")
            try check(store.lastSync != nil, "recovery completes catalog load")
            guard let thread = store.recentChats.first else { throw Failure(message: "missing fixture thread") }
            store.selectRecent(id: thread.id)
            store.activateSelection(.recents)
            try await settle { store.detailThread?.id == thread.id }
            store.beginWriting(from: .detail)
            store.composerText = "ECHO"
            store.submitMessage()
            try await settle { !store.messageSending && store.visibleDetailItems.contains { $0.text == "BAVBAV_ECHO_OK" } }
            try check(store.visibleDetailItems.filter { $0.text == "ECHO" }.count == 1, "one user message after recovery")
            try check(store.visibleDetailItems.filter { $0.text == "BAVBAV_ECHO_OK" }.count == 1, "streaming reply arrives after recovery")
            try check(store.runningChatCount == 0, "completion event clears running state")
            await store.refresh()
            try check(store.connection.shortLabel == "CODEX", "subsequent refresh stays connected")
            await store.shutdown()
            print("BAVBAV CONNECTION CHECK PASSED: \(checks) checks; initial failure, retry, models, live fixture echo/completion; no real turns or windows")
            return true
        } catch {
            await store.shutdown()
            print("BAVBAV CONNECTION CHECK FAILED: \(error)")
            return false
        }
    }
}
