import AppKit
import BavbavCompanion
import CompanionSafety

/// Tests the controller's real permission-refresh action with injected sources
/// and logical presentation. Windows stay hidden; no native permissions,
/// screen capture, microphone, account requests or desktop input are exercised.
@MainActor enum CompanionPermissionRetryCheck {
    private struct Failure: Error { let message: String }

    private final class Conversation: CompanionConversation {
        var connects = 0
        var sends = 0
        func connect() async throws -> String { connects += 1; return "permission-retry-fixture" }
        func send(text: String, image: URL?) async throws -> String {
            sends += 1
            throw CompanionFailure("Unexpected fixture model request")
        }
        func stop() async {}
    }

    private final class Screen: CompanionScreenSource {
        var displaySelectionAccessReady = false
        var permissionRequests = 0
        var listings = 0
        var captures = 0
        var returnedCaptures = 0
        var delayCapture = false
        var pendingCapture: CheckedContinuation<Data, Error>?
        let display = CompanionDisplay(id: 92_001, width: 1440, height: 900, label: "Injected retry display")
        func prepareDisplaySelection() async throws {
            permissionRequests += 1
            if !displaySelectionAccessReady { throw CompanionFailure("Injected Screen Recording denial") }
        }
        func displays() async throws -> [CompanionDisplay] { listings += 1; return [display] }
        func captureDisplay(_ display: CompanionDisplay) async throws -> Data {
            captures += 1
            let result: Data
            if delayCapture { result = try await withCheckedThrowingContinuation { pendingCapture = $0 } }
            else { result = Data("Injected frame, not native screen pixels".utf8) }
            returnedCaptures += 1
            return result
        }
        func windows() async throws -> [CompanionWindow] { throw CompanionFailure("Unexpected window enumeration") }
        func capture(_ window: CompanionWindow) async throws -> Data { throw CompanionFailure("Unexpected window capture") }
    }

    private final class Speech: CompanionSpeechDriving {
        var onTranscript: ((String) -> Void)?
        var onDictationFinished: ((String) -> Void)?
        var onDictationFailed: ((String) -> Void)?
        var onSpeakingFinished: (() -> Void)?
        var dictationBusy = false
        var speaking = false
        var status = "Injected speech idle"
        var starts = 0
        func start(allowAppleService: Bool, endOnSilence: Bool) async { starts += 1; dictationBusy = true }
        func finishListening() { dictationBusy = false }
        func stopListening() { dictationBusy = false }
        func speak(_ text: String) { speaking = true }
        func stopSpeaking() { speaking = false }
        func stop() { stopListening(); stopSpeaking() }
    }

    private final class Executor: CompanionDesktopExecuting {
        var controlAccessReady = true
        var permissionRequests = 0
        var inputDispatches = 0
        func prepareControlAccess() -> Bool { permissionRequests += 1; return controlAccessReady }
        func visibleWindows(in screenshotBounds: CGRect) async throws -> [CompanionDesktopWindowSnapshot] { [] }
        func resolveTarget(at point: CGPoint, screenshotBounds: CGRect) async throws -> TargetSnapshot {
            throw CompanionFailure("Unexpected fixture target resolution")
        }
        func prepareTarget(_ target: TargetSnapshot, at point: CGPoint, gate: SafetyGate, epoch: UInt64) async throws -> TargetSnapshot {
            throw CompanionFailure("Unexpected fixture activation")
        }
        func dispatchClick(at point: CGPoint, target: TargetSnapshot, request: ActionRequest,
                           gate: SafetyGate, ownerID: String) async throws -> ActionOutcome {
            inputDispatches += 1
            throw CompanionFailure("Unexpected fixture input dispatch")
        }
    }

    private final class Cursor: CompanionDesktopCursorDisplaying {
        func show(at point: CGPoint) {}
        func hide() {}
    }

    @MainActor private final class Fixture {
        let conversation = Conversation()
        let screen = Screen()
        let speech = Speech()
        let executor = Executor()
        let session: CompanionSession
        let controller: CompanionWindowController
        var presented = true
        init(preferences: AppPreferences) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bavbav-permission-retry-\(UUID())")
            session = CompanionSession(conversation: conversation, screen: screen, directory: directory,
                speechDriver: speech, desktopControl: CompanionDesktopControl(executor: executor, cursor: Cursor()))
            session.screenShareInterval = 60
            // Presentation is injected only for hidden action-wiring tests.
            // Production controller defaults to its actual NSWindow.isVisible.
            var fixturePresentation: (() -> Bool)?
            controller = CompanionWindowController(webSession: ChatGPTWebSession(), preferences: preferences,
                session: session, permissionResumePresentation: { fixturePresentation?() ?? false })
            fixturePresentation = { [weak self] in self?.presented == true }
        }
        func close() async {
            await controller.shutdown()
            controller.window.close()
        }
    }

    static func run(preferences: AppPreferences) async -> Bool {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            checks += 1
            guard condition() else { throw Failure(message: message) }
        }
        func settle() async { for _ in 0..<20 { await Task.yield() } }
        func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(3)
            while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
            try check(condition(), "injected retry continuation did not reach expected stage")
        }
        var fixtures: [Fixture] = []
        do {
            let screen = Fixture(preferences: preferences); fixtures.append(screen)
            screen.controller.refreshPermissionsAndResumePendingStart()
            await screen.controller.waitForPendingPermissionRefresh()
            try check(screen.conversation.connects == 0 && screen.screen.permissionRequests == 0
                      && screen.screen.captures == 0 && screen.speech.starts == 0,
                      "permission refresh before explicit Start must not start any scope")
            await screen.session.startIntegratedSession()
            try check(screen.session.integratedStarting && screen.screen.permissionRequests == 1
                      && screen.screen.captures == 0, "denied screen permission retains exactly one explicit pending Start")
            screen.controller.refreshPermissionsAndResumePendingStart()
            await screen.controller.waitForPendingPermissionRefresh()
            try check(screen.session.integratedStarting && screen.screen.permissionRequests == 1
                      && screen.screen.captures == 0, "not-ready refresh neither repeats OS request nor captures")
            screen.screen.displaySelectionAccessReady = true
            // The same action used by the visible retry, identity refresh and
            // repeated show()/Command 6; no key/focus notification is sent.
            screen.controller.refreshPermissionsAndResumePendingStart()
            screen.controller.refreshPermissionsAndResumePendingStart()
            await screen.controller.waitForPendingPermissionRefresh()
            try check(!screen.session.integratedStarting && screen.session.screenSharing
                      && screen.session.desktopControl.enabled && screen.session.voiceConversationActive,
                      "same-window explicit refresh resumes all prepared fixture scopes without a focus event")
            try check(screen.screen.permissionRequests == 1 && screen.screen.captures == 1
                      && screen.executor.permissionRequests == 1 && screen.speech.starts == 1,
                      "duplicate refreshes remain serialized and do not reprompt or double-start")
            try check(!screen.controller.window.isVisible && !screen.controller.window.isKeyWindow
                      && screen.conversation.sends == 0 && screen.executor.inputDispatches == 0,
                      "injected wiring test never presents a window, sends inference or posts native input")

            let control = Fixture(preferences: preferences); fixtures.append(control)
            control.screen.displaySelectionAccessReady = true; control.executor.controlAccessReady = false
            await control.session.startIntegratedSession()
            try check(control.session.integratedStarting && control.executor.permissionRequests == 1
                      && control.speech.starts == 0, "pending control permission has not started voice")
            control.executor.controlAccessReady = true
            control.controller.refreshPermissionsAndResumePendingStart()
            await control.controller.waitForPendingPermissionRefresh()
            try check(!control.session.integratedStarting && control.session.desktopControl.enabled
                      && control.speech.starts == 1 && control.executor.permissionRequests == 1,
                      "control permission refresh resumes read-only without another native control request")

            let stop = Fixture(preferences: preferences); fixtures.append(stop)
            await stop.session.startIntegratedSession()
            stop.screen.displaySelectionAccessReady = true
            stop.controller.refreshPermissionsAndResumePendingStart()
            stop.controller.stop()
            await stop.session.waitForPendingStop(); await settle()
            stop.controller.refreshPermissionsAndResumePendingStart()
            await stop.controller.waitForPendingPermissionRefresh()
            try check(!stop.session.integratedStarting && !stop.session.screenSharing
                      && !stop.session.desktopControl.enabled && !stop.session.voiceConversationActive
                      && stop.screen.captures == 0 && stop.speech.starts == 0,
                      "STOP cancels queued refresh and later refresh cannot recover revoked intent")

            let hidden = Fixture(preferences: preferences); fixtures.append(hidden)
            await hidden.session.startIntegratedSession()
            hidden.screen.displaySelectionAccessReady = true
            hidden.controller.refreshPermissionsAndResumePendingStart()
            hidden.presented = false
            await hidden.controller.waitForPendingPermissionRefresh()
            try check(hidden.screen.captures == 0 && hidden.speech.starts == 0,
                      "hiding after enqueue prevents continuation")
            hidden.presented = true
            hidden.controller.refreshPermissionsAndResumePendingStart()
            await hidden.controller.waitForPendingPermissionRefresh()
            try check(hidden.speech.starts == 1 && !hidden.session.integratedStarting,
                      "cancelled hidden refresh clears task so an actual later visible retry can proceed")

            let late = Fixture(preferences: preferences); fixtures.append(late)
            await late.session.startIntegratedSession()
            late.screen.displaySelectionAccessReady = true; late.screen.delayCapture = true
            late.controller.refreshPermissionsAndResumePendingStart()
            try await waitUntil { late.screen.pendingCapture != nil }
            late.controller.stop()
            let pending = late.screen.pendingCapture; late.screen.pendingCapture = nil
            pending?.resume(returning: Data("Late injected frame".utf8))
            try await waitUntil { late.screen.returnedCaptures == 1 }
            await late.session.waitForPendingStop(); await settle()
            try check(!late.session.integratedStarting && late.session.preview == nil
                      && !late.session.screenSharing && !late.session.desktopControl.enabled
                      && late.speech.starts == 0, "late refresh capture after STOP cannot publish or start media")
            for fixture in fixtures { await fixture.close() }
            print("COMPANION PERMISSION RETRY CHECK PASSED: \(checks) checks; real controller refresh wiring, readiness without focus, duplicate suppression, STOP and hidden/late cancellation; injected presentation/media only, no native permissions/account/audio/capture/input")
            return true
        } catch {
            for fixture in fixtures {
                if let pending = fixture.screen.pendingCapture {
                    fixture.screen.pendingCapture = nil; pending.resume(throwing: CancellationError())
                }
                await fixture.close()
            }
            fputs("COMPANION PERMISSION RETRY CHECK FAILED: \((error as? Failure)?.message ?? error.localizedDescription)\n", stderr)
            return false
        }
    }
}
