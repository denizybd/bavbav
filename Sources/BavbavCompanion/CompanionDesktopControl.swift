import Combine
import CoreGraphics
import Foundation
import CompanionSafety

public enum CompanionDesktopScope: Equatable, Sendable {
    case allVisibleApps
    case selectedWindow(CompanionWindow)
}

/// Quartz global coordinates (top-left origin), not screenshot pixels.
public struct CompanionDesktopWindowSnapshot: Equatable, Sendable {
    public let target: TargetSnapshot
    public let layer: Int
    public init(target: TargetSnapshot, layer: Int = 0) { self.target = target; self.layer = layer }
}

public struct CompanionDesktopClick: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let explanation: String

    /// Intentionally accepts only an inner action object, never arbitrary prose,
    /// Markdown, arrays, keyboard actions or fields that could extend authority.
    public static func parse(_ response: String) throws -> Self {
        guard let data = response.data(using: .utf8), data.count <= 2_048,
              let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(row.keys) == ["action", "x", "y", "explanation"],
              row["action"] as? String == "click",
              let x = row["x"] as? NSNumber, let y = row["y"] as? NSNumber,
              CFGetTypeID(x) != CFBooleanGetTypeID(), CFGetTypeID(y) != CFBooleanGetTypeID(),
              x.doubleValue.isFinite, y.doubleValue.isFinite,
              (0..<1).contains(x.doubleValue), (0..<1).contains(y.doubleValue),
              let explanation = row["explanation"] as? String else {
            throw CompanionFailure("Yalnızca tek, sınırlandırılmış click JSON önerisi kabul edilir.")
        }
        let reason = explanation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty, reason.count <= 180, reason.utf8.count <= 540,
              !reason.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !CompanionDesktopRisk.isRisky(reason) else {
            throw CompanionFailure("Bu tıklama amacı güvenli ilk sürümün dışında; işlem yapılmadı.")
        }
        return Self(x: x.doubleValue, y: y.doubleValue, explanation: reason)
    }
}

/// A conservative deny list, not a claim that arbitrary desktop actions are safe.
/// Consequential UI, credentials, permissions and executable entry are excluded.
public enum CompanionDesktopRisk {
    public static func isRisky(_ value: String) -> Bool {
        let text = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let words = text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let exact: Set<String> = ["delete", "remove", "erase", "trash", "empty", "buy", "purchase", "pay", "payment",
            "checkout", "transfer", "send", "submit", "allow", "deny", "authorize", "permission", "privacy", "password",
            "passcode", "login", "signin", "security", "unlock", "install", "uninstall", "download", "execute", "terminal",
            "sudo", "shell", "quit", "sil", "cop", "odeme", "havale", "izin", "yetki", "parola", "sifre", "giris", "kapat"]
        let stems = ["delet", "remov", "eras", "trash", "purchas", "pay", "transfer", "submit", "authoriz", "permiss",
            "credential", "install", "uninstall", "download", "execut", "secur", "password", "sil", "satinal", "gonder",
            "onay", "yetkil", "kurul", "yukle", "calistir", "kaldir"]
        return words.contains { exact.contains($0) || stems.contains(where: $0.hasPrefix) }
            || text.contains("sign in") || text.contains("log in") || text.contains("satin al")
            || text.contains("system settings") || text.contains("sistem ayar")
    }

    public static func isBlockedBundle(_ bundleID: String) -> Bool {
        let value = bundleID.lowercased()
        return value == "dev.deniz.bavbav" || value.contains("securityagent") || value.contains("loginwindow")
            || value.contains("systempreferences") || value.contains("keychainaccess") || value.contains("terminal")
            || value.contains("iterm") || value.contains("password")
    }
}

public struct CompanionDesktopProposal: Identifiable, Sendable {
    public let id: UUID
    public let explanation: String
    public let point: CGPoint
    public let target: TargetSnapshot
    public let capturedAt: Date
    public let expiresAt: Date
    fileprivate let frameID: String
    fileprivate let generation: UUID
}

/// Opaque, one-use geometry observed immediately before an actual screenshot.
/// It carries no pixels or input authority and cannot be manufactured by callers.
public struct CompanionDesktopCaptureSnapshot: Sendable {
    fileprivate let id: UUID
    fileprivate let generation: UUID
    fileprivate let bounds: CGRect
    fileprivate let preparedAt: Date
    fileprivate let windows: [CompanionDesktopWindowSnapshot]
}

@MainActor public protocol CompanionDesktopExecuting: AnyObject {
    /// Only the visible local enable action may call this; never model output.
    func prepareControlAccess() -> Bool
    func visibleWindows(in screenshotBounds: CGRect) async throws -> [CompanionDesktopWindowSnapshot]
    func resolveTarget(at point: CGPoint, screenshotBounds: CGRect) async throws -> TargetSnapshot
    /// Activation is part of the explicitly enabled control session, never the cursor overlay.
    func prepareTarget(_ target: TargetSnapshot, at point: CGPoint, gate: SafetyGate, epoch: UInt64) async throws -> TargetSnapshot
    func dispatchClick(at point: CGPoint, target: TargetSnapshot, request: ActionRequest,
                       gate: SafetyGate, ownerID: String) async throws -> ActionOutcome
}

public extension CompanionDesktopExecuting {
    // Injectable fixture executors do not ask macOS for permissions.
    func prepareControlAccess() -> Bool { true }
}

@MainActor public protocol CompanionDesktopCursorDisplaying: AnyObject {
    func show(at point: CGPoint)
    func hide()
}

/// Explicit local scope + one model proposal per user turn. Sharing, microphone
/// activation and account connection never enable computer control implicitly.
@MainActor public final class CompanionDesktopControl: ObservableObject {
    @Published public private(set) var enabled = false
    @Published public private(set) var automaticClicks = false
    @Published public private(set) var executing = false
    @Published public private(set) var pending: CompanionDesktopProposal?
    @Published public private(set) var status = "Bilgisayar kontrolü kapalı"
    public private(set) var scope: CompanionDesktopScope = .allVisibleApps
    public static let proposalLifetime: TimeInterval = 20
    public static let maximumFrameAge: TimeInterval = 10
    private let executor: any CompanionDesktopExecuting
    private let cursor: any CompanionDesktopCursorDisplaying
    private let clock: any GateClock
    private let gate: SafetyGate
    private let previewDelayNanoseconds: UInt64
    private let ownerID = UUID().uuidString
    private var generation = UUID()
    private var preparingProposal: UUID?
    private var preparedCaptureID: UUID?
    private var registeringCaptureID: UUID?
    private var expiryTask: Task<Void, Never>?
    private struct RegisteredFrame {
        let id: String
        let bounds: CGRect
        let capturedAt: Date
        let windows: [CompanionDesktopWindowSnapshot]
    }
    private var frame: RegisteredFrame?

    public init(executor: (any CompanionDesktopExecuting)? = nil,
                cursor: (any CompanionDesktopCursorDisplaying)? = nil,
                clock: any GateClock = SystemGateClock(), previewDelayNanoseconds: UInt64 = 200_000_000) {
        self.executor = executor ?? CompanionDesktopNativeExecutor()
        self.cursor = cursor ?? CompanionDesktopCursorOverlay()
        self.clock = clock
        self.previewDelayNanoseconds = min(previewDelayNanoseconds, 500_000_000)
        gate = SafetyGate(clock: clock, maxFrameAge: Self.maximumFrameAge, leaseDuration: 20, actionTimeout: 2)
    }

    /// Call only from an explicit visible local control toggle, not model output.
    public func enable(scope: CompanionDesktopScope = .allVisibleApps, automaticClicks: Bool = true) {
        guard !executing else { status = "Önce mevcut tıklamanın durmasını bekle."; return }
        revokeProposal()
        guard executor.prepareControlAccess() else {
            enabled = false; self.automaticClicks = false
            status = "Erişilebilirlik ve Ekran Kaydı izni gerekiyor. Sistem Ayarları → Gizlilik ve Güvenlik altında Bavbav'a izin ver; sonra Kontrolü başlat'a tekrar bas. Otomatik izin verilmez."
            return
        }
        self.scope = scope; self.automaticClicks = automaticClicks; enabled = true
        status = automaticClicks ? "Kontrol açık · her kullanıcı turunda en fazla bir sıradan tıklama" : "Kontrol açık · her tıklama yerel onay bekler"
    }

    /// Call BEFORE capture. Registration requires the same ordered window
    /// identities and geometry AFTER capture, so a moved/covered window cannot
    /// bind old pixels to a newly occupying application. No pixels/input are read.
    public func prepareFrameCapture(screenshotBounds: CGRect) async throws -> CompanionDesktopCaptureSnapshot {
        try Task.checkCancellation()
        guard enabled, !executing else { throw CompanionFailure("Bilgisayar kontrolü kapalı veya meşgul.") }
        guard Self.valid(screenshotBounds) else { throw CompanionFailure("Ekran geometrisi geçersiz.") }
        revokeProposal()
        let token = generation; let id = UUID(); preparedCaptureID = id
        let windows = try await executor.visibleWindows(in: screenshotBounds)
        try Task.checkCancellation()
        guard enabled, generation == token, preparedCaptureID == id else { throw CancellationError() }
        guard Self.valid(windows, in: screenshotBounds) else {
            preparedCaptureID = nil
            throw CompanionFailure("Görüntü öncesi hedef pencereler doğrulanamadı.")
        }
        return CompanionDesktopCaptureSnapshot(id: id, generation: token, bounds: screenshotBounds,
            preparedAt: Date(timeIntervalSince1970: clock.unixMS / 1_000), windows: windows)
    }

    /// Call AFTER capture and before model inference. The snapshot is consumed
    /// before the first await; STOP/re-enable/replacement cannot revive it.
    public func registerFrame(snapshot: CompanionDesktopCaptureSnapshot, capturedAt: Date) async throws {
        try Task.checkCancellation()
        guard enabled, !executing, snapshot.generation == generation,
              preparedCaptureID == snapshot.id, registeringCaptureID == nil,
              fresh(snapshot.preparedAt), fresh(capturedAt),
              capturedAt.timeIntervalSince(snapshot.preparedAt) >= -0.001 else {
            throw CompanionFailure("Görüntü güncel, etkin çekim öncesi kapsamına bağlı değil.")
        }
        preparedCaptureID = nil; registeringCaptureID = snapshot.id
        defer { if registeringCaptureID == snapshot.id { registeringCaptureID = nil } }
        let windows = try await executor.visibleWindows(in: snapshot.bounds)
        try Task.checkCancellation()
        guard enabled, generation == snapshot.generation, registeringCaptureID == snapshot.id else { throw CancellationError() }
        guard fresh(snapshot.preparedAt), fresh(capturedAt), Self.valid(windows, in: snapshot.bounds),
              windows == snapshot.windows else {
            throw CompanionFailure("Görüntü alınırken pencere sırası veya konumu değişti; yeni görüntü gerekli.")
        }
        frame = RegisteredFrame(id: UUID().uuidString, bounds: snapshot.bounds, capturedAt: capturedAt, windows: snapshot.windows)
    }

    public func prepareProposal(response: String, screenshotBounds: CGRect,
                                capturedAt: Date) async throws -> CompanionDesktopProposal {
        guard enabled, !executing, pending == nil, preparingProposal == nil, let frame,
              frame.bounds == screenshotBounds, frame.capturedAt == capturedAt, fresh(capturedAt) else {
            throw CompanionFailure("Öneri güncel, kayıtlı ekran görüntüsüne bağlı değil. Yeni görüntüyle tekrar dene.")
        }
        let click = try CompanionDesktopClick.parse(response)
        let point = CGPoint(x: frame.bounds.minX + click.x * frame.bounds.width,
                            y: frame.bounds.minY + click.y * frame.bounds.height)
        guard let recorded = frame.windows.first(where: { $0.target.bounds.contains(Point(x: point.x, y: point.y)) }),
              recorded.layer == 0, recorded.target.isValid,
              !CompanionDesktopRisk.isBlockedBundle(recorded.target.bundleID),
              recorded.target.pid != Int32(ProcessInfo.processInfo.processIdentifier) else {
            throw CompanionFailure("Bu nokta sıradan bir hedef uygulama penceresinde değil; tıklama yapılmadı.")
        }
        if case .selectedWindow(let window) = scope {
            guard recorded.target.windowID == window.id, recorded.target.pid == window.pid,
                  recorded.target.bundleID == window.bundleID else { throw CompanionFailure("Nokta seçilen pencerenin dışında.") }
        }
        let token = generation
        // The SDK's own admission slot is reserved before the first await.
        // Session currently has one writer, but other embedders must not let
        // concurrent model completions replace one another's pending proposal.
        let reservation = UUID(); preparingProposal = reservation
        defer { if preparingProposal == reservation { preparingProposal = nil } }
        let actual = try await executor.resolveTarget(at: point, screenshotBounds: screenshotBounds)
        guard enabled, generation == token, fresh(capturedAt) else { throw CancellationError() }
        guard recorded.target.matches(actual), actual.isVisible else {
            throw CompanionFailure("Hedef görüntü alındıktan sonra değişti; başka pencereye yönlendirilmedi.")
        }
        let now = Date(timeIntervalSince1970: clock.unixMS / 1_000)
        let proposal = CompanionDesktopProposal(id: UUID(), explanation: click.explanation, point: point,
            target: actual, capturedAt: capturedAt, expiresAt: now.addingTimeInterval(Self.proposalLifetime),
            frameID: frame.id, generation: token)
        pending = proposal; cursor.show(at: point)
        status = "Tıklama önerisi · \(actual.bundleID) · \(click.explanation)"
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(Self.proposalLifetime * 1_000_000_000)) }
            catch { return }
            guard let self, self.pending?.id == proposal.id else { return }
            self.revokeProposal(); self.status = "Tıklama önerisinin süresi doldu; işlem yapılmadı."
        }
        return proposal
    }

    /// Only this method dispatches. Automatic mode requires a prior local enable;
    /// otherwise the UI must explicitly approve this exact proposal identity.
    public func executePending(id: UUID, userApproved: Bool = false) async throws -> ActionOutcome {
        guard enabled, !executing, let proposal = pending, proposal.id == id,
              proposal.generation == generation, automaticClicks || userApproved,
              proposal.expiresAt.timeIntervalSince1970 * 1_000 > clock.unixMS,
              fresh(proposal.capturedAt) else { throw CompanionFailure("Tıklama yetkisi, görüntüsü veya önerisi artık geçerli değil.") }
        executing = true; pending = nil; frame = nil; expiryTask?.cancel(); expiryTask = nil
        let token = generation
        defer { executing = false; cursor.hide() }
        do {
            // Yield long enough for AppKit to paint the green proposal cursor.
            // This wait is outside the gate lock and STOP remains immediate.
            if previewDelayNanoseconds > 0 { try await Task.sleep(nanoseconds: previewDelayNanoseconds) }
            guard enabled, generation == token, fresh(proposal.capturedAt) else { throw CancellationError() }
            cursor.hide()
            let target = try await executor.prepareTarget(proposal.target, at: proposal.point, gate: gate, epoch: gate.status().epoch)
            guard enabled, generation == token, fresh(proposal.capturedAt), proposal.target.matches(target),
                  target.isVisible, target.isFrontmost else { throw CancellationError() }
            let taskID = proposal.id.uuidString
            guard gate.proposeTask(ownerID: ownerID, taskID: taskID).state == "accepted",
                  gate.grantLocalControl(ownerID: ownerID, taskID: taskID, target: target).state == "accepted" else {
                throw CompanionFailure("Yerel kontrol kapsamı doğrulanamadı.")
            }
            let age = max(0, (clock.unixMS - proposal.capturedAt.timeIntervalSince1970 * 1_000) / 1_000)
            let pixelWidth = max(1, min(16_384, Int(target.bounds.width.rounded(.up))))
            let pixelHeight = max(1, min(16_384, Int(target.bounds.height.rounded(.up))))
            let frame = FrameRecord(frameID: proposal.frameID, sessionID: gate.sessionID, target: target,
                region: Rect(x: 0, y: 0, width: target.bounds.width, height: target.bounds.height),
                pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                capturedAtUnixMS: proposal.capturedAt.timeIntervalSince1970 * 1_000,
                capturedAtMonotonic: clock.monotonic - age, epoch: gate.status().epoch)
            guard gate.addFrame(frame) else { throw CompanionFailure("Tıklama görüntüsü eski veya kapsam dışında.") }
            let local = Point(x: (proposal.point.x - target.bounds.x) * Double(pixelWidth) / target.bounds.width,
                              y: (proposal.point.y - target.bounds.y) * Double(pixelHeight) / target.bounds.height)
            let request = ActionRequest(sessionID: gate.sessionID, taskID: taskID, actionID: taskID,
                frameID: frame.frameID, epoch: frame.epoch, expiresAtUnixMS: clock.unixMS + 1_900,
                kind: .click, x: local.x, y: local.y)
            let outcome = try await executor.dispatchClick(at: proposal.point, target: target, request: request,
                                                          gate: gate, ownerID: ownerID)
            guard enabled, generation == token else { throw CancellationError() }
            gate.invalidate(reason: "SINGLE_CLICK_FINISHED")
            status = outcome.dispatchedEvents == 2 ? "Tıklama hedef uygulamaya iletildi; sonucu ekranda doğrula." : "Tıklama tamamlanmadı; yeni işlem yapılmadı."
            return outcome
        } catch {
            gate.invalidate(reason: "CLICK_FAILED")
            if generation == token { status = "Tıklama yapılmadı veya durduruldu: \(error.localizedDescription)" }
            throw error
        }
    }

    /// Independent of model, network and microphone completion. Already posted
    /// events cannot be reversed; the native executor may only release an owed UP.
    public func stop() {
        enabled = false; automaticClicks = false; revokeProposal()
        status = "DURDURULDU · bilgisayar kontrolü ve sanal imleç kapalı"
    }

    private func revokeProposal() {
        generation = UUID(); gate.invalidate(reason: "COMPANION_DESKTOP_SCOPE_REVOKED"); gate.emergencyStop()
        pending = nil; frame = nil; preparingProposal = nil; preparedCaptureID = nil; registeringCaptureID = nil
        expiryTask?.cancel(); expiryTask = nil; cursor.hide()
    }
    private func fresh(_ capturedAt: Date) -> Bool {
        let age = (clock.unixMS - capturedAt.timeIntervalSince1970 * 1_000) / 1_000
        // Date's reference-epoch conversion can round a same-instant fixture or
        // native timestamp a few nanoseconds into the future. Permit <=1ms only;
        // never relabel a genuinely old or future screenshot as fresh.
        return age.isFinite && age >= -0.001 && age <= Self.maximumFrameAge
    }
    private static func valid(_ bounds: CGRect) -> Bool {
        [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy(\.isFinite)
            && bounds.width > 0 && bounds.height > 0 && bounds.width <= 32_768 && bounds.height <= 32_768
    }
    private static func valid(_ windows: [CompanionDesktopWindowSnapshot], in bounds: CGRect) -> Bool {
        let expected = Rect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height)
        return !windows.isEmpty && windows.count <= 256 && windows.allSatisfy {
            $0.target.isValid && $0.target.isVisible && $0.target.displayBounds == expected
        }
    }
}
