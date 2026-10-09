import AppKit
import ScreenCaptureKit
import CompanionSafety

/// Reuses Companion's revocation epoch. This component never grants control or
/// imports NativeDesktop: a share selection is NOT a desktop-input permission.
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

@MainActor public protocol CompanionScreenSource: AnyObject {
    func windows() async throws -> [CompanionWindow]
    func capture(_ window: CompanionWindow) async throws -> Data
}

@MainActor public final class SelectedWindowSource: CompanionScreenSource {
    public init() {}
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
