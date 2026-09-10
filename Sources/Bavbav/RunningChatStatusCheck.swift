import AppKit
import BavbavCore

@MainActor
enum RunningChatStatusCheck {
    static func run() -> Bool {
        let suite = "Bavbav.StatusCountCheck.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = OverlayStore(defaults: defaults)
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        var presenter: RunningChatStatus? = RunningChatStatus(store: store, button: button)
        var checks = 0; var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) { checks += 1; if !condition { failures.append(label) } }
        func expectCount(_ count: Int, _ label: String) {
            expect(store.runningChatCount == count && button.attributedTitle.string == String(count), label)
        }
        expectCount(0, "idle shows zero, never an icon")
        expect(button.image == nil && button.imagePosition == .noImage, "number only")
        expect(button.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == BavbavTheme.focusAccent,
               "exact same color object as window focus ring")
        store.handleServerEvent(.turnStarted(threadID: "hidden-a", turnID: "a1"))
        expectCount(1, "hidden chat counts without any open window")
        store.handleServerEvent(.turnStarted(threadID: "hidden-a", turnID: "a1"))
        expectCount(1, "duplicate events cannot double count")
        store.handleServerEvent(.turnStarted(threadID: "hidden-b", turnID: "b1"))
        expectCount(2, "simultaneous independent chats")
        store.clearCurrentDetail(threadID: "hidden-a")
        expectCount(2, "Q closing UI does not stop or discount background work")
        let request = CodexInteractionRequest(requestID: .string("ask-a"), threadID: "hidden-a", turnID: "a1", itemID: nil,
            kind: .commandApproval, title: "Fixture", summary: "", detail: "", options: [])
        store.handleServerEvent(.interactionRequested(request))
        expectCount(1, "awaiting user input is waiting, not working")
        store.handleServerEvent(.interactionResolved(requestID: .string("ask-a"), threadID: "hidden-a"))
        expectCount(2, "resumed chat returns immediately")
        store.handleServerEvent(.turnCompleted(threadID: "hidden-a", turnID: "old-turn", status: "completed", error: nil))
        expectCount(2, "stale completion cannot discount a newer running turn")
        store.handleServerEvent(.turnCompleted(threadID: "hidden-a", turnID: "a1", status: "completed", error: nil))
        expectCount(1, "completion decrements immediately")
        store.handleServerEvent(.turnCompleted(threadID: "hidden-a", turnID: "a1", status: "completed", error: nil))
        expectCount(1, "duplicate completion never makes count negative")
        for index in 0..<12 { store.handleServerEvent(.turnStarted(threadID: "many-\(index)", turnID: "t")) }
        expectCount(13, "multi-digit count")
        store.handleServerEvent(.transportClosed(message: "fixture disconnected"))
        expectCount(0, "transport loss clears stale working count")
        presenter = nil
        store.handleServerEvent(.turnStarted(threadID: "released", turnID: "t"))
        expect(button.attributedTitle.string == "0", "presenter releases subscription")
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            button.appearance = NSAppearance(named: name)
            RunningChatStatus.apply(count: 12, to: button)
            expect(button.attributedTitle.string == "12" && button.attributedAlternateTitle.string == "12",
                   "plain digits retained across appearances")
        }
        withExtendedLifetime(presenter) {}
        if failures.isEmpty { print("BAVBAV STATUS COUNT CHECK PASSED: \(checks) checks; lifecycle, background, waiting, duplicates and native title styling") }
        else { failures.forEach { print("STATUS COUNT CHECK FAILED: \($0)") } }
        return failures.isEmpty
    }
}
