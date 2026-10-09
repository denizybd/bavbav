import AppKit
import ScreenCaptureKit
import CompanionSafety

/// Reuses Companion's revocation epoch. This component never grants control or
/// imports NativeDesktop: screen sharing is NOT a desktop-input permission.
public final class CompanionFence {
    private let gate = SafetyGate()
    public init() {}
    public var token: UInt64 { gate.status().epoch }
    public func accepts(_ token: UInt64) -> Bool { token == self.token }
    public func revoke() { gate.invalidate(reason: "COMPANION_SCOPE_STOPPED"); gate.emergencyStop() }
}

public struct CompanionWindow: Identifiable, Equatable, Sendable {
    public let id: UInt32
    public let pid: Int32
    public let bundleID: String
    public let label: String
    public init(id: UInt32, pid: Int32, bundleID: String, label: String) {
        self.id = id; self.pid = pid; self.bundleID = bundleID; self.label = label
    }
}

/// A single physical display selected for full-screen sharing. Width and height
/// use ScreenCaptureKit's screen-point dimensions, not Retina backing pixels.
/// Keeping the identity and dimensions rejects removed or reconfigured displays
/// rather than silently capturing a different screen.
public struct CompanionDisplay: Identifiable, Equatable, Sendable {
    public let id: UInt32
    public let width: Int
    public let height: Int
    public let label: String
    public init(id: UInt32, width: Int, height: Int, label: String) {
        self.id = id; self.width = width; self.height = height; self.label = label
    }
}

@MainActor public protocol CompanionScreenSource: AnyObject {
    func windows() async throws -> [CompanionWindow]
    func capture(_ window: CompanionWindow) async throws -> Data
    func displays() async throws -> [CompanionDisplay]
    func captureDisplay(_ display: CompanionDisplay) async throws -> Data
}

/// Legacy window-only adapters remain compatible, but never broaden their scope
/// by substituting a window or an arbitrary display for a full-screen request.
public extension CompanionScreenSource {
    func displays() async throws -> [CompanionDisplay] {
        throw CompanionFailure("Bu ekran kaynağı tam ekran paylaşımını desteklemiyor.")
    }
    func captureDisplay(_ display: CompanionDisplay) async throws -> Data {
        throw CompanionFailure("Bu ekran kaynağı tam ekran paylaşımını desteklemiyor.")
    }
}

@MainActor public final class SelectedWindowSource: CompanionScreenSource {
    public init() {}

    public func displays() async throws -> [CompanionDisplay] {
        // Enumeration is requested by the user's share controls, never at init
        // or account connection. No capture or microphone is started here.
        guard #available(macOS 14.0, *) else {
            throw CompanionFailure("Tam ekran paylaşımı macOS 14 veya üzerini gerektiriyor.")
        }
        try Task.checkCancellation()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        let screens = NSScreen.screens
        return content.displays.filter { $0.width > 0 && $0.height > 0 }.map { display in
            let screen = screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
            }
            let name = screen?.localizedName ?? "Ekran \(display.displayID)"
            return CompanionDisplay(id: display.displayID, width: display.width, height: display.height,
                                    label: "\(name) · \(display.width) × \(display.height)")
        }.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    public func captureDisplay(_ selection: CompanionDisplay) async throws -> Data {
        guard #available(macOS 14.0, *) else {
            throw CompanionFailure("Tam ekran paylaşımı macOS 14 veya üzerini gerektiriyor.")
        }
        try Task.checkCancellation()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard selection.width > 0, selection.height > 0,
              let display = content.displays.first(where: {
                  $0.displayID == selection.id && $0.width == selection.width && $0.height == selection.height
              }) else {
            throw CompanionFailure("Paylaşılan ekran çıkarıldı veya boyutu değişti. Yeniden seç; başka ekran otomatik paylaşılmaz.")
        }
        // An empty exclusion list means the entire selected display, including
        // visible app windows, desktop and Dock. It is not a stitched desktop
        // or a window filter. The account transport adds no input permissions.
        let filter = SCContentFilter(display: display, excludingWindows: [])
        if #available(macOS 14.2, *) { filter.includeMenuBar = true }
        let configuration = SCStreamConfiguration()
        let ratio = min(1, 1280.0 / Double(max(display.width, display.height)))
        configuration.width = max(1, Int(Double(display.width) * ratio))
        configuration.height = max(1, Int(Double(display.height) * ratio))
        configuration.showsCursor = false
        configuration.capturesAudio = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        // Native screenshot completion may arrive after STOP; do not encode or
        // return that late frame when the owning share task has been cancelled.
        try Task.checkCancellation()
        guard image.width <= 1280, image.height <= 1280,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
              png.count <= 6 * 1024 * 1024 else {
            throw CompanionFailure("Ekran görüntüsü hazırlanamadı veya çok büyük.")
        }
        return png
    }

    public func windows() async throws -> [CompanionWindow] {
        // Called only by the visible Choose Window button, never on launch.
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        return content.windows.compactMap { window in
            guard let app = window.owningApplication, window.windowLayer == 0,
                  window.frame.width > 40, window.frame.height > 40 else { return nil }
            return CompanionWindow(id: window.windowID, pid: app.processID, bundleID: app.bundleIdentifier,
                                   label: "\(app.applicationName) · \(window.title ?? "Pencere")")
        }.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    public func capture(_ selection: CompanionWindow) async throws -> Data {
        guard #available(macOS 14.0, *) else { throw CompanionFailure("Tek pencere paylaşımı macOS 14 veya üzerini gerektiriyor.") }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: {
            $0.windowID == selection.id && $0.owningApplication?.processID == selection.pid &&
            $0.owningApplication?.bundleIdentifier == selection.bundleID && $0.isOnScreen
        }) else { throw CompanionFailure("Seçilen pencere kapandı veya değişti. Yeniden seç; başka pencere otomatik paylaşılmaz.") }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let ratio = min(1, 1280 / max(window.frame.width, window.frame.height))
        configuration.width = max(1, Int(window.frame.width * ratio))
        configuration.height = max(1, Int(window.frame.height * ratio))
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
              png.count <= 6 * 1024 * 1024 else { throw CompanionFailure("Pencere görüntüsü hazırlanamadı veya çok büyük.") }
        return png
    }
}
