import Foundation
import BavbavCompanion
import CompanionSafety

@MainActor private final class TestConversation: CompanionConversation {
    var sent: [(String, URL?)] = []
    var stopped = 0
    var pending: CheckedContinuation<String, Error>?
    var delay = false
    func connect() async throws -> String { "fixture-thread" }
    func send(text: String, image: URL?) async throws -> String {
        sent.append((text, image))
        if delay { return try await withCheckedThrowingContinuation { pending = $0 } }
        return "Türkçe deneme yanıtı"
    }
    func stop() async { stopped += 1 }
}
@MainActor private final class TestScreen: CompanionScreenSource {
    var captures: [CompanionWindow] = []
    var pending: CheckedContinuation<Data, Error>?
    var delay = false
    let window = CompanionWindow(id: 42, pid: 123, bundleID: "test.demo", label: "Fixture only")
    func windows() async throws -> [CompanionWindow] { [window] }
    func capture(_ window: CompanionWindow) async throws -> Data {
        captures.append(window)
        if delay { return try await withCheckedThrowingContinuation { pending = $0 } }
        return Data("fixture-not-a-real-screen".utf8)
    }
}

@MainActor final class CompanionTests {
    var directories: [URL] = []
    func cleanUp() { for directory in directories { try? FileManager.default.removeItem(at: directory) } }
    func testOriginalStopGateRevokesEpochAndNeverGrantsControl() {
        let fence = CompanionFence(); let first = fence.token
        expectTrue(fence.accepts(first)); fence.revoke()
        expectFalse(fence.accepts(first)); let second = fence.token
        fence.revoke(); expectFalse(fence.accepts(second))
        let gate = SafetyGate()
        expectNil(gate.status().ownerID)
        expectEqual(gate.emergencyStop().state, "cancelled")
        expectNil(gate.status().target)
    }

    @MainActor private func makeSession(_ conversation: TestConversation, _ screen: TestScreen) -> CompanionSession {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bavbav-companion-test-\(UUID())")
        directories.append(directory)
        let session = CompanionSession(conversation: conversation, screen: screen, directory: directory)
        session.speakReplies = false
        return session
    }
    @MainActor func testSelectionDoesNotCaptureOrSend() async {
        let conversation = TestConversation(); let screen = TestScreen(); let session = makeSession(conversation, screen)
        await session.listWindows(); session.selectWindow(screen.window)
        expectEqual(session.windows, [screen.window]); expectTrue(screen.captures.isEmpty)
        expectTrue(conversation.sent.isEmpty); expectNil(session.preview); expectFalse(session.includePreview)
        await session.capturePreview()
        expectEqual(screen.captures, [screen.window]); expectNotNil(session.preview)
        expectTrue(conversation.sent.isEmpty); expectFalse(session.includePreview)
    }
    @MainActor func testImageRequiresExplicitOneShotConsent() async {
        let conversation = TestConversation(); let screen = TestScreen(); let session = makeSession(conversation, screen)
        await session.connect(); session.selectWindow(screen.window); await session.capturePreview()
        session.draft = "Merhaba"; await session.send()
        expectEqual(conversation.sent.count, 1); expectNil(conversation.sent[0].1)
        session.selectWindow(screen.window); await session.capturePreview()
        session.includePreview = true; session.draft = "Bu pencereyi açıkla"; await session.send()
        expectNotNil(conversation.sent[1].1); expectFalse(session.includePreview); expectNil(session.preview)
        expectEqual(session.lines.count, 4)
        session.draft = "Sonraki"; await session.send()
        expectNil(conversation.sent[2].1)
        session.stop()
    }
    @MainActor func testChangingTargetRejectsLateCapture() async {
        let conversation = TestConversation(); let screen = TestScreen(); screen.delay = true
        let session = makeSession(conversation, screen); session.selectWindow(screen.window)
        let task = Task { await session.capturePreview() }
        while screen.pending == nil { await Task.yield() }
        session.selectWindow(CompanionWindow(id: 99, pid: 456, bundleID: "other", label: "Other"))
        screen.pending?.resume(returning: Data([1, 2, 3])); await task.value
        expectNil(session.preview); expectFalse(session.includePreview); expectEqual(session.selection?.id, 99)
    }
    @MainActor func testStopRejectsLateReplyAndKeepsDraft() async {
        let conversation = TestConversation(); conversation.delay = true
        let session = makeSession(conversation, TestScreen()); await session.connect()
        session.draft = "Bunu koru"
        let task = Task { await session.send() }
        while conversation.pending == nil { await Task.yield() }
        session.stop()
        expectFalse(session.connected); expectFalse(session.sending); expectFalse(session.speech.listening)
        conversation.pending?.resume(returning: "Geç kalan yanıt"); await task.value
        expectTrue(session.lines.isEmpty); expectEqual(session.draft, "Bunu koru")
        expectFalse(session.speech.speaking)
    }
    @MainActor func testDuplicateSendAndNoAutomaticRetry() async {
        let conversation = TestConversation(); conversation.delay = true
        let session = makeSession(conversation, TestScreen()); await session.connect(); session.draft = "Bir kez"
        let task = Task { await session.send() }
        while conversation.pending == nil { await Task.yield() }
        await session.send(); expectEqual(conversation.sent.count, 1)
        conversation.pending?.resume(throwing: CompanionFailure("Fixture failure")); await task.value
        expectEqual(session.draft, "Bir kez"); expectFalse(session.sending)
        expectTrue(session.lines.isEmpty); expectEqual(conversation.sent.count, 1)
        session.stop()
    }
    @MainActor func testStopRejectsLateCaptureAndInvalidConsent() async {
        let conversation = TestConversation(); let screen = TestScreen(); screen.delay = true
        let session = makeSession(conversation, screen); await session.connect(); session.selectWindow(screen.window)
        let task = Task { await session.capturePreview() }
        while screen.pending == nil { await Task.yield() }
        session.stop(); screen.pending?.resume(returning: Data([1])); await task.value
        expectNil(session.preview); expectNil(session.selection); expectFalse(session.capturing)
        while session.stopping { await Task.yield() }
        await session.connect(); session.includePreview = true; await session.send()
        expectTrue(conversation.sent.isEmpty); expectFalse(session.includePreview)
        session.stop()
    }
}

@MainActor private var checks = 0
@MainActor private func expectTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    checks += 1
    guard value else { fputs("COMPANION CHECK FAILED: \(file):\(line)\n", stderr); Foundation.exit(1) }
}
@MainActor private func expectFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { expectTrue(!value, file: file, line: line) }
@MainActor private func expectNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { expectTrue(value == nil, file: file, line: line) }
@MainActor private func expectNotNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { expectTrue(value != nil, file: file, line: line) }
@MainActor private func expectEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { expectTrue(a == b, file: file, line: line) }

@main enum CompanionChecks {
    @MainActor static func main() async {
        let tests = CompanionTests()
        defer { tests.cleanUp() }
        tests.testOriginalStopGateRevokesEpochAndNeverGrantsControl()
        await tests.testSelectionDoesNotCaptureOrSend()
        await tests.testImageRequiresExplicitOneShotConsent()
        await tests.testChangingTargetRejectsLateCapture()
        await tests.testStopRejectsLateReplyAndKeepsDraft()
        await tests.testDuplicateSendAndNoAutomaticRetry()
        await tests.testStopRejectsLateCaptureAndInvalidConsent()
        if ProcessInfo.processInfo.environment["BAVBAV_COMPANION_CHECK"] == "1" {
            expectTrue(ProcessInfo.processInfo.environment["BAVBAV_CODEX_BIN"]?.hasSuffix("BavbavFakeCodex") == true)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bavbav-companion-protocol-\(UUID())")
            let bridge = CodexCompanionConversation(directory: folder, ephemeral: true)
            do {
                _ = try await bridge.connect()
                let text = try await bridge.send(text: "fixture", image: nil)
                expectEqual(text, "COMPANION_TEXT_OK")
                let png = folder.appendingPathComponent("fixture.png")
                try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a9WQAAAAASUVORK5CYII=")!.write(to: png)
                let imageReply = try await bridge.send(text: "fixture image", image: png)
                expectEqual(imageReply, "COMPANION_IMAGE_OK")
                await bridge.stop()
                try? FileManager.default.removeItem(at: folder)
            } catch { await bridge.stop(); fputs("COMPANION PROTOCOL FAILED: \(error)\n", stderr); Foundation.exit(1) }
        }
        print("COMPANION CHECKS PASSED: \(checks) assertions; fixtures only, no microphone or account proof")
    }
}
