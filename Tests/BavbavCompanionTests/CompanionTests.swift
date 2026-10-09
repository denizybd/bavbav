import Foundation
import BavbavCompanion
import CompanionSafety

@MainActor private final class TestConversation: CompanionConversation {
    var connections = 0
    var delayConnect = false
    var connectFailure = false
    var pendingConnections: [Int: CheckedContinuation<String, Error>] = [:]
    var sent: [(String, URL?)] = []
    var stopped = 0
    var pending: CheckedContinuation<String, Error>?
    var delay = false
    var reconnectFailure = false
    var cancelledSends = 0
    var delayStop = false
    var pendingStop: CheckedContinuation<Void, Never>?
    var disconnectionHandler: ((String) -> Void)?
    func setDisconnectionHandler(_ handler: ((String) -> Void)?) { disconnectionHandler = handler }
    var replyHandler: ((String) -> Void)?
    func setReplyHandler(_ handler: ((String) -> Void)?) { replyHandler = handler }
    func connect() async throws -> String {
        connections += 1
        if delayConnect {
            let attempt = connections
            return try await withCheckedThrowingContinuation { pendingConnections[attempt] = $0 }
        }
        if connectFailure { throw CompanionFailure("Fixture account unavailable") }
        return "fixture-thread"
    }
    func send(text: String, image: URL?) async throws -> String {
        sent.append((text, image))
        if reconnectFailure { throw CompanionFailure("Fixture disconnected", requiresReconnect: true) }
        if delay {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { pending = $0 }
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancelledSends += 1 }
            }
        }
        return "Türkçe deneme yanıtı"
    }
    func stop() async {
        stopped += 1
        if delayStop { await withCheckedContinuation { pendingStop = $0 } }
    }
}
@MainActor private final class TestSpeech: CompanionSpeechDriving {
    var onTranscript: ((String) -> Void)?
    var onDictationFinished: ((String) -> Void)?
    var onSpeakingFinished: (() -> Void)?
    var onDictationFailed: ((String) -> Void)?
    var dictationBusy = false
    var speaking = false
    var status = "Fixture speech idle"
    var starts: [(allowAppleService: Bool, endOnSilence: Bool)] = []
    var utterances: [String] = []
    var listeningStops = 0
    var speakingStops = 0
    var pendingStart: CheckedContinuation<Void, Never>?
    var delayStart = false
    private var generation = UUID()
    func start(allowAppleService: Bool, endOnSilence: Bool) async {
        starts.append((allowAppleService, endOnSilence))
        let token = generation
        if delayStart { await withCheckedContinuation { pendingStart = $0 } }
        guard generation == token else { return }
        dictationBusy = true; status = "Fixture listening"
    }
    func finishListening() { dictationBusy = false }
    func stopListening() { generation = UUID(); listeningStops += 1; dictationBusy = false }
    func speak(_ text: String) { utterances.append(text); speaking = true; status = "Fixture speaking" }
    func stopSpeaking() { speakingStops += 1; speaking = false }
    func stop() { stopListening(); stopSpeaking() }
    func completeDictation(_ text: String) {
        onTranscript?(text); dictationBusy = false; onDictationFinished?(text)
    }
    func completeSpeaking() { speaking = false; onSpeakingFinished?() }
    func failDictation(_ message: String) { dictationBusy = false; onDictationFailed?(message) }
}
@MainActor private final class TestScreen: CompanionScreenSource {
    var lists = 0
    var captures: [CompanionWindow] = []
    var pending: CheckedContinuation<Data, Error>?
    var delay = false
    var displayLists = 0
    var capturedDisplays: [CompanionDisplay] = []
    var pendingDisplayCapture: CheckedContinuation<Data, Error>?
    var delayDisplay = false
    var displayPreparations = 0
    var denyDisplayPreparation = false
    var delayDisplayPreparation = false
    var pendingDisplayPreparation: CheckedContinuation<Void, Error>?
    var listedDisplays: [CompanionDisplay]?
    let window = CompanionWindow(id: 42, pid: 123, bundleID: "test.demo", label: "Fixture only")
    let display = CompanionDisplay(id: 7, width: 1440, height: 900, label: "Fixture display")
    func windows() async throws -> [CompanionWindow] { lists += 1; return [window] }
    func capture(_ window: CompanionWindow) async throws -> Data {
        captures.append(window)
        if delay { return try await withCheckedThrowingContinuation { pending = $0 } }
        return Data("fixture-not-a-real-screen".utf8)
    }
    func prepareDisplaySelection() async throws {
        displayPreparations += 1
        if denyDisplayPreparation { throw CompanionFailure("Fixture Screen Recording denied") }
        if delayDisplayPreparation { try await withCheckedThrowingContinuation { pendingDisplayPreparation = $0 } }
    }
    func displays() async throws -> [CompanionDisplay] { displayLists += 1; return listedDisplays ?? [display] }
    func captureDisplay(_ display: CompanionDisplay) async throws -> Data {
        capturedDisplays.append(display)
        if delayDisplay { return try await withCheckedThrowingContinuation { pendingDisplayCapture = $0 } }
        return Data("fixture-not-a-real-display".utf8)
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

    func testIndependentAcceptanceGates() {
        for mask in 0..<16 {
            var verification = CompanionVerification()
            verification.accountMessage = mask & 1 != 0
            verification.selectedWindowToModel = mask & 2 != 0
            verification.turkishMicrophoneRecognition = mask & 4 != 0
            verification.audibleTurkishResponse = mask & 8 != 0
            expectEqual(verification.automatedGatesPassed, mask & 3 == 3)
            expectEqual(verification.productComplete, mask == 15)
        }
    }

    func testDictationFinalizationAndDraftProtection() {
        var recognition = CompanionDictationLifecycle()
        let first = recognition.begin()!
        expectEqual(recognition.phase, .preparing); expectFalse(recognition.acceptsTranscript(first))
        expectNil(recognition.begin()); expectTrue(recognition.listen(first))
        expectTrue(recognition.acceptsTranscript(first)); expectTrue(recognition.finalize(first))
        expectEqual(recognition.phase, .finalizing); expectTrue(recognition.acceptsTranscript(first))
        expectNil(recognition.begin()); expectEqual(recognition.token, first)
        expectTrue(recognition.complete(first)); expectFalse(recognition.acceptsTranscript(first))
        let second = recognition.begin()!
        expectFalse(recognition.complete(first)); expectEqual(recognition.phase, .preparing)
        expectTrue(recognition.listen(second)); recognition.cancel()
        expectFalse(recognition.acceptsTranscript(second)); expectFalse(recognition.complete(second))
        expectEqual(recognition.phase, .idle); expectNotNil(recognition.begin())
        expectEqual(CompanionDictationLifecycle.finalizationTimeoutNanoseconds, 2_000_000_000)

        var draft = CompanionDictationDraft(original: "Önceki metin")
        let partial = draft.merge(transcript: "Merha", currentDraft: "Önceki metin")!
        expectEqual(partial, "Önceki metin\nMerha")
        let final = draft.merge(transcript: "Merhaba Deniz", currentDraft: partial)!
        expectEqual(final, "Önceki metin\nMerhaba Deniz")
        expectNil(draft.merge(transcript: "Geç sonuç", currentDraft: final + " · elle düzenlendi"))
        var editedDuringPermission = CompanionDictationDraft(original: "Başlangıç")
        expectNil(editedDuringPermission.merge(transcript: "Konuşma", currentDraft: "Yeni elle yazılan metin"))
        var empty = CompanionDictationDraft(original: "")
        expectEqual(empty.merge(transcript: "Türkçe", currentDraft: ""), "Türkçe")
    }

    @MainActor private func makeSession(_ conversation: TestConversation, _ screen: TestScreen) -> CompanionSession {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bavbav-companion-test-\(UUID())")
        directories.append(directory)
        let session = CompanionSession(conversation: conversation, screen: screen, directory: directory)
        session.speakReplies = false
        return session
    }
    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        expectTrue(condition())
    }
    private func settleTasks() async { for _ in 0..<20 { await Task.yield() } }
    private func makeVoiceSession(_ conversation: TestConversation, _ screen: TestScreen, _ speech: TestSpeech) -> CompanionSession {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bavbav-companion-voice-test-\(UUID())")
        directories.append(directory)
        return CompanionSession(conversation: conversation, screen: screen, directory: directory, speechDriver: speech)
    }
    func testRepeatedOpenConnectsOnceWithoutMediaOrSend() async {
        let conversation = TestConversation(); conversation.delayConnect = true
        let screen = TestScreen(); let session = makeSession(conversation, screen)
        let first = Task { await session.connect() }
        while conversation.pendingConnections[1] == nil { await Task.yield() }
        let duplicateOpens = (0..<8).map { _ in Task { await session.connect() } }
        for task in duplicateOpens { await task.value }
        expectEqual(conversation.connections, 1); expectTrue(session.connecting)
        expectFalse(session.connected); expectNil(session.threadID)
        expectTrue(conversation.sent.isEmpty); expectEqual(screen.lists, 0); expectTrue(screen.captures.isEmpty)
        expectFalse(session.speech.dictationBusy); expectFalse(session.speech.speaking)
        conversation.pendingConnections.removeValue(forKey: 1)?.resume(returning: "first-open")
        await first.value
        expectTrue(session.connected); expectFalse(session.connecting); expectEqual(session.threadID, "first-open")
        for _ in 0..<8 { await session.connect() }
        expectEqual(conversation.connections, 1); expectTrue(conversation.sent.isEmpty)
        expectEqual(screen.lists, 0); expectTrue(screen.captures.isEmpty)
        expectFalse(session.speech.dictationBusy); expectFalse(session.speech.speaking)
        await session.shutdown()
    }

    func testStopDuringConnectRejectsLateSuccessAndFailure() async {
        for oldFails in [false, true] {
            let conversation = TestConversation(); conversation.delayConnect = true; conversation.delayStop = true
            let screen = TestScreen(); let session = makeSession(conversation, screen)
            let old = Task { await session.connect() }
            while conversation.pendingConnections[1] == nil { await Task.yield() }
            session.stop()
            expectFalse(session.connecting); expectFalse(session.connected); expectNil(session.threadID)
            expectTrue(session.stopping)
            await session.connect(); expectEqual(conversation.connections, 1)
            while conversation.pendingStop == nil { await Task.yield() }
            conversation.pendingStop?.resume()
            while session.stopping { await Task.yield() }
            let replacement = Task { await session.connect() }
            while conversation.pendingConnections[2] == nil { await Task.yield() }
            let status = session.status
            let stale = conversation.pendingConnections.removeValue(forKey: 1)
            if oldFails { stale?.resume(throwing: CompanionFailure("Stale connection failure")) }
            else { stale?.resume(returning: "stale-thread") }
            await old.value
            expectTrue(session.connecting); expectFalse(session.connected); expectNil(session.threadID)
            expectEqual(session.status, status)
            conversation.pendingConnections.removeValue(forKey: 2)?.resume(returning: "replacement-thread")
            await replacement.value
            expectTrue(session.connected); expectFalse(session.connecting)
            expectEqual(session.threadID, "replacement-thread"); expectEqual(conversation.connections, 2)
            expectTrue(conversation.sent.isEmpty); expectEqual(screen.lists, 0); expectTrue(screen.captures.isEmpty)
            expectFalse(session.speech.dictationBusy); expectFalse(session.speech.speaking)
            conversation.delayStop = false
            await session.shutdown(); expectEqual(conversation.stopped, 2)
        }
    }

    func testFailedAccountConnectionAllowsSafeRetry() async {
        let conversation = TestConversation(); conversation.connectFailure = true
        let screen = TestScreen(); let session = makeSession(conversation, screen)
        session.draft = "Bağlantı için kendiliğinden gönderme"
        await session.connect()
        expectFalse(session.connecting); expectFalse(session.connected); expectNil(session.threadID)
        expectEqual(session.status, "Fixture account unavailable")
        conversation.connectFailure = false
        await session.connect()
        expectTrue(session.connected); expectEqual(conversation.connections, 2)
        expectEqual(session.draft, "Bağlantı için kendiliğinden gönderme")
        expectTrue(conversation.sent.isEmpty); expectEqual(screen.lists, 0); expectTrue(screen.captures.isEmpty)
        expectFalse(session.speech.dictationBusy); expectFalse(session.speech.speaking)
        await session.shutdown()
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

    func testShutdownWaitsForOneStop() async {
        let conversation = TestConversation(); conversation.delayStop = true
        let session = makeSession(conversation, TestScreen()); await session.connect()
        session.stop()
        while conversation.pendingStop == nil { await Task.yield() }
        var firstFinished = false; var secondFinished = false
        let first = Task { await session.shutdown(); firstFinished = true }
        let second = Task { await session.shutdown(); secondFinished = true }
        await Task.yield()
        expectEqual(conversation.stopped, 1); expectTrue(session.stopping)
        expectFalse(firstFinished); expectFalse(secondFinished)
        conversation.pendingStop?.resume(); await first.value; await second.value
        expectTrue(firstFinished); expectTrue(secondFinished); expectFalse(session.stopping)
        await session.shutdown(); expectEqual(conversation.stopped, 1)
        let coldConversation = TestConversation()
        await makeSession(coldConversation, TestScreen()).shutdown()
        expectEqual(coldConversation.stopped, 0)
    }

    func testDisconnectedFailureOffersReconnectAndKeepsDraft() async {
        let conversation = TestConversation(); conversation.reconnectFailure = true
        let session = makeSession(conversation, TestScreen()); await session.connect()
        session.draft = "Bu metin korunsun"; await session.send()
        expectFalse(session.connected); expectNil(session.threadID); expectFalse(session.sending)
        expectEqual(session.draft, "Bu metin korunsun"); expectEqual(conversation.sent.count, 1)
        conversation.reconnectFailure = false
        await session.connect(); expectTrue(session.connected)
        await session.send(); expectEqual(session.lines.count, 2)
        await session.shutdown()
    }

    func testIdleDisconnectionClearsSessionAndPreservesDraft() async {
        let conversation = TestConversation(); let screen = TestScreen()
        let session = makeSession(conversation, screen)
        await session.connect()
        session.draft = "Bağlantı koparsa bu metni koru"
        conversation.disconnectionHandler?("Fixture idle transport closed")
        expectFalse(session.connected); expectFalse(session.connecting)
        expectNil(session.threadID); expectFalse(session.sending)
        expectEqual(session.draft, "Bağlantı koparsa bu metni koru")
        expectFalse(session.speech.dictationBusy); expectFalse(session.speech.speaking)
        expectTrue(conversation.sent.isEmpty); expectTrue(screen.captures.isEmpty)
        await session.connect()
        expectTrue(session.connected); expectEqual(conversation.connections, 2)
        expectTrue(conversation.sent.isEmpty)
        await session.shutdown()
    }

    func testDisplaySelectionIsNotCaptureOrShareConsent() async {
        let conversation = TestConversation(); let screen = TestScreen()
        let session = makeSession(conversation, screen)
        await session.listDisplays(); session.selectDisplay(screen.display)
        expectEqual(session.displays, [screen.display]); expectEqual(screen.displayLists, 1)
        expectEqual(session.displaySelection, screen.display); expectFalse(session.screenSharing)
        expectTrue(screen.capturedDisplays.isEmpty); expectTrue(conversation.sent.isEmpty)
        expectEqual(conversation.connections, 0)
        await session.shareScreenNow()
        expectTrue(screen.capturedDisplays.isEmpty); expectTrue(conversation.sent.isEmpty)
        await session.shutdown()
    }

    func testPeriodicFramePreservesDraftAndRemovesTransientFile() async {
        let conversation = TestConversation(); let screen = TestScreen()
        let session = makeSession(conversation, screen)
        session.draft = "Yazarken taslağımı silme"
        session.selectDisplay(screen.display)
        await session.startScreenSharing()
        await waitUntil { session.lastSharedAt != nil }
        expectTrue(session.screenSharing); expectTrue(session.connected)
        expectEqual(conversation.connections, 1); expectEqual(conversation.sent.count, 1)
        expectEqual(screen.capturedDisplays, [screen.display]); expectTrue(screen.captures.isEmpty)
        expectEqual(session.draft, "Yazarken taslağımı silme")
        expectEqual(session.lines.count, 1); expectNotNil(session.preview)
        expectFalse(session.sending); expectFalse(session.capturing)
        expectFalse(session.speech.speaking); expectFalse(session.includePreview)
        let image = conversation.sent[0].1
        expectNotNil(image)
        expectEqual(image?.deletingLastPathComponent().lastPathComponent, "ScreenFrames")
        expectFalse(FileManager.default.fileExists(atPath: image?.path ?? ""))
        session.stopScreenSharing()
        await session.shareScreenNow()
        expectEqual(conversation.sent.count, 1); expectNil(session.preview)
        await session.shutdown()
    }

    func testShareTicksHaveOneCaptureAndStopRejectsLateFrame() async {
        let conversation = TestConversation(); let screen = TestScreen(); screen.delayDisplay = true
        let session = makeSession(conversation, screen)
        await session.connect(); session.selectDisplay(screen.display)
        await session.startScreenSharing()
        await waitUntil { screen.pendingDisplayCapture != nil }
        let duplicateTicks = (0..<8).map { _ in Task { await session.shareScreenNow() } }
        for task in duplicateTicks { await task.value }
        expectEqual(screen.capturedDisplays.count, 1); expectTrue(session.capturing)
        expectTrue(conversation.sent.isEmpty)
        session.draft = "Capture devam ederken ikinci yazar açma"
        await session.send()
        expectTrue(conversation.sent.isEmpty)
        session.stopScreenSharing()
        expectFalse(session.screenSharing); expectFalse(session.capturing)
        screen.pendingDisplayCapture?.resume(returning: Data("Late frame".utf8))
        screen.pendingDisplayCapture = nil
        await settleTasks()
        expectTrue(conversation.sent.isEmpty); expectNil(session.preview)
        expectNil(session.lastSharedAt); expectTrue(session.connected)
        await session.shutdown()
    }

    func testIdleLossRevokesPendingScreenFrameAndNeverRestartsSharing() async {
        let conversation = TestConversation(); let screen = TestScreen(); screen.delayDisplay = true
        let session = makeSession(conversation, screen)
        await session.connect(); session.selectDisplay(screen.display)
        await session.startScreenSharing()
        await waitUntil { screen.pendingDisplayCapture != nil }
        session.draft = "Bağlantı koparken bu metni koru"
        conversation.disconnectionHandler?("Fixture idle exit during capture")
        expectFalse(session.connected); expectFalse(session.screenSharing)
        expectFalse(session.capturing); expectFalse(session.sending)
        screen.pendingDisplayCapture?.resume(returning: Data("Stale frame".utf8))
        screen.pendingDisplayCapture = nil
        await settleTasks()
        expectTrue(conversation.sent.isEmpty); expectNil(session.preview)
        expectFalse(session.speech.dictationBusy); expectFalse(session.speech.speaking)
        await session.connect(); await session.shareScreenNow()
        expectTrue(session.connected); expectFalse(session.screenSharing)
        expectTrue(conversation.sent.isEmpty); expectEqual(screen.capturedDisplays.count, 1)
        expectEqual(session.draft, "Bağlantı koparken bu metni koru")
        await session.shutdown()
    }

    func testCancelledNativeCaptureDoesNotDisconnectAccount() async {
        let conversation = TestConversation(); let screen = TestScreen(); screen.delayDisplay = true
        let session = makeSession(conversation, screen)
        await session.connect(); session.selectDisplay(screen.display)
        session.draft = "Ekran yakalamayı iptal ederken taslağımı koru"
        await session.startScreenSharing()
        await waitUntil { screen.pendingDisplayCapture != nil }
        session.stopScreenSharing()
        screen.pendingDisplayCapture?.resume(throwing: CancellationError())
        screen.pendingDisplayCapture = nil
        await settleTasks()
        expectTrue(session.connected); expectEqual(session.threadID, "fixture-thread")
        expectFalse(session.screenSharing); expectFalse(session.sending); expectFalse(session.capturing)
        expectEqual(session.draft, "Ekran yakalamayı iptal ederken taslağımı koru")
        expectTrue(conversation.sent.isEmpty); expectEqual(conversation.stopped, 0)
        expectNil(session.preview); expectNil(session.lastSharedAt)
        await session.shareScreenNow()
        expectTrue(conversation.sent.isEmpty); expectEqual(screen.capturedDisplays.count, 1)
        await session.shutdown()
    }

    func testShareStopDrainsOneOwnedReplyWithoutNewSendOrSpeech() async {
        let conversation = TestConversation(); conversation.delay = true
        let screen = TestScreen(); let session = makeSession(conversation, screen)
        session.draft = "Paylaşırken bu taslak kalsın"
        await session.connect(); session.selectDisplay(screen.display)
        await session.startScreenSharing()
        await waitUntil { conversation.pending != nil }
        let image = conversation.sent[0].1
        expectNotNil(image); expectTrue(FileManager.default.fileExists(atPath: image?.path ?? ""))
        await session.shareScreenNow(); await session.send()
        expectEqual(conversation.sent.count, 1); expectEqual(screen.capturedDisplays.count, 1)
        session.stopScreenSharing()
        expectFalse(session.screenSharing); expectTrue(session.sending); expectNil(session.preview)
        expectEqual(conversation.stopped, 0)
        conversation.pending?.resume(returning: "Geç ekran gözlemi")
        conversation.pending = nil
        await waitUntil { !session.sending }
        await session.shareScreenNow()
        expectEqual(conversation.sent.count, 1); expectTrue(session.lines.isEmpty)
        expectNil(session.lastSharedAt); expectEqual(session.draft, "Paylaşırken bu taslak kalsın")
        expectFalse(session.speech.speaking); expectTrue(session.connected)
        expectFalse(FileManager.default.fileExists(atPath: image?.path ?? ""))
        await session.shutdown()
    }

    func testFullStopAndReconnectNeverRestoreSharingOrOldReply() async {
        let conversation = TestConversation(); conversation.delay = true
        let screen = TestScreen(); let session = makeSession(conversation, screen)
        await session.connect(); session.selectDisplay(screen.display)
        await session.startScreenSharing()
        await waitUntil { conversation.pending != nil }
        let image = conversation.sent[0].1
        let oldReply = conversation.pending; conversation.pending = nil
        session.draft = "Kapatırken bu metni koru"
        session.stop()
        expectFalse(session.screenSharing); expectFalse(session.sending); expectFalse(session.connected)
        expectNil(session.displaySelection); expectNil(session.preview)
        await session.waitForPendingStop()
        await session.connect()
        expectTrue(session.connected); expectFalse(session.screenSharing)
        expectEqual(conversation.connections, 2); expectEqual(conversation.sent.count, 1)
        oldReply?.resume(returning: "Eski paylaşım yanıtı")
        await settleTasks()
        await session.shareScreenNow()
        expectEqual(conversation.sent.count, 1); expectTrue(session.lines.isEmpty)
        expectNil(session.lastSharedAt); expectEqual(session.draft, "Kapatırken bu metni koru")
        expectFalse(FileManager.default.fileExists(atPath: image?.path ?? ""))
        conversation.delay = false
        await session.shutdown()
    }

    func testPeriodicTransportFailureStopsWithoutRetryAndRemovesFrame() async {
        let conversation = TestConversation(); conversation.reconnectFailure = true
        let screen = TestScreen(); let session = makeSession(conversation, screen)
        session.draft = "Hata olursa bu metni koru"
        session.selectDisplay(screen.display)
        await session.startScreenSharing()
        await waitUntil { !session.screenSharing }
        expectFalse(session.connected); expectFalse(session.sending)
        expectEqual(conversation.sent.count, 1); expectEqual(screen.capturedDisplays.count, 1)
        expectTrue(session.lines.isEmpty); expectEqual(session.draft, "Hata olursa bu metni koru")
        expectFalse(FileManager.default.fileExists(atPath: conversation.sent[0].1?.path ?? ""))
        conversation.reconnectFailure = false
        await session.connect(); await session.shareScreenNow()
        expectFalse(session.screenSharing); expectEqual(conversation.sent.count, 1)
        await session.shutdown()
    }

    func testScreenIntervalBoundsAndNoStartWithoutDisplay() async {
        let conversation = TestConversation(); let screen = TestScreen()
        let session = makeSession(conversation, screen)
        expectEqual(session.screenShareInterval, 10)
        session.screenShareInterval = -100; expectEqual(session.screenShareInterval, 3)
        session.screenShareInterval = 120; expectEqual(session.screenShareInterval, 60)
        session.screenShareInterval = .nan; expectEqual(session.screenShareInterval, 10)
        session.screenShareInterval = .infinity; expectEqual(session.screenShareInterval, 10)
        session.screenShareInterval = 3.5; expectEqual(session.screenShareInterval, 3.5)
        await session.startScreenSharing()
        expectFalse(session.screenSharing); expectEqual(conversation.connections, 0)
        expectTrue(conversation.sent.isEmpty); expectTrue(screen.capturedDisplays.isEmpty)
        await session.shutdown()
    }

    func testAccountConnectDoesNotStartVoiceOrPermissionFlow() async {
        let conversation = TestConversation(); let screen = TestScreen(); let speech = TestSpeech()
        let session = makeVoiceSession(conversation, screen, speech)
        session.draft = "Bu taslağı kendiliğinden gönderme"
        await session.connect()
        expectTrue(session.connected); expectFalse(session.voiceConversationActive)
        expectTrue(speech.starts.isEmpty); expectTrue(speech.utterances.isEmpty)
        expectEqual(screen.displayPreparations, 0); expectEqual(screen.displayLists, 0)
        expectTrue(screen.capturedDisplays.isEmpty); expectTrue(conversation.sent.isEmpty)
        expectEqual(session.draft, "Bu taslağı kendiliğinden gönderme")
        await session.shutdown()
    }

    func testStartedVoiceSubmitsOnceStreamsActualReplyAndResumesAfterSpeech() async {
        let conversation = TestConversation(); conversation.delay = true
        let screen = TestScreen(); let speech = TestSpeech()
        let session = makeVoiceSession(conversation, screen, speech)
        session.draft = "Sesli konuşma elle yazdığımı bozmasın"
        await session.startVoiceConversation()
        for _ in 0..<5 { await session.startVoiceConversation() }
        expectTrue(session.voiceConversationActive); expectEqual(speech.starts.count, 1)
        expectTrue(speech.starts[0].endOnSilence); expectFalse(speech.starts[0].allowAppleService)
        expectTrue(speech.dictationBusy); expectTrue(conversation.sent.isEmpty)
        let finished = speech.onDictationFinished
        speech.completeDictation("Merhaba, gerçek bir Türkçe konuşma")
        finished?("Aynı döngünün ikinci bitişi")
        await waitUntil { conversation.pending != nil }
        expectEqual(conversation.sent.count, 1)
        expectEqual(conversation.sent[0].0, "Merhaba, gerçek bir Türkçe konuşma")
        expectNil(conversation.sent[0].1); expectTrue(speech.utterances.isEmpty)
        expectEqual(session.draft, "Sesli konuşma elle yazdığımı bozmasın")
        conversation.replyHandler?("Gerçek kısmi yanıt")
        expectEqual(session.liveReply, "Gerçek kısmi yanıt"); expectTrue(speech.utterances.isEmpty)
        conversation.pending?.resume(returning: "Gerçek tamamlanmış Türkçe yanıt")
        conversation.pending = nil
        await waitUntil { speech.speaking }
        expectEqual(speech.utterances, ["Gerçek tamamlanmış Türkçe yanıt"])
        expectEqual(session.liveReply, ""); expectFalse(speech.dictationBusy)
        expectEqual(session.lines.map(\.text), ["Merhaba, gerçek bir Türkçe konuşma", "Gerçek tamamlanmış Türkçe yanıt"])
        let speakingFinished = speech.onSpeakingFinished
        speech.completeSpeaking(); speakingFinished?()
        await waitUntil { speech.starts.count == 2 }
        expectTrue(session.voiceConversationActive); expectTrue(speech.dictationBusy)
        expectEqual(conversation.sent.count, 1); expectTrue(screen.capturedDisplays.isEmpty)
        expectEqual(screen.displayPreparations, 0)
        session.pauseVoiceConversation(); await session.shutdown()
    }

    func testPausingSubmittedVoiceDrainsSilentlyWithoutCancellationOrRestart() async {
        let conversation = TestConversation(); conversation.delay = true
        let screen = TestScreen(); let speech = TestSpeech()
        let session = makeVoiceSession(conversation, screen, speech)
        await session.startVoiceConversation()
        let oldTranscript = speech.onTranscript; let oldFinished = speech.onDictationFinished
        speech.completeDictation("Gönderilen konuşma")
        await waitUntil { conversation.pending != nil }
        session.pauseVoiceConversation()
        oldTranscript?("Eski geç metin"); oldFinished?("Eski geç bitiş")
        expectFalse(session.voiceConversationActive); expectFalse(speech.dictationBusy)
        expectTrue(session.sending); expectEqual(conversation.sent.count, 1)
        await settleTasks(); expectEqual(conversation.cancelledSends, 0)
        conversation.pending?.resume(returning: "Sessizce tamamlanan gerçek yanıt")
        conversation.pending = nil
        await waitUntil { !session.sending }
        expectTrue(speech.utterances.isEmpty); expectEqual(speech.starts.count, 1)
        expectEqual(session.lines.map(\.text), ["Gönderilen konuşma", "Sessizce tamamlanan gerçek yanıt"])
        expectTrue(session.connected); expectEqual(conversation.cancelledSends, 0)
        await session.shutdown()
    }

    func testStopReplyAudioAndMuteRejectStaleRestartCallbacks() async {
        for useMute in [false, true] {
            let conversation = TestConversation(); let screen = TestScreen(); let speech = TestSpeech()
            let session = makeVoiceSession(conversation, screen, speech)
            await session.startVoiceConversation(); speech.completeDictation("Yanıtı seslendir")
            await waitUntil { speech.speaking }
            let oldFinish = speech.onSpeakingFinished
            if useMute { session.mute() } else { session.stopReplyAudio() }
            oldFinish?()
            await settleTasks()
            expectFalse(session.voiceConversationActive); expectFalse(speech.speaking)
            expectFalse(speech.dictationBusy); expectEqual(speech.starts.count, 1)
            expectEqual(conversation.sent.count, 1)
            expectEqual(session.muted, useMute)
            await session.shutdown()
        }
    }

    func testVoiceErrorsAndEmptyRecognitionPauseWithoutRetry() async {
        for scenario in ["empty", "device", "transport"] {
            let conversation = TestConversation(); let screen = TestScreen(); let speech = TestSpeech()
            let session = makeVoiceSession(conversation, screen, speech)
            session.draft = "Hata sırasında elle yazılan taslak"
            await session.startVoiceConversation()
            if scenario == "empty" { speech.completeDictation("   ") }
            else if scenario == "device" { speech.failDictation("Fixture microphone changed") }
            else {
                conversation.reconnectFailure = true
                speech.completeDictation("Hata alan konuşma")
            }
            await waitUntil { !session.voiceConversationActive && !session.sending }
            expectFalse(speech.dictationBusy); expectFalse(speech.speaking)
            expectTrue(speech.utterances.isEmpty); expectEqual(speech.starts.count, 1)
            expectEqual(session.draft, "Hata sırasında elle yazılan taslak")
            expectEqual(conversation.sent.count, scenario == "transport" ? 1 : 0)
            if scenario == "transport" {
                expectFalse(session.connected)
                expectEqual(session.lines.map(\.text), ["Hata alan konuşma"])
                conversation.reconnectFailure = false
                await session.connect()
                expectFalse(session.voiceConversationActive); expectEqual(speech.starts.count, 1)
            }
            await session.shutdown()
        }
    }

    func testVoiceStopDuringPermissionPreparationRejectsLateStartAndCallbacks() async {
        let conversation = TestConversation(); let screen = TestScreen(); let speech = TestSpeech(); speech.delayStart = true
        let session = makeVoiceSession(conversation, screen, speech)
        let start = Task { await session.startVoiceConversation() }
        await waitUntil { speech.pendingStart != nil }
        let oldFinished = speech.onDictationFinished
        session.stop()
        speech.pendingStart?.resume(); speech.pendingStart = nil
        await start.value
        oldFinished?("İzin tamamlandıktan sonra gelen eski konuşma")
        await settleTasks()
        expectFalse(session.voiceConversationActive); expectFalse(speech.dictationBusy)
        expectFalse(session.connected); expectTrue(conversation.sent.isEmpty)
        expectTrue(speech.utterances.isEmpty)
        await session.shutdown()
    }

    func testOldVoiceCompletionCannotClobberReplacementSendOwnership() async {
        let conversation = TestConversation(); conversation.delay = true
        let screen = TestScreen(); let speech = TestSpeech()
        let session = makeVoiceSession(conversation, screen, speech)
        await session.startVoiceConversation()
        let oldDictationFinished = speech.onDictationFinished
        speech.completeDictation("İlk oturum konuşması")
        await waitUntil { conversation.pending != nil }
        let oldReply = conversation.pending; conversation.pending = nil
        session.stop(); await session.waitForPendingStop(); await settleTasks()
        let cancellationsAfterStop = conversation.cancelledSends
        await session.startVoiceConversation()
        expectTrue(session.voiceConversationActive)
        oldDictationFinished?("Eski döngünün geç bitişi")
        expectEqual(conversation.sent.count, 1)
        speech.completeDictation("Yeni oturum konuşması")
        await waitUntil { conversation.pending != nil }
        expectEqual(conversation.sent.count, 2)
        oldReply?.resume(returning: "Eski oturumun geç cevabı")
        await settleTasks()
        expectTrue(session.sending)
        expectFalse(session.lines.contains { $0.text == "Eski oturumun geç cevabı" })
        session.pauseVoiceConversation(); await settleTasks()
        expectEqual(conversation.cancelledSends, cancellationsAfterStop)
        conversation.pending?.resume(returning: "Yeni oturumun sessiz gerçek cevabı")
        conversation.pending = nil
        await waitUntil { !session.sending }
        expectTrue(speech.utterances.isEmpty)
        expectTrue(session.lines.contains { $0.text == "Yeni oturumun sessiz gerçek cevabı" })
        expectFalse(session.voiceConversationActive)
        await session.shutdown()
    }

    func testVoiceQueuesOneTurnAfterHeldScreenAndTakesWriterPriority() async {
        let conversation = TestConversation(); conversation.delay = true
        let screen = TestScreen(); let speech = TestSpeech()
        let session = makeVoiceSession(conversation, screen, speech)
        await session.startVoiceConversation(); session.selectDisplay(screen.display)
        await session.startScreenSharing()
        await waitUntil { conversation.pending != nil }
        expectEqual(conversation.sent.count, 1); expectNotNil(conversation.sent[0].1)
        let screenReply = conversation.pending; conversation.pending = nil
        speech.completeDictation("Ekrandan sonra öncelikli konuşmam")
        await settleTasks()
        expectEqual(conversation.sent.count, 1); expectTrue(session.voiceConversationActive)
        await session.shareScreenNow(); expectEqual(screen.capturedDisplays.count, 1)
        screenReply?.resume(returning: "Gerçek ekran yanıtı")
        await waitUntil { conversation.pending != nil && conversation.sent.count == 2 }
        expectEqual(conversation.sent[1].0, "Ekrandan sonra öncelikli konuşmam")
        expectNil(conversation.sent[1].1); expectTrue(speech.utterances.isEmpty)
        expectTrue(session.screenSharing)
        session.pauseVoiceConversation()
        expectTrue(session.screenSharing)
        conversation.pending?.resume(returning: "Ses kapatılınca sessizce gelen yanıt")
        conversation.pending = nil
        await waitUntil { !session.sending }
        expectTrue(speech.utterances.isEmpty); expectEqual(conversation.cancelledSends, 0)
        session.stop()
        expectFalse(session.screenSharing); expectFalse(session.voiceConversationActive)
        await session.shutdown()
    }

    func testNaturalSpeechCompletionWaitsForHeldScreenThenResumesMicrophone() async {
        let conversation = TestConversation(); let screen = TestScreen(); let speech = TestSpeech()
        let session = makeVoiceSession(conversation, screen, speech)
        await session.startVoiceConversation(); speech.completeDictation("Önce sesli yanıt al")
        await waitUntil { speech.speaking }
        expectEqual(speech.starts.count, 1)
        conversation.delay = true
        session.selectDisplay(screen.display); await session.startScreenSharing()
        await waitUntil { conversation.pending != nil }
        expectEqual(conversation.sent.count, 2); expectNotNil(conversation.sent[1].1)
        speech.completeSpeaking()
        try? await Task.sleep(nanoseconds: 350_000_000)
        expectTrue(session.voiceConversationActive); expectTrue(session.sending)
        expectEqual(speech.starts.count, 1); expectFalse(speech.dictationBusy)
        conversation.pending?.resume(returning: "Ekran isteği tamamlandı")
        conversation.pending = nil
        await waitUntil { speech.starts.count == 2 }
        expectTrue(speech.dictationBusy); expectTrue(session.voiceConversationActive)
        expectTrue(session.connected); expectFalse(session.sending)
        expectEqual(conversation.sent.count, 2); expectEqual(screen.capturedDisplays.count, 1)
        expectEqual(speech.utterances, ["Türkçe deneme yanıtı"])
        session.pauseVoiceConversation(); await session.shutdown()
    }

    func testPauseOrStopWhileResumeWaitsRejectsLateMicrophoneRestart() async {
        for fullStop in [false, true] {
            let conversation = TestConversation(); let screen = TestScreen(); let speech = TestSpeech()
            let session = makeVoiceSession(conversation, screen, speech)
            await session.startVoiceConversation(); speech.completeDictation("Yanıt sonrası bekleyen mikrofon")
            await waitUntil { speech.speaking }
            conversation.delay = true
            session.selectDisplay(screen.display); await session.startScreenSharing()
            await waitUntil { conversation.pending != nil }
            let screenReply = conversation.pending; conversation.pending = nil
            speech.completeSpeaking()
            try? await Task.sleep(nanoseconds: 350_000_000)
            expectEqual(speech.starts.count, 1); expectTrue(session.voiceConversationActive)
            if fullStop { session.stop(); await session.waitForPendingStop() }
            else { session.pauseVoiceConversation() }
            screenReply?.resume(returning: "Duraklatmadan sonra geç ekran cevabı")
            await settleTasks()
            try? await Task.sleep(nanoseconds: 100_000_000)
            expectFalse(session.voiceConversationActive); expectFalse(speech.dictationBusy)
            expectEqual(speech.starts.count, 1); expectEqual(conversation.sent.count, 2)
            expectEqual(session.connected, !fullStop)
            expectEqual(session.screenSharing, !fullStop)
            await session.shutdown()
        }
    }

    func testDisplayPermissionRetryAutoSelectsOnlySoleDisplayWithoutCapture() async {
        let conversation = TestConversation(); let screen = TestScreen()
        let session = makeSession(conversation, screen)
        screen.denyDisplayPreparation = true
        await session.listDisplays()
        expectEqual(screen.displayPreparations, 1); expectEqual(screen.displayLists, 0)
        expectFalse(session.requestingScreenPermission); expectNil(session.displaySelection)
        screen.denyDisplayPreparation = false
        await session.listDisplays()
        expectEqual(screen.displayPreparations, 2); expectEqual(session.displaySelection, screen.display)
        expectTrue(screen.capturedDisplays.isEmpty); expectFalse(session.screenSharing)
        expectTrue(conversation.sent.isEmpty); expectEqual(conversation.connections, 0)
        let second = CompanionDisplay(id: 8, width: 1920, height: 1080, label: "Second fixture display")
        session.selectDisplay(nil); screen.listedDisplays = [screen.display, second]
        await session.listDisplays()
        expectNil(session.displaySelection); expectEqual(session.displays.count, 2)
        screen.listedDisplays = []; await session.listDisplays()
        expectTrue(session.displays.isEmpty); expectNil(session.displaySelection)
        await session.shutdown()
    }

    func testStopRejectsLateDisplayPermissionPreparation() async {
        let conversation = TestConversation(); let screen = TestScreen(); screen.delayDisplayPreparation = true
        let session = makeSession(conversation, screen)
        let listing = Task { await session.listDisplays() }
        await waitUntil { screen.pendingDisplayPreparation != nil }
        session.stop()
        screen.pendingDisplayPreparation?.resume(); screen.pendingDisplayPreparation = nil
        await listing.value
        expectEqual(screen.displayLists, 0); expectTrue(session.displays.isEmpty)
        expectNil(session.displaySelection); expectFalse(session.screenSharing)
        expectFalse(session.requestingScreenPermission); expectFalse(session.capturing)
        expectTrue(screen.capturedDisplays.isEmpty); expectTrue(conversation.sent.isEmpty)
        await session.shutdown()
    }
}

@MainActor var checks = 0
@MainActor func expectTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    checks += 1
    guard value else { fputs("COMPANION CHECK FAILED: \(file):\(line)\n", stderr); Foundation.exit(1) }
}
@MainActor func expectFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { expectTrue(!value, file: file, line: line) }
@MainActor func expectNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { expectTrue(value == nil, file: file, line: line) }
@MainActor func expectNotNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { expectTrue(value != nil, file: file, line: line) }
@MainActor func expectEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { expectTrue(a == b, file: file, line: line) }

@main enum CompanionChecks {
    @MainActor static func main() async {
        let tests = CompanionTests()
        defer { tests.cleanUp() }
        tests.testOriginalStopGateRevokesEpochAndNeverGrantsControl()
        tests.testIndependentAcceptanceGates()
        tests.testDictationFinalizationAndDraftProtection()
        CompanionSpeechEndpointTests.run()
        await tests.testRepeatedOpenConnectsOnceWithoutMediaOrSend()
        await tests.testStopDuringConnectRejectsLateSuccessAndFailure()
        await tests.testFailedAccountConnectionAllowsSafeRetry()
        await tests.testSelectionDoesNotCaptureOrSend()
        await tests.testImageRequiresExplicitOneShotConsent()
        await tests.testChangingTargetRejectsLateCapture()
        await tests.testStopRejectsLateReplyAndKeepsDraft()
        await tests.testDuplicateSendAndNoAutomaticRetry()
        await tests.testStopRejectsLateCaptureAndInvalidConsent()
        await tests.testShutdownWaitsForOneStop()
        await tests.testDisconnectedFailureOffersReconnectAndKeepsDraft()
        await tests.testIdleDisconnectionClearsSessionAndPreservesDraft()
        await tests.testDisplaySelectionIsNotCaptureOrShareConsent()
        await tests.testPeriodicFramePreservesDraftAndRemovesTransientFile()
        await tests.testShareTicksHaveOneCaptureAndStopRejectsLateFrame()
        await tests.testIdleLossRevokesPendingScreenFrameAndNeverRestartsSharing()
        await tests.testCancelledNativeCaptureDoesNotDisconnectAccount()
        await tests.testShareStopDrainsOneOwnedReplyWithoutNewSendOrSpeech()
        await tests.testFullStopAndReconnectNeverRestoreSharingOrOldReply()
        await tests.testPeriodicTransportFailureStopsWithoutRetryAndRemovesFrame()
        await tests.testScreenIntervalBoundsAndNoStartWithoutDisplay()
        await tests.testAccountConnectDoesNotStartVoiceOrPermissionFlow()
        await tests.testStartedVoiceSubmitsOnceStreamsActualReplyAndResumesAfterSpeech()
        await tests.testPausingSubmittedVoiceDrainsSilentlyWithoutCancellationOrRestart()
        await tests.testStopReplyAudioAndMuteRejectStaleRestartCallbacks()
        await tests.testVoiceErrorsAndEmptyRecognitionPauseWithoutRetry()
        await tests.testVoiceStopDuringPermissionPreparationRejectsLateStartAndCallbacks()
        await tests.testOldVoiceCompletionCannotClobberReplacementSendOwnership()
        await tests.testVoiceQueuesOneTurnAfterHeldScreenAndTakesWriterPriority()
        await tests.testNaturalSpeechCompletionWaitsForHeldScreenThenResumesMicrophone()
        await tests.testPauseOrStopWhileResumeWaitsRejectsLateMicrophoneRestart()
        await tests.testDisplayPermissionRetryAutoSelectsOnlySoleDisplayWithoutCapture()
        await tests.testStopRejectsLateDisplayPermissionPreparation()
        if ProcessInfo.processInfo.environment["BAVBAV_COMPANION_CHECK"] == "1" {
            expectTrue(ProcessInfo.processInfo.environment["BAVBAV_CODEX_BIN"]?.hasSuffix("BavbavFakeCodex") == true)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bavbav-companion-protocol-\(UUID())")
            let bridge = CodexCompanionConversation(directory: folder, ephemeral: true)
            var replySnapshots: [String] = []
            bridge.setReplyHandler { replySnapshots.append($0) }
            do {
                _ = try await bridge.connect()
                let text = try await bridge.send(text: "fixture", image: nil)
                expectEqual(text, "COMPANION_TEXT_OK")
                expectEqual(replySnapshots, ["COMPANION_TEXT_OK"])
                replySnapshots = []
                let png = folder.appendingPathComponent("fixture.png")
                try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a9WQAAAAASUVORK5CYII=")!.write(to: png)
                let imageReply = try await bridge.send(text: "fixture image", image: png)
                expectEqual(imageReply, "COMPANION_IMAGE_OK")
                expectEqual(replySnapshots, ["COMPANION_IMAGE_OK"])
                replySnapshots = []
                let staleReply = try await bridge.send(text: "COMPANION_STALE_SAME_THREAD", image: nil)
                expectEqual(staleReply, "COMPANION_TEXT_OK")
                expectEqual(replySnapshots, ["COMPANION_TEXT_OK"])
                let delayed = try await bridge.send(text: "COMPANION_TERMINAL_ACK_FIRST", image: nil)
                expectEqual(delayed, "COMPANION_DELAYED_FINAL_OK")
                await bridge.stop()
                await checkCancellationAndRecovery(folder: folder)
                await checkIdleDisconnectionAndRecovery(folder: folder)
                await checkLiveReplyStreaming(folder: folder)
                try? FileManager.default.removeItem(at: folder)
            } catch { await bridge.stop(); fputs("COMPANION PROTOCOL FAILED: \(error)\n", stderr); Foundation.exit(1) }
        }
        print("COMPANION CHECKS PASSED: \(checks) assertions; fixtures only, no microphone or account proof")
    }

    @MainActor private static func requests(_ log: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: log) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
    }

    @MainActor private static func waitForRequest(_ method: String, log: URL) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let request = requests(log).last(where: { $0["method"] as? String == method }) { return request }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw CompanionFailure("Fixture request was not observed: \(method)")
    }

    @MainActor private static func checkCancellationAndRecovery(folder: URL) async {
        for scenario in ["COMPANION_HOLD_AFTER_ACK", "COMPANION_HOLD_BEFORE_ACK"] {
            let directory = folder.appendingPathComponent(scenario, isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let log = directory.appendingPathComponent("requests.jsonl")
            setenv("BAVBAV_COMPANION_REQUEST_LOG", log.path, 1)
            let bridge = CodexCompanionConversation(directory: directory, ephemeral: true)
            do {
                _ = try await bridge.connect()
                let pending = Task { try await bridge.send(text: scenario, image: nil) }
                _ = try await waitForRequest("turn/start", log: log)
                if scenario == "COMPANION_HOLD_AFTER_ACK" {
                    _ = try await waitForRequest("fixture/turn-ack", log: log)
                    // Allow the already-written acknowledgement to reach the
                    // local actor; interruption is verified by the actual RPC.
                    try await Task.sleep(nanoseconds: 80_000_000)
                }
                let cancelledAt = Date(); pending.cancel()
                do { _ = try await pending.value; expectTrue(false) }
                catch { expectTrue(error is CancellationError) }
                expectTrue(Date().timeIntervalSince(cancelledAt) < 3)
                expectNil(bridge.threadID)
                let interruptions = requests(log).filter { $0["method"] as? String == "turn/interrupt" }
                expectEqual(interruptions.count, scenario == "COMPANION_HOLD_AFTER_ACK" ? 1 : 0)
                _ = try await bridge.connect()
                let recovered = try await bridge.send(text: "recovered", image: nil)
                expectEqual(recovered, "COMPANION_TEXT_OK")
                await bridge.stop()
            } catch {
                await bridge.stop(); fputs("COMPANION CANCELLATION FAILED: \(error)\n", stderr); Foundation.exit(1)
            }
        }
        let directory = folder.appendingPathComponent("ambiguous-start", isDirectory: true)
        let bridge = CodexCompanionConversation(directory: directory, ephemeral: true)
        do {
            _ = try await bridge.connect()
            do {
                _ = try await bridge.send(text: "COMPANION_AMBIGUOUS_START_FAILURE", image: nil)
                expectTrue(false)
            } catch { expectTrue((error as? CompanionFailure)?.requiresReconnect == true) }
            expectNil(bridge.threadID)
            _ = try await bridge.connect()
            let recovered = try await bridge.send(text: "recovered", image: nil)
            expectEqual(recovered, "COMPANION_TEXT_OK")
            await bridge.stop()
        } catch {
            await bridge.stop(); fputs("COMPANION RECOVERY FAILED: \(error)\n", stderr); Foundation.exit(1)
        }
        let stopDirectory = folder.appendingPathComponent("stop-before-ack", isDirectory: true)
        let stopLog = stopDirectory.appendingPathComponent("requests.jsonl")
        setenv("BAVBAV_COMPANION_REQUEST_LOG", stopLog.path, 1)
        let stoppedBridge = CodexCompanionConversation(directory: stopDirectory, ephemeral: true)
        do {
            _ = try await stoppedBridge.connect()
            let oldSend = Task { try await stoppedBridge.send(text: "COMPANION_HOLD_BEFORE_ACK", image: nil) }
            _ = try await waitForRequest("turn/start", log: stopLog)
            await stoppedBridge.stop()
            expectNil(stoppedBridge.threadID)
            let replacement = try await stoppedBridge.connect()
            let next = try await stoppedBridge.send(text: "replacement", image: nil)
            expectEqual(next, "COMPANION_TEXT_OK")
            do { _ = try await oldSend.value; expectTrue(false) }
            catch { expectTrue(error is CancellationError || (error as? CompanionFailure)?.requiresReconnect == true) }
            expectEqual(stoppedBridge.threadID, replacement)
            let subsequent = try await stoppedBridge.send(text: "still connected", image: nil)
            expectEqual(subsequent, "COMPANION_TEXT_OK")
            await stoppedBridge.stop()
        } catch {
            await stoppedBridge.stop(); fputs("COMPANION STOP/RECONNECT FAILED: \(error)\n", stderr); Foundation.exit(1)
        }
        unsetenv("BAVBAV_COMPANION_REQUEST_LOG")
    }

    @MainActor private static func checkIdleDisconnectionAndRecovery(folder: URL) async {
        let directory = folder.appendingPathComponent("idle-close", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = directory.appendingPathComponent("requests.jsonl")
        setenv("BAVBAV_COMPANION_REQUEST_LOG", log.path, 1)
        setenv("BAVBAV_COMPANION_IDLE_EXIT", "1", 1)
        defer {
            unsetenv("BAVBAV_COMPANION_IDLE_EXIT")
            unsetenv("BAVBAV_COMPANION_REQUEST_LOG")
        }
        let bridge = CodexCompanionConversation(directory: directory, ephemeral: true)
        var disconnections: [String] = []
        bridge.setDisconnectionHandler { disconnections.append($0) }
        do {
            _ = try await bridge.connect()
            expectNotNil(bridge.threadID)
            let deadline = Date().addingTimeInterval(3)
            while disconnections.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
            expectEqual(disconnections.count, 1); expectNil(bridge.threadID)
            expectFalse(requests(log).contains { $0["method"] as? String == "turn/start" })
            do { _ = try await bridge.send(text: "Do not send on dead child", image: nil); expectTrue(false) }
            catch { expectTrue((error as? CompanionFailure)?.requiresReconnect == true) }
            expectFalse(requests(log).contains { $0["method"] as? String == "turn/start" })
            unsetenv("BAVBAV_COMPANION_IDLE_EXIT")
            _ = try await bridge.connect()
            let recovered = try await bridge.send(text: "Explicit recovery", image: nil)
            expectEqual(recovered, "COMPANION_TEXT_OK")
            await bridge.stop()
            try await Task.sleep(nanoseconds: 350_000_000)
            expectEqual(disconnections.count, 1)

            // STOP cancels the old stream before its scheduled idle exit. Its
            // delayed termination must not disconnect the replacement child.
            setenv("BAVBAV_COMPANION_IDLE_EXIT", "1", 1)
            _ = try await bridge.connect()
            await bridge.stop()
            unsetenv("BAVBAV_COMPANION_IDLE_EXIT")
            let replacement = try await bridge.connect()
            try await Task.sleep(nanoseconds: 350_000_000)
            expectEqual(disconnections.count, 1); expectEqual(bridge.threadID, replacement)
            let next = try await bridge.send(text: "Still connected after old exit", image: nil)
            expectEqual(next, "COMPANION_TEXT_OK")
            await bridge.stop()
        } catch {
            await bridge.stop(); fputs("COMPANION IDLE RECOVERY FAILED: \(error)\n", stderr); Foundation.exit(1)
        }
    }

    @MainActor private static func waitForCondition(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        guard condition() else { throw CompanionFailure("Fixture condition was not observed") }
    }

    @MainActor private static func checkLiveReplyStreaming(folder: URL) async {
        let directory = folder.appendingPathComponent("live-stream", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = directory.appendingPathComponent("requests.jsonl")
        let gate = directory.appendingPathComponent("allow-ack")
        setenv("BAVBAV_COMPANION_REQUEST_LOG", log.path, 1)
        setenv("BAVBAV_COMPANION_STREAM_ACK_GATE", gate.path, 1)
        defer {
            unsetenv("BAVBAV_COMPANION_REQUEST_LOG")
            unsetenv("BAVBAV_COMPANION_STREAM_ACK_GATE")
        }
        let bridge = CodexCompanionConversation(directory: directory, ephemeral: true)
        var snapshots: [String] = []
        bridge.setReplyHandler { snapshots.append($0) }
        do {
            _ = try await bridge.connect()
            var finished = false
            let pending = Task { let reply = try await bridge.send(text: "COMPANION_STREAM_BEFORE_ACK", image: nil); finished = true; return reply }
            _ = try await waitForRequest("fixture/stream-before-ack", log: log)
            try await Task.sleep(nanoseconds: 30_000_000)
            expectTrue(snapshots.isEmpty); expectFalse(finished)
            expectFalse(requests(log).contains { $0["method"] as? String == "fixture/turn-ack" })
            try Data("release fixture ACK".utf8).write(to: gate, options: .atomic)
            try await waitForCondition { snapshots.first == "PREACK" }
            expectFalse(finished)
            let final = try await pending.value
            expectEqual(final, "PREACK_LIVE"); expectTrue(finished)
            expectEqual(snapshots, ["PREACK", "PREACK_LIVE"])
            await bridge.stop()

            for scenario in ["COMPANION_STREAM_CANCEL", "COMPANION_STREAM_HOLD_BEFORE_ACK"] {
                snapshots = []
                let scenarioLog = directory.appendingPathComponent(scenario + ".jsonl")
                setenv("BAVBAV_COMPANION_REQUEST_LOG", scenarioLog.path, 1)
                _ = try await bridge.connect()
                let cancelled = Task { try await bridge.send(text: scenario, image: nil) }
                _ = try await waitForRequest("fixture/stream-held", log: scenarioLog)
                if scenario == "COMPANION_STREAM_CANCEL" {
                    try await waitForCondition { snapshots == ["CANCELLABLE_PARTIAL"] }
                } else {
                    try await Task.sleep(nanoseconds: 30_000_000)
                    expectTrue(snapshots.isEmpty)
                }
                cancelled.cancel()
                do { _ = try await cancelled.value; expectTrue(false) }
                catch { expectTrue(error is CancellationError) }
                expectNil(bridge.threadID)
                let beforeRecovery = snapshots
                bridge.setReplyHandler(nil)
                _ = try await bridge.connect()
                let recovered = try await bridge.send(text: "stream recovery", image: nil)
                expectEqual(recovered, "COMPANION_TEXT_OK")
                expectEqual(snapshots, beforeRecovery)
                await bridge.stop()
                bridge.setReplyHandler { snapshots.append($0) }
            }
        } catch {
            await bridge.stop(); fputs("COMPANION LIVE STREAM FAILED: \(error)\n", stderr); Foundation.exit(1)
        }
    }
}
