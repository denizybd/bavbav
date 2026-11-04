import BavbavCore
import Foundation

@MainActor enum CodexDeliveryCheck {
    private struct Failure: Error { let message: String }
    private final class Recorder {
        var text = "", key: String?
        func record(_ event: CodexServerEvent) {
            func delta(_ next: String, _ text: String) {
                if key != next { self.text += "<\(next)>"; key = next }
                self.text += text
            }
            switch event {
            case .agentMessageDelta(_, _, let item, let text): delta("agent:\(item)", text)
            case .itemTextDelta(_, _, let item, let kind, let title, let text): delta("item:\(item):\(kind.rawValue):\(title)", text)
            case .turnDiffUpdated(_, _, let text): key = nil; self.text += text
            case .turnCompleted: key = nil; text += "!"
            default: key = nil
            }
        }
    }
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock(); private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    static func run() async -> Bool {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
            checks += 1; if !value() { throw Failure(message: message) }
        }
        func wait(_ message: String, _ predicate: () -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            while !predicate() {
                if ProcessInfo.processInfo.systemUptime >= deadline { throw Failure(message: message) }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        do {
            let recorder = Recorder(), finished = Flag()
            let inbox = CodexEventInbox(maximumEvents: 4, maximumBytes: 4096, batchSize: 2) { recorder.record($0) }
            DispatchQueue.global().async {
                for _ in 0..<200 {
                    for _ in 0..<100 { inbox.submit(.agentMessageDelta(threadID: "t", turnID: "turn", itemID: "A", delta: "ğ")) }
                    for _ in 0..<10 { inbox.submit(.agentMessageDelta(threadID: "t", turnID: "turn", itemID: "B", delta: "β")) }
                    for _ in 0..<5 { inbox.submit(.itemTextDelta(threadID: "t", turnID: "turn", itemID: "R", kind: .reasoning, title: "one", delta: "r")) }
                    for _ in 0..<5 { inbox.submit(.itemTextDelta(threadID: "t", turnID: "turn", itemID: "R", kind: .reasoning, title: "two", delta: "s")) }
                    inbox.submit(.turnDiffUpdated(threadID: "t", turnID: "turn", diff: "|"))
                }
                inbox.submit(.turnCompleted(threadID: "t", turnID: "turn", status: "completed", error: nil)); finished.set()
            }
            // Intentionally stall the real consumer until producer backpressure
            // is observed. No GUI, network, account or real worker is used.
            let blockedDeadline = ProcessInfo.processInfo.systemUptime + 2
            while inbox.diagnostics.blockedSubmissions == 0 && ProcessInfo.processInfo.systemUptime < blockedDeadline { Thread.sleep(forTimeInterval: 0.001) }
            try check(inbox.diagnostics.blockedSubmissions > 0 && !finished.isSet, "A stopped main consumer did not backpressure the producer")
            try check(inbox.diagnostics.peakEvents <= 4 && inbox.diagnostics.peakBytes <= 4096, "Queued stream exceeded count/byte bounds")
            try await wait("Stream did not finish after the consumer resumed") { finished.isSet && inbox.diagnostics.queuedEvents == 0 && recorder.text.hasSuffix("!") }
            let group = "<agent:A>" + String(repeating: "ğ", count: 100) + "<agent:B>" + String(repeating: "β", count: 10)
                + "<item:R:reasoning:one>rrrrr<item:R:reasoning:two>sssss|"
            try check(recorder.text == String(repeating: group, count: 200) + "!", "Coalescing lost/reordered Unicode text, item/title boundaries or terminal events")
            try check(inbox.diagnostics.coalescedEvents > 0, "Adjacent token events were not batched")
            inbox.close(); try check(!inbox.submit(.turnDiffUpdated(threadID: "t", turnID: "turn", diff: "late")), "Closed stream accepted a late event")

            let mainRecorder = Recorder(), queued = Flag()
            let mainInbox = CodexEventInbox(maximumEvents: 2, maximumBytes: 4096) { mainRecorder.record($0) }
            DispatchQueue.global().async {
                mainInbox.submit(.turnDiffUpdated(threadID: "t", turnID: "turn", diff: "first"))
                mainInbox.submit(.turnDiffUpdated(threadID: "t", turnID: "turn", diff: "second")); queued.set()
            }
            let mainDeadline = ProcessInfo.processInfo.systemUptime + 2
            while !queued.isSet && ProcessInfo.processInfo.systemUptime < mainDeadline { Thread.sleep(forTimeInterval: 0.001) }
            try check(queued.isSet, "Main-path fixture did not fill the queue")
            mainInbox.submit(.turnCompleted(threadID: "t", turnID: "turn", status: "completed", error: nil))
            try check(mainRecorder.text == "firstsecond!", "Main-thread submit deadlocked or passed preceding events")
            mainInbox.close()

            let closedRecorder = Recorder(), released = Flag()
            let closing = CodexEventInbox(maximumEvents: 1, maximumBytes: 1024) { closedRecorder.record($0) }
            DispatchQueue.global().async {
                closing.submit(.turnDiffUpdated(threadID: "t", turnID: "turn", diff: "queued"))
                if !closing.submit(.turnCompleted(threadID: "t", turnID: "turn", status: "completed", error: nil)) { released.set() }
            }
            let closeDeadline = ProcessInfo.processInfo.systemUptime + 2
            while closing.diagnostics.blockedSubmissions == 0 && ProcessInfo.processInfo.systemUptime < closeDeadline { Thread.sleep(forTimeInterval: 0.001) }
            try check(closing.diagnostics.blockedSubmissions > 0, "Close fixture did not block its producer")
            closing.close()
            try await wait("Shutdown failed to wake a blocked producer") { released.isSet }
            try check(closedRecorder.text.isEmpty && closing.diagnostics.queuedEvents == 0, "Closed generation delivered retained events")
            print("BAVBAV CODEX DELIVERY CHECK PASSED: \(checks) checks; 24000 token events, stalled consumer, byte/count bounds, Unicode/item/title barriers, ordered terminal, main caller and shutdown; fixtures only")
            return true
        } catch {
            print("BAVBAV CODEX DELIVERY CHECK FAILED after \(checks) checks: \(error)")
            return false
        }
    }
}
