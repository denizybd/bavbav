import AppKit
import ApplicationServices
import CoreGraphics
import CompanionSafety

/// Native path is intentionally mouse-click only. No permission requests,
/// keyboard events, shell, background-app remapping or credential extraction.
@MainActor public final class CompanionDesktopNativeExecutor: CompanionDesktopExecuting {
    public init() {}
    public var permissionsReady: Bool { AXIsProcessTrusted() && CGPreflightScreenCaptureAccess() && CGPreflightPostEventAccess() }

    public func prepareControlAccess() -> Bool {
        // Visible local Start is the only authorization prompt boundary. This
        // requests the user's macOS decision; it never clicks or bypasses Allow.
        let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        return trusted && CGPreflightScreenCaptureAccess() && CGPreflightPostEventAccess()
    }

    public func visibleWindows(in screenshotBounds: CGRect) async throws -> [CompanionDesktopWindowSnapshot] {
        guard CGPreflightScreenCaptureAccess() else { throw CompanionFailure("Ekran Kaydı izni gerekiyor; otomatik izin verilmez.") }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return try await Task.detached(priority: .userInitiated) {
            try Self.snapshots(in: screenshotBounds, frontmostPID: frontmost)
        }.value
    }

    public func resolveTarget(at point: CGPoint, screenshotBounds: CGRect) async throws -> TargetSnapshot {
        let windows = try await visibleWindows(in: screenshotBounds)
        guard let hit = windows.first(where: { $0.target.bounds.contains(Point(x: point.x, y: point.y)) }),
              hit.layer == 0, hit.target.isValid, hit.target.isVisible,
              hit.target.pid != Int32(ProcessInfo.processInfo.processIdentifier),
              !CompanionDesktopRisk.isBlockedBundle(hit.target.bundleID) else {
            throw CompanionFailure("Nokta kapalı, örtülü veya izin verilmeyen bir hedefte.")
        }
        return hit.target
    }

    public func prepareTarget(_ target: TargetSnapshot, at point: CGPoint,
                              gate: SafetyGate, epoch: UInt64) async throws -> TargetSnapshot {
        guard permissionsReady else {
            throw CompanionFailure("Tıklama için macOS Erişilebilirlik ve Ekran Kaydı izni gerekli. Sistem izinleri otomatik geçilemez.")
        }
        let display = Self.cgRect(target.displayBounds)
        let before = try await resolveTarget(at: point, screenshotBounds: display)
        guard gate.status().epoch == epoch, target.matches(before) else { throw CancellationError() }
        // The user enabled computer control; ordinary app activation is part of
        // this exact click. The virtual cursor never invokes activation itself.
        guard let app = NSRunningApplication(processIdentifier: target.pid),
              app.bundleIdentifier == target.bundleID else { throw CompanionFailure("Hedef uygulama kimliği değişti.") }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.pid {
            guard gate.status().epoch == epoch, app.activate(options: [.activateIgnoringOtherApps]) else {
                throw CompanionFailure("Hedef uygulama öne getirilemedi; tıklama yapılmadı.")
            }
            try await Task.sleep(nanoseconds: 80_000_000)
        }
        guard gate.status().epoch == epoch else { throw CancellationError() }
        let current = try await resolveTarget(at: point, screenshotBounds: display)
        guard gate.status().epoch == epoch, target.matches(current), current.isFrontmost else {
            throw CompanionFailure("Öne getirme sırasında hedef pencere veya konum değişti; tıklama yapılmadı.")
        }
        try await Task.detached(priority: .userInitiated) {
            try Self.validateAccessibility(target: current, point: point)
        }.value
        guard gate.status().epoch == epoch else { throw CancellationError() }
        return current
    }

    public func dispatchClick(at point: CGPoint, target: TargetSnapshot, request: ActionRequest,
                              gate: SafetyGate, ownerID: String) async throws -> ActionOutcome {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard frontmost == target.pid else { throw CompanionFailure("Hedef uygulama artık önde değil.") }
        return try await Task.detached(priority: .userInitiated) {
            try Self.dispatch(point: point, target: target, request: request, gate: gate,
                              ownerID: ownerID, frontmostPID: frontmost)
        }.value
    }

    nonisolated private static func dispatch(point: CGPoint, target: TargetSnapshot, request: ActionRequest,
                                            gate: SafetyGate, ownerID: String, frontmostPID: Int32?) throws -> ActionOutcome {
        let current = try validateCurrent(target: target, point: point, frontmostPID: frontmostPID)
        switch gate.preflight(request, currentTarget: current, ownerID: ownerID,
                              screenPermission: CGPreflightScreenCaptureAccess(), accessibilityPermission: AXIsProcessTrusted() && CGPreflightPostEventAccess()) {
        case .deny(let outcome): throw CompanionFailure("Tıklama güvenlik kapısı reddetti: \(outcome.errorCode ?? outcome.state)")
        case .allow: break
        }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            throw CompanionFailure("Yerel tıklama olayı oluşturulamadı.")
        }
        for event in [down, up] {
            event.flags = []; event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.setIntegerValueField(.eventSourceUserData, value: 0x424156434C49434B)
        }
        var downPosted = false; var upPosted = false
        do {
            for event in [down, up] {
                let now = try validateCurrent(target: target, point: point, frontmostPID: frontmostPID)
                // Every post uses the reused lock/epoch barrier. There are no AX
                // queries or awaits inside its bounded event-post callback.
                if let denial = gate.withDispatchAuthorization(request, currentTarget: now, ownerID: ownerID,
                    screenPermission: CGPreflightScreenCaptureAccess(), accessibilityPermission: AXIsProcessTrusted() && CGPreflightPostEventAccess(), body: {
                        // Directed PID delivery cannot accidentally click a newly
                        // foregrounded different application between validation/post.
                        event.postToPid(target.pid)
                    }) { throw CompanionFailure("Tıklama durduruldu: \(denial.errorCode ?? denial.state)") }
                if event.type == .leftMouseDown { downPosted = true } else { upPosted = true }
            }
            let result = ActionOutcome(state: "completed", actionID: request.actionID, dispatchedEvents: 2, verified: false)
            gate.recordOutcome(result, for: request)
            return result
        } catch {
            // Only an owed release bypasses revocation. It is PID-directed and
            // cannot introduce a new click, change target or retain a held DOWN.
            if downPosted && !upPosted { up.postToPid(target.pid) }
            let result = ActionOutcome(state: downPosted ? "unknown" : "rejected", errorCode: "NATIVE_CLICK_CANCELLED",
                                       actionID: request.actionID, dispatchedEvents: downPosted ? 1 : 0, verified: false)
            gate.recordOutcome(result, for: request)
            throw error
        }
    }

    nonisolated private static func validateCurrent(target: TargetSnapshot, point: CGPoint,
                                                   frontmostPID: Int32?) throws -> TargetSnapshot {
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess(), CGPreflightScreenCaptureAccess() else {
            throw CompanionFailure("macOS izinleri artık etkin değil.")
        }
        let windows = try snapshots(in: cgRect(target.displayBounds), frontmostPID: frontmostPID)
        guard let hit = windows.first(where: { $0.target.bounds.contains(Point(x: point.x, y: point.y)) }),
              hit.layer == 0, target.matches(hit.target), hit.target.isVisible, hit.target.isFrontmost else {
            throw CompanionFailure("Tıklama noktası veya hedef pencere değişti ya da örtüldü.")
        }
        try validateAccessibility(target: hit.target, point: point)
        return hit.target
    }

    nonisolated private static func snapshots(in displayBounds: CGRect, frontmostPID: Int32?) throws -> [CompanionDesktopWindowSnapshot] {
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            throw CompanionFailure("Görünür pencere sırası alınamadı.")
        }
        var displayID: UInt32 = 0; var scale = 1.0
        var active = [CGDirectDisplayID](repeating: 0, count: 32); var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(active.count), &active, &count) == .success,
              let display = active.prefix(Int(count)).first(where: { CGDisplayBounds($0) == displayBounds }) else {
            throw CompanionFailure("Paylaşılan ekranın düzeni değişti; yeni görüntü gerekli.")
        }
        displayID = display
        scale = Double(CGDisplayPixelsWide(display)) / max(1, displayBounds.width)
        var result: [CompanionDesktopWindowSnapshot] = []
        for row in rows {
            guard ((row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0) > 0.01,
                  let dictionary = row[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary), bounds.intersects(displayBounds),
                  let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { continue }
            let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "unknown.application"
            let target = TargetSnapshot(windowID: id, pid: pid, bundleID: bundle, displayID: displayID,
                bounds: rect(bounds), displayBounds: rect(displayBounds), scale: scale,
                isVisible: true, isFrontmost: frontmostPID == pid)
            result.append(CompanionDesktopWindowSnapshot(target: target,
                layer: (row[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1))
            if result.count == 256 { break }
        }
        return result
    }

    nonisolated private static func validateAccessibility(target: TargetSnapshot, point: CGPoint) throws {
        guard !CompanionDesktopRisk.isBlockedBundle(target.bundleID), target.pid != Int32(ProcessInfo.processInfo.processIdentifier) else {
            throw CompanionFailure("Bavbav, güvenlik pencereleri ve yürütülebilir komut girişleri kontrol edilmez.")
        }
        let app = AXUIElementCreateApplication(target.pid)
        guard AXUIElementSetMessagingTimeout(app, 0.10) == .success else { throw CompanionFailure("Hedef Erişilebilirlik zaman aşımı ayarlanamadı.") }
        let focused = try elementAttribute(app, kAXFocusedWindowAttribute)
        let focusedRect = try frame(of: focused)
        guard rect(focusedRect) == target.bounds else { throw CompanionFailure("Odaklanan pencere seçilen hedef değil.") }
        // AX does not expose a public CG window-ID attribute. Require the exact
        // focused bounds to resolve to only one on-screen window for this PID.
        let identical = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []).filter { row in
            guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == target.pid,
                  (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let dictionary = row[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary) else { return false }
            return rect(bounds) == target.bounds
        }
        guard identical.count == 1,
              (identical[0][kCGWindowNumber as String] as? NSNumber)?.uint32Value == target.windowID else {
            throw CompanionFailure("Odaklanan pencere kimliği belirsiz; tıklama yapılmadı.")
        }
        var minimized: CFTypeRef?
        if AXUIElementCopyAttributeValue(focused, kAXMinimizedAttribute as CFString, &minimized) == .success,
           minimized as? Bool == true { throw CompanionFailure("Hedef pencere küçültülmüş; tıklama yapılmadı.") }
        let system = AXUIElementCreateSystemWide()
        guard AXUIElementSetMessagingTimeout(system, 0.10) == .success else { throw CompanionFailure("Erişilebilirlik hit-test hazır değil.") }
        let focusedApp = try elementAttribute(system, kAXFocusedApplicationAttribute)
        var focusedPID: pid_t = 0
        guard AXUIElementGetPid(focusedApp, &focusedPID) == .success, focusedPID == target.pid else {
            throw CompanionFailure("Sistem odağı başka bir uygulamaya geçti; tıklama yapılmadı.")
        }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, var element = hit else {
            throw CompanionFailure("Tıklama noktasının UI öğesi doğrulanamadı.")
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid == target.pid else {
            throw CompanionFailure("Tıklama noktası başka bir uygulamaya ait.")
        }
        let containing = try elementAttribute(element, kAXWindowAttribute)
        guard CFEqual(containing, focused) else { throw CompanionFailure("Tıklama noktası başka bir pencereye ait.") }
        for _ in 0..<6 {
            guard AXUIElementSetMessagingTimeout(element, 0.10) == .success else { throw CompanionFailure("UI güvenlik sorgusu hazırlanamadı.") }
            for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXRoleAttribute, kAXSubroleAttribute] {
                var value: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(element, key as CFString, &value)
                guard status == .success || status == .attributeUnsupported || status == .noValue else {
                    throw CompanionFailure("UI güvenlik bilgisi doğrulanamadı.")
                }
                if let text = value as? String,
                   text == kAXSecureTextFieldSubrole || CompanionDesktopRisk.isRisky(text) {
                    throw CompanionFailure("Silme, ödeme, gönderim, hesap veya güvenlik UI'sinde tıklama yapılmaz.")
                }
            }
            if CFEqual(element, focused) { break }
            guard let parent = try? elementAttribute(element, kAXParentAttribute) else { break }
            element = parent
        }
    }

    nonisolated private static func elementAttribute(_ element: AXUIElement, _ key: String) throws -> AXUIElement {
        guard AXUIElementSetMessagingTimeout(element, 0.10) == .success else { throw CompanionFailure("AX sorgusu hazırlanamadı.") }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw CompanionFailure("Hedef pencere veya UI öğesi doğrulanamadı.")
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    nonisolated private static func frame(of element: AXUIElement) throws -> CGRect {
        var position: CFTypeRef?; var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else {
            throw CompanionFailure("Odaklanan pencere konumu doğrulanamadı.")
        }
        var point = CGPoint.zero; var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else {
            throw CompanionFailure("Odaklanan pencere geometrisi okunamadı.")
        }
        return CGRect(origin: point, size: dimensions)
    }
    nonisolated private static func rect(_ value: CGRect) -> Rect { Rect(x: value.minX, y: value.minY, width: value.width, height: value.height) }
    nonisolated private static func cgRect(_ value: Rect) -> CGRect { CGRect(x: value.x, y: value.y, width: value.width, height: value.height) }
}
