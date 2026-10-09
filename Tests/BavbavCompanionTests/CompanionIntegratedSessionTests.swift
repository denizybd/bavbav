import Foundation
import CoreGraphics
import BavbavCompanion
import CompanionSafety

@MainActor private final class IntegratedEventLog {
    var entries: [String] = []
    func append(_ value: String) { entries.append(value) }
}

@MainActor private final class IntegratedConversation: CompanionConversation {
    let log: IntegratedEventLog
    var connectCount = 0
    var stopCount = 0
    var delayConnect = false
    var connectFailure = false
    var pendingConnect: CheckedContinuation<String, Error>?
    var reply = #"{"reply":"Deneme yanıtı","action":null}"#
    var sends: [(text: String, image: URL?, bytes: Data?)] = []
    var disconnect: ((String) -> Void)?
    init(_ log: IntegratedEventLog) { self.log = log }
    func setDisconnectionHandler(_ handler: ((String) -> Void)?) { disconnect = handler }
    func connect() async throws -> String {
        connectCount += 1; log.append("account.connect")
        if delayConnect { return try await withCheckedThrowingContinuation { pendingConnect = $0 } }
        if connectFailure { throw CompanionFailure("Fixture account unavailable") }
        return "integrated-fixture-thread"
    }
    func send(text: String, image: URL?) async throws -> String {
        log.append("account.send")
        sends.append((text, image, image.flatMap { try? Data(contentsOf: $0) }))
        return reply
    }
    func stop() async { stopCount += 1; log.append("account.stop") }
}

@MainActor private final class IntegratedScreen: CompanionScreenSource {
    let log: IntegratedEventLog
    let display = CompanionDisplay(id: 71_001, width: 1440, height: 900, label: "Fixture display")
    let second = CompanionDisplay(id: 71_002, width: 1280, height: 800, label: "Fixture second display",
                                  bounds: CGRect(x: 1440, y: 0, width: 1280, height: 800))
    let pixels = Data("injected fixture bytes; no native screen".utf8)
    var displaySelectionAccessReady = true
    var permissionCount = 0
    var listingCount = 0
    var windowListingCount = 0
    var windowCaptureCount = 0
    var captures: [CompanionDisplay] = []
    var listed: [CompanionDisplay]?
    var unsupported = false
    var failCapture = false
    var frame: Data?
    var delayPermission = false
    var delayList = false
    var delayCapture = false
    var pendingPermission: CheckedContinuation<Void, Error>?
    var pendingList: CheckedContinuation<[CompanionDisplay], Error>?
    var pendingCapture: CheckedContinuation<Data, Error>?
    init(_ log: IntegratedEventLog) { self.log = log }
    func prepareDisplaySelection() async throws {
        permissionCount += 1; log.append("screen.permission")
        if delayPermission { try await withCheckedThrowingContinuation { pendingPermission = $0 } }
        if !displaySelectionAccessReady { throw CompanionFailure("Fixture Screen Recording denied") }
    }
    func displays() async throws -> [CompanionDisplay] {
        listingCount += 1; log.append("screen.list")
        if delayList { return try await withCheckedThrowingContinuation { pendingList = $0 } }
        if unsupported { throw CompanionFailure("Fixture full-screen capture unsupported") }
        return listed ?? [display]
    }
    func captureDisplay(_ display: CompanionDisplay) async throws -> Data {
        captures.append(display); log.append("screen.capture")
        if delayCapture { return try await withCheckedThrowingContinuation { pendingCapture = $0 } }
        if failCapture { throw CompanionFailure("Fixture capture failed") }
        return frame ?? pixels
    }
    func windows() async throws -> [CompanionWindow] { windowListingCount += 1; return [] }
    func capture(_ window: CompanionWindow) async throws -> Data { windowCaptureCount += 1; return pixels }
}

@MainActor private final class IntegratedSpeech: CompanionSpeechDriving {
    let log: IntegratedEventLog
    var onTranscript: ((String) -> Void)?
    var onDictationFinished: ((String) -> Void)?
    var onDictationFailed: ((String) -> Void)?
    var onSpeakingFinished: (() -> Void)?
    var dictationBusy = false
    var speaking = false
    var status = "Fixture microphone idle"
    var starts: [(apple: Bool, silence: Bool)] = []
    var utterances: [String] = []
    var delayStart = false
    var denied = false
    var pendingStart: CheckedContinuation<Void, Never>?
    private var generation = UUID()
    init(_ log: IntegratedEventLog) { self.log = log }
    func start(allowAppleService: Bool, endOnSilence: Bool) async {
        log.append("voice.permission"); starts.append((allowAppleService, endOnSilence))
        let token = generation
        if delayStart { await withCheckedContinuation { pendingStart = $0 } }
        guard generation == token else { return }
        if denied { status = "Fixture microphone denied"; return }
        dictationBusy = true; status = "Fixture microphone listening"
    }
    func finishListening() { dictationBusy = false }
    func stopListening() { generation = UUID(); dictationBusy = false }
    func speak(_ text: String) { utterances.append(text); speaking = true }
    func stopSpeaking() { speaking = false }
    func stop() { stopListening(); stopSpeaking() }
    func completeDictation(_ text: String) {
        onTranscript?(text); dictationBusy = false; onDictationFinished?(text)
    }
}

@MainActor private final class IntegratedCursor: CompanionDesktopCursorDisplaying {
    var points: [CGPoint] = []
    func show(at point: CGPoint) { points.append(point) }
    func hide() {}
}

@MainActor private final class IntegratedExecutor: CompanionDesktopExecuting {
    let log: IntegratedEventLog
    var controlAccessReady = true
    var permissionCount = 0
    var geometryCount = 0
    var posts = 0
    var target = TargetSnapshot(windowID: 42, pid: 1_234, bundleID: "test.ordinary.editor", displayID: 71_001,
        bounds: Rect(x: 100, y: 100, width: 800, height: 600),
        displayBounds: Rect(x: 0, y: 0, width: 1440, height: 900), scale: 1, isVisible: true, isFrontmost: true)
    init(_ log: IntegratedEventLog) { self.log = log }
    func prepareControlAccess() -> Bool {
        permissionCount += 1; log.append("control.permission"); return controlAccessReady
    }
    func visibleWindows(in screenshotBounds: CGRect) async throws -> [CompanionDesktopWindowSnapshot] {
        geometryCount += 1; log.append("control.geometry")
        return [CompanionDesktopWindowSnapshot(target: target)]
    }
    func resolveTarget(at point: CGPoint, screenshotBounds: CGRect) async throws -> TargetSnapshot { target }
    func prepareTarget(_ target: TargetSnapshot, at point: CGPoint, gate: SafetyGate, epoch: UInt64) async throws -> TargetSnapshot {
        guard gate.status().epoch == epoch else { throw CancellationError() }
        return self.target
    }
    func dispatchClick(at point: CGPoint, target: TargetSnapshot, request: ActionRequest,
                       gate: SafetyGate, ownerID: String) async throws -> ActionOutcome {
        switch gate.preflight(request, currentTarget: target, ownerID: ownerID,
                              screenPermission: true, accessibilityPermission: true) {
        case .deny(let result): throw CompanionFailure(result.errorCode ?? "Fixture gate refused")
        case .allow: break
        }
        for _ in 0..<2 {
            if let rejected = gate.withDispatchAuthorization(request, currentTarget: target, ownerID: ownerID,
                screenPermission: true, accessibilityPermission: true, body: { posts += 1 }) {
                throw CompanionFailure(rejected.errorCode ?? "Fixture gate revoked")
            }
        }
        let result = ActionOutcome(state: "completed", actionID: request.actionID, dispatchedEvents: 2, verified: false)
        gate.recordOutcome(result, for: request)
        return result
    }
}

@MainActor private final class IntegratedFixture {
    let log: IntegratedEventLog
    let directory: URL
    let conversation: IntegratedConversation
    let screen: IntegratedScreen
    let speech: IntegratedSpeech
    let executor: IntegratedExecutor
    let cursor: IntegratedCursor
    let session: CompanionSession
    init() {
        let log = IntegratedEventLog()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bavbav-integrated-fixture-\(UUID())")
        let conversation = IntegratedConversation(log), screen = IntegratedScreen(log)
        let speech = IntegratedSpeech(log), executor = IntegratedExecutor(log), cursor = IntegratedCursor()
        let control = CompanionDesktopControl(executor: executor, cursor: cursor, previewDelayNanoseconds: 0)
        self.log = log; self.directory = directory; self.conversation = conversation; self.screen = screen
        self.speech = speech; self.executor = executor; self.cursor = cursor
        session = CompanionSession(conversation: conversation, screen: screen, directory: directory,
                                   speechDriver: speech, desktopControl: control)
        session.screenShareInterval = 60
    }
    func cleanUp() async {
        await session.shutdown()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Exercises only injected sources and executors. No microphone, screen, native
/// desktop input, account transport, Keychain or OS permission request is used.
@MainActor enum CompanionIntegratedSessionTests {
    private static var assertions = 0
    private static func check(_ value: Bool, line: UInt = #line) {
        assertions += 1
        guard value else { fatalError("INTEGRATED SESSION FIXTURE FAILED at line \(line)") }
    }
    private static func waitUntil(_ condition: () -> Bool, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        check(condition(), line: line)
    }
    private static func settle() async { for _ in 0..<20 { await Task.yield() } }
    private static func inactive(_ fixture: IntegratedFixture, line: UInt = #line) {
        check(!fixture.session.screenSharing, line: line)
        check(!fixture.session.desktopControl.enabled, line: line)
        check(!fixture.session.voiceConversationActive, line: line)
        check(!fixture.speech.dictationBusy && !fixture.speech.speaking, line: line)
        check(fixture.conversation.sends.isEmpty && fixture.executor.posts == 0, line: line)
    }
    private static func ready(_ fixture: IntegratedFixture, line: UInt = #line) {
        check(fixture.session.connected && !fixture.session.integratedStarting, line: line)
        check(fixture.session.screenSharing && fixture.session.displaySelection != nil, line: line)
        check(fixture.session.preview == fixture.screen.pixels && fixture.session.lastCapturedAt != nil, line: line)
        check(fixture.session.desktopControl.enabled && fixture.session.desktopControl.automaticClicks, line: line)
        check(fixture.session.voiceConversationActive && fixture.speech.dictationBusy, line: line)
    }
    static func run() async -> Int {
        assertions = 0
        await initializationAndConnectionCarryNoMediaConsent()
        await primaryStartAndExplicitUserTurns()
        await displaySelectionFailsClosed()
        await failureDoesNotBecomeReady()
        await permissionResumeNeverReprompts()
        await duplicateStartsAreSerialized()
        await stopRejectsEveryLateStage()
        await cancellationClosesEveryLateStage()
        await sharingStopCancelsPendingIntegratedIntent()
        await manualPauseRevokesPendingMicrophone()
        await stopRejectsPermissionResume()
        await oldStartCannotOverwriteReplacement()
        await boundedInputStillRequiresAnExplicitTurn()
        await laterFailuresKeepMediaStatusTruthful()
        await controlOnlyStopKeepsMediaStatusTruthful()
        print("INTEGRATED COMPANION CHECKS PASSED: \(assertions) assertions; injected startup, permission resume, STOP and image delivery only; no native media/input")
        return assertions
    }

    private static func initializationAndConnectionCarryNoMediaConsent() async {
        let f = IntegratedFixture()
        check(f.log.entries.isEmpty)
        inactive(f)
        await f.session.connect()
        check(f.conversation.connectCount == 1)
        check(f.screen.permissionCount == 0 && f.screen.listingCount == 0 && f.screen.captures.isEmpty)
        check(f.executor.permissionCount == 0 && f.speech.starts.isEmpty)
        inactive(f)
        f.session.selectDisplay(f.screen.display)
        check(f.screen.captures.isEmpty && f.executor.permissionCount == 0 && f.speech.starts.isEmpty)
        inactive(f)
        await f.cleanUp()
    }

    private static func primaryStartAndExplicitUserTurns() async {
        let f = IntegratedFixture()
        f.session.draft = "Henüz gönderilmemiş taslak"
        f.session.observeScreenChanges = true
        await f.session.startIntegratedSession()
        ready(f)
        check(f.conversation.connectCount == 1 && f.screen.permissionCount == 1 && f.screen.listingCount == 1)
        check(f.screen.windowListingCount == 0 && f.screen.windowCaptureCount == 0)
        check(f.executor.permissionCount == 1 && f.speech.starts.count == 1)
        check(!f.speech.starts[0].apple && f.speech.starts[0].silence)
        check(f.session.draft == "Henüz gönderilmemiş taslak" && f.conversation.sends.isEmpty)
        check(!f.session.observeScreenChanges && f.session.lastSharedAt == nil && f.executor.posts == 0)
        let order = ["account.connect", "screen.permission", "screen.list", "screen.capture", "control.permission", "voice.permission"]
        let indices = order.compactMap { f.log.entries.firstIndex(of: $0) }
        check(indices.count == order.count && zip(indices, indices.dropFirst()).allSatisfy { $0.0 < $0.1 })
        check(!FileManager.default.fileExists(atPath: f.directory.path))
        await f.session.shareScreenNow()
        check(f.conversation.sends.isEmpty && f.executor.posts == 0)
        check(f.session.lastSharedAt == nil)

        let capturesBefore = f.screen.captures.count
        f.speech.completeDictation("Ekranda ne görüyorsun?")
        await waitUntil { f.conversation.sends.count == 1 && !f.speech.utterances.isEmpty }
        await settle()
        let spoken = f.conversation.sends[0]
        check(spoken.text.hasPrefix("Ekranda ne görüyorsun?"))
        check(spoken.image != nil && spoken.bytes == f.screen.pixels)
        check(f.screen.captures.count == capturesBefore + 1 && f.executor.geometryCount == 2)
        check(f.session.lastSharedAt != nil && f.session.draft == "Henüz gönderilmemiş taslak")
        check(!FileManager.default.fileExists(atPath: spoken.image!.path))
        check(f.executor.posts == 0 && f.cursor.points.isEmpty)

        f.session.pauseVoiceConversation(); f.session.speakReplies = false
        f.session.draft = "Bu yazılı turu incele"
        await f.session.send()
        check(f.conversation.sends.count == 2)
        let typed = f.conversation.sends[1]
        check(typed.text.hasPrefix("Bu yazılı turu incele") && typed.image != nil && typed.bytes == f.screen.pixels)
        check(!FileManager.default.fileExists(atPath: typed.image!.path))
        check(f.executor.posts == 0)
        await f.cleanUp()
    }

    private static func displaySelectionFailsClosed() async {
        for scenario in 0..<5 {
            let f = IntegratedFixture()
            switch scenario {
            case 0: f.screen.listed = []
            case 1: f.screen.listed = [f.screen.display, f.screen.second]
            case 2:
                f.session.selectDisplay(f.screen.display)
                f.screen.listed = [f.screen.second]
            case 3:
                f.session.selectDisplay(f.screen.display)
                f.screen.listed = [CompanionDisplay(id: f.screen.display.id, width: 1000, height: 700, label: "Reconfigured")]
            default: f.screen.listed = [f.screen.display]
            }
            await f.session.startIntegratedSession(preferredDisplayID: scenario == 4 ? 99_999 : nil)
            check(f.screen.captures.isEmpty && f.executor.permissionCount == 0 && f.speech.starts.isEmpty)
            inactive(f)
            await f.cleanUp()
        }
        let f = IntegratedFixture()
        f.screen.listed = [f.screen.display, f.screen.second]
        await f.session.startIntegratedSession(preferredDisplayID: f.screen.second.id)
        ready(f)
        check(f.session.displaySelection == f.screen.second && f.screen.captures.allSatisfy { $0 == f.screen.second })
        check(f.conversation.sends.isEmpty)
        await f.cleanUp()
    }

    private static func failureDoesNotBecomeReady() async {
        for scenario in 0..<5 {
            let f = IntegratedFixture()
            switch scenario {
            case 0: f.conversation.connectFailure = true
            case 1: f.screen.unsupported = true
            case 2: f.screen.failCapture = true
            case 3: f.screen.frame = Data()
            default: f.screen.frame = Data(repeating: 0, count: 6 * 1024 * 1024 + 1)
            }
            await f.session.startIntegratedSession()
            check(!f.session.integratedStarting)
            inactive(f)
            check(f.executor.permissionCount == 0 && f.speech.starts.isEmpty)
            if scenario == 0 { check(f.screen.permissionCount == 0 && f.screen.listingCount == 0 && f.screen.captures.isEmpty) }
            await f.cleanUp()
        }
        let f = IntegratedFixture(); f.speech.denied = true
        await f.session.startIntegratedSession()
        check(!f.session.integratedStarting && !f.session.voiceConversationActive && !f.speech.dictationBusy)
        check(!f.session.integratedStatus.localizedCaseInsensitiveContains("hazır"))
        check(f.conversation.sends.isEmpty && f.executor.posts == 0)
        await f.cleanUp()
    }

    private static func permissionResumeNeverReprompts() async {
        let screen = IntegratedFixture(); screen.screen.displaySelectionAccessReady = false
        await screen.session.startIntegratedSession()
        check(screen.session.integratedStarting && screen.screen.permissionCount == 1)
        check(screen.screen.listingCount == 0 && screen.screen.captures.isEmpty)
        inactive(screen)
        for _ in 0..<3 { await screen.session.resumeIntegratedStartAfterPermissions() }
        check(screen.screen.permissionCount == 1 && screen.screen.listingCount == 0)
        screen.screen.displaySelectionAccessReady = true
        await screen.session.resumeIntegratedStartAfterPermissions()
        ready(screen)
        check(screen.screen.permissionCount == 1 && screen.executor.permissionCount == 1)
        check(screen.conversation.sends.isEmpty)
        await screen.cleanUp()

        let control = IntegratedFixture(); control.executor.controlAccessReady = false
        await control.session.startIntegratedSession()
        check(control.session.integratedStarting && control.executor.permissionCount == 1)
        check(control.session.screenSharing && control.session.preview == control.screen.pixels)
        check(!control.session.desktopControl.enabled && control.speech.starts.isEmpty)
        check(control.conversation.sends.isEmpty && control.executor.posts == 0)
        for _ in 0..<3 { await control.session.resumeIntegratedStartAfterPermissions() }
        check(control.executor.permissionCount == 1 && control.speech.starts.isEmpty)
        let capturesBefore = control.screen.captures.count
        control.executor.controlAccessReady = true
        await control.session.resumeIntegratedStartAfterPermissions()
        ready(control)
        check(control.executor.permissionCount == 1 && control.screen.permissionCount == 1)
        check(control.screen.captures.count > capturesBefore)
        check(control.conversation.sends.isEmpty)
        await control.cleanUp()
    }

    private enum Stage: CaseIterable { case connect, permission, list, capture, voice }
    private static func delay(_ stage: Stage, fixture f: IntegratedFixture) {
        switch stage {
        case .connect: f.conversation.delayConnect = true
        case .permission: f.screen.delayPermission = true
        case .list: f.screen.delayList = true
        case .capture: f.screen.delayCapture = true
        case .voice: f.speech.delayStart = true
        }
    }
    private static func pending(_ stage: Stage, fixture f: IntegratedFixture) -> Bool {
        switch stage {
        case .connect: return f.conversation.pendingConnect != nil
        case .permission: return f.screen.pendingPermission != nil
        case .list: return f.screen.pendingList != nil
        case .capture: return f.screen.pendingCapture != nil
        case .voice: return f.speech.pendingStart != nil
        }
    }
    private static func release(_ stage: Stage, fixture f: IntegratedFixture, fails: Bool = false) {
        let error = CompanionFailure("Fixture delayed failure")
        switch stage {
        case .connect:
            let continuation = f.conversation.pendingConnect; f.conversation.pendingConnect = nil
            if fails { continuation?.resume(throwing: error) } else { continuation?.resume(returning: "late-fixture-thread") }
        case .permission:
            let continuation = f.screen.pendingPermission; f.screen.pendingPermission = nil
            if fails { continuation?.resume(throwing: error) } else { continuation?.resume() }
        case .list:
            let continuation = f.screen.pendingList; f.screen.pendingList = nil
            if fails { continuation?.resume(throwing: error) } else { continuation?.resume(returning: [f.screen.display]) }
        case .capture:
            let continuation = f.screen.pendingCapture; f.screen.pendingCapture = nil
            if fails { continuation?.resume(throwing: error) } else { continuation?.resume(returning: f.screen.pixels) }
        case .voice:
            let continuation = f.speech.pendingStart; f.speech.pendingStart = nil; continuation?.resume()
        }
    }

    private static func duplicateStartsAreSerialized() async {
        for stage in Stage.allCases {
            let f = IntegratedFixture(); delay(stage, fixture: f)
            let first = Task { await f.session.startIntegratedSession() }
            await waitUntil { pending(stage, fixture: f) }
            check(f.session.integratedStarting)
            let before = f.log.entries
            let duplicate = (0..<8).map { _ in Task { await f.session.startIntegratedSession() } }
            for task in duplicate { await task.value }
            check(f.log.entries == before)
            check(f.conversation.sends.isEmpty && f.executor.posts == 0)
            release(stage, fixture: f); await first.value
            ready(f)
            let prompts = (f.screen.permissionCount, f.executor.permissionCount, f.speech.starts.count)
            await f.session.startIntegratedSession()
            check(f.conversation.connectCount == 1 && f.screen.permissionCount == prompts.0)
            check(f.executor.permissionCount == prompts.1 && f.speech.starts.count == prompts.2)
            check(f.conversation.sends.isEmpty)
            await f.cleanUp()
        }
    }

    private static func stopRejectsEveryLateStage() async {
        for stage in Stage.allCases {
            for fails in [false, true] {
                if stage == .voice && fails { continue }
                let f = IntegratedFixture(); delay(stage, fixture: f)
                let start = Task { await f.session.startIntegratedSession() }
                await waitUntil { pending(stage, fixture: f) }
                let staleTranscript = f.speech.onTranscript
                let staleFinished = f.speech.onDictationFinished
                let capturesBefore = f.screen.captures.count
                let controlBefore = f.executor.permissionCount
                let voiceBefore = f.speech.starts.count
                f.session.stop()
                inactive(f)
                check(!f.session.integratedStarting && !f.session.connected && f.session.preview == nil)
                check(f.session.displaySelection == nil && f.session.threadID == nil)
                let stoppedStatus = f.session.integratedStatus
                release(stage, fixture: f, fails: fails); await start.value; await settle()
                staleTranscript?("Geç kalan konuşma"); staleFinished?("Geç kalan konuşma")
                await settle()
                inactive(f)
                check(f.screen.captures.count == capturesBefore && f.executor.permissionCount == controlBefore)
                check(f.speech.starts.count == voiceBefore && f.session.integratedStatus == stoppedStatus)
                check(!f.session.integratedStarting && f.session.preview == nil && f.session.threadID == nil)
                await f.cleanUp()
                check(f.conversation.stopCount == 1)
            }
        }
    }

    private static func stopRejectsPermissionResume() async {
        for isControl in [false, true] {
            let f = IntegratedFixture()
            if isControl { f.executor.controlAccessReady = false } else { f.screen.displaySelectionAccessReady = false }
            await f.session.startIntegratedSession()
            check(f.session.integratedStarting)
            f.session.stop(); await f.session.waitForPendingStop()
            let before = f.log.entries
            f.executor.controlAccessReady = true; f.screen.displaySelectionAccessReady = true
            await f.session.resumeIntegratedStartAfterPermissions(); await settle()
            check(f.log.entries == before && !f.session.integratedStarting)
            inactive(f)
            await f.cleanUp()
        }
    }

    private static func cancellationClosesEveryLateStage() async {
        for stage in Stage.allCases {
            let f = IntegratedFixture(); delay(stage, fixture: f)
            let start = Task { await f.session.startIntegratedSession() }
            await waitUntil { pending(stage, fixture: f) }
            let capturesBefore = f.screen.captures.count
            let controlBefore = f.executor.permissionCount
            let voiceBefore = f.speech.starts.count
            start.cancel()
            release(stage, fixture: f); await start.value; await settle()
            inactive(f)
            check(!f.session.integratedStarting && f.session.preview == nil)
            check(f.screen.captures.count == capturesBefore && f.executor.permissionCount == controlBefore)
            check(f.speech.starts.count == voiceBefore)
            await f.cleanUp()
        }
    }

    private static func sharingStopCancelsPendingIntegratedIntent() async {
        for stage in [Stage.permission, .list, .capture, .voice] {
            let f = IntegratedFixture(); delay(stage, fixture: f)
            let start = Task { await f.session.startIntegratedSession() }
            await waitUntil { pending(stage, fixture: f) }
            let capturesBefore = f.screen.captures.count
            let controlBefore = f.executor.permissionCount
            let voiceBefore = f.speech.starts.count
            let staleFinished = f.speech.onDictationFinished
            f.session.stopScreenSharing()
            check(!f.session.integratedStarting && !f.session.requestingScreenPermission)
            check(f.session.connected && !f.session.stopping)
            inactive(f)
            let stoppedStatus = f.session.integratedStatus
            release(stage, fixture: f); await start.value
            staleFinished?("Geç kalan konuşma")
            await f.session.resumeIntegratedStartAfterPermissions(); await settle()
            inactive(f)
            check(f.screen.captures.count == capturesBefore && f.executor.permissionCount == controlBefore)
            check(f.speech.starts.count == voiceBefore && f.session.integratedStatus == stoppedStatus)
            check(f.conversation.stopCount == 0 && !f.session.requestingScreenPermission)
            await f.cleanUp()
        }
        for isControl in [false, true] {
            let f = IntegratedFixture()
            if isControl { f.executor.controlAccessReady = false } else { f.screen.displaySelectionAccessReady = false }
            await f.session.startIntegratedSession()
            check(f.session.integratedStarting)
            f.session.stopScreenSharing()
            let before = f.log.entries
            f.executor.controlAccessReady = true; f.screen.displaySelectionAccessReady = true
            let focusEvents = (0..<8).map { _ in Task { await f.session.resumeIntegratedStartAfterPermissions() } }
            for task in focusEvents { await task.value }
            check(f.log.entries == before && !f.session.integratedStarting)
            inactive(f)
            check(f.session.connected && f.conversation.stopCount == 0)
            await f.cleanUp()
        }

        // After startup has completed, stopping only sharing preserves the
        // already-authorized voice conversation without sharing another frame.
        let active = IntegratedFixture()
        await active.session.startIntegratedSession()
        active.session.stopScreenSharing()
        check(active.session.connected && active.session.voiceConversationActive && active.speech.dictationBusy)
        check(!active.session.screenSharing && !active.session.desktopControl.enabled && active.session.preview == nil)
        active.speech.completeDictation("Yalnızca sesle devam et")
        await waitUntil { active.conversation.sends.count == 1 && !active.speech.utterances.isEmpty }
        check(active.conversation.sends[0].image == nil && active.executor.posts == 0)
        await active.cleanUp()
    }

    private static func manualPauseRevokesPendingMicrophone() async {
        let f = IntegratedFixture(); f.speech.delayStart = true
        let start = Task { await f.session.startIntegratedSession() }
        await waitUntil { f.speech.pendingStart != nil }
        let staleTranscript = f.speech.onTranscript
        let staleFinished = f.speech.onDictationFinished
        f.session.pauseVoiceConversation()
        check(!f.session.integratedStarting && !f.session.voiceConversationActive && !f.speech.dictationBusy)
        check(f.session.screenSharing && f.session.desktopControl.enabled)
        let pausedStatus = f.session.integratedStatus
        release(.voice, fixture: f); await start.value
        staleTranscript?("Geç kalan konuşma"); staleFinished?("Geç kalan konuşma")
        await f.session.resumeIntegratedStartAfterPermissions(); await settle()
        check(!f.session.integratedStarting && !f.session.voiceConversationActive && !f.speech.dictationBusy)
        check(f.session.integratedStatus == pausedStatus && f.speech.starts.count == 1)
        check(f.session.screenSharing && f.session.desktopControl.enabled && f.session.preview == f.screen.pixels)
        check(f.conversation.sends.isEmpty && f.executor.posts == 0 && f.conversation.stopCount == 0)
        await f.cleanUp()
    }

    private static func oldStartCannotOverwriteReplacement() async {
        let f = IntegratedFixture(); f.screen.delayCapture = true
        let old = Task { await f.session.startIntegratedSession() }
        await waitUntil { f.screen.pendingCapture != nil }
        let staleCapture = f.screen.pendingCapture; f.screen.pendingCapture = nil
        f.session.stop(); await f.session.waitForPendingStop()
        f.screen.delayCapture = false
        await f.session.startIntegratedSession()
        ready(f)
        let newStatus = f.session.integratedStatus
        let newThread = f.session.threadID
        let newFrameTime = f.session.lastCapturedAt
        staleCapture?.resume(returning: Data("old revoked capture".utf8))
        await old.value; await settle()
        ready(f)
        check(f.session.integratedStatus == newStatus && f.session.threadID == newThread)
        check(f.session.lastCapturedAt == newFrameTime && f.conversation.connectCount == 2)
        check(f.conversation.sends.isEmpty && f.executor.posts == 0)
        await f.cleanUp()
    }

    private static func boundedInputStillRequiresAnExplicitTurn() async {
        let f = IntegratedFixture()
        await f.session.startIntegratedSession()
        ready(f)
        check(f.executor.posts == 0 && f.cursor.points.isEmpty)
        f.session.pauseVoiceConversation(); f.session.speakReplies = false
        f.conversation.reply = #"{"reply":"Play düğmesi burada","action":{"action":"click","x":0.3,"y":0.25,"explanation":"Play düğmesine tıkla"}}"#
        f.session.draft = "Play düğmesine tıkla"
        await f.session.send()
        check(f.conversation.sends.count == 1 && f.executor.posts == 2 && f.cursor.points.count == 1)
        check(f.session.desktopControl.pending == nil && !f.session.desktopControl.executing)
        f.conversation.reply = #"{"reply":"İşlem isteniyor","action":{"action":"click","x":0.3,"y":0.25,"explanation":"Delete document"}}"#
        f.session.draft = "Bu sonraki turu incele"
        await f.session.send()
        check(f.conversation.sends.count == 2 && f.executor.posts == 2 && f.cursor.points.count == 1)
        check(f.session.desktopControl.pending == nil)
        f.session.stop()
        check(!f.session.desktopControl.enabled && f.session.desktopControl.pending == nil)
        await f.cleanUp()
    }

    private static func laterFailuresKeepMediaStatusTruthful() async {
        let speech = IntegratedFixture()
        await speech.session.startIntegratedSession()
        ready(speech)
        speech.speech.onDictationFailed?("Fixture later recognition failed")
        check(!speech.session.voiceConversationActive && !speech.speech.dictationBusy && !speech.speech.speaking)
        check(speech.session.screenSharing && speech.session.desktopControl.enabled)
        check(speech.session.integratedStatus.contains("Ses kapalı"))
        check(!speech.session.integratedStatus.contains("Ses + ekran + imleç açık"))
        check(speech.session.voiceStatus == "Fixture later recognition failed")
        check(speech.conversation.sends.isEmpty && speech.executor.posts == 0)
        await speech.cleanUp()

        let envelope = IntegratedFixture()
        await envelope.session.startIntegratedSession()
        ready(envelope)
        envelope.conversation.reply = "Fixture malformed control envelope"
        envelope.speech.completeDictation("Bu kullanıcı turunu yanıtla")
        await waitUntil { !envelope.session.desktopControl.enabled && envelope.speech.speaking }
        check(envelope.session.screenSharing && envelope.session.voiceConversationActive)
        check(!envelope.session.integratedStatus.contains("Ses + ekran + imleç açık"))
        check(envelope.session.integratedStatus.contains("imleç kapalı"))
        check(envelope.conversation.sends.count == 1 && envelope.executor.posts == 0)
        await envelope.cleanUp()
    }

    private static func controlOnlyStopKeepsMediaStatusTruthful() async {
        let pending = IntegratedFixture(); pending.speech.delayStart = true
        let start = Task { await pending.session.startIntegratedSession() }
        await waitUntil { pending.speech.pendingStart != nil }
        pending.session.stopDesktopControl()
        let stoppedStatus = pending.session.integratedStatus
        check(!pending.session.integratedStarting && !pending.session.voiceConversationActive)
        check(!pending.session.desktopControl.enabled && pending.session.screenSharing && pending.session.connected)
        release(.voice, fixture: pending); await start.value; await settle()
        check(!pending.speech.dictationBusy && !pending.speech.speaking && !pending.session.voiceConversationActive)
        check(!pending.session.desktopControl.enabled && pending.session.integratedStatus == stoppedStatus)
        check(pending.conversation.sends.isEmpty && pending.executor.posts == 0 && pending.conversation.stopCount == 0)
        await pending.cleanUp()

        let active = IntegratedFixture()
        await active.session.startIntegratedSession()
        ready(active)
        active.session.stopDesktopControl()
        check(active.session.voiceConversationActive && active.speech.dictationBusy && active.session.screenSharing)
        check(!active.session.desktopControl.enabled && active.session.connected)
        check(active.session.integratedStatus.contains("imleç kapalı"))
        check(!active.session.integratedStatus.contains("Ses + ekran + imleç açık"))
        check(active.conversation.sends.isEmpty && active.executor.posts == 0 && active.conversation.stopCount == 0)
        await active.cleanUp()
    }
}
