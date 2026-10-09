import AppKit
import BavbavCompanion

/// Hidden native theme fixtures only. Never opens a microphone, website, model turn or screen capture.
@MainActor enum CompanionThemeCheck {
    private struct Failure: Error { let message: String }
    private struct Pixels {
        var sampled = 0
        var clear = 0
        var opaque = 0
        var opaqueGreen = 0
        var foregroundByRegion: [String: Int] = [:]
    }

    static func run() async -> Bool {
        let domain = "bavbav.companion-theme-check.\(UUID())"
        guard let defaults = UserDefaults(suiteName: domain) else { return false }
        defer { defaults.removePersistentDomain(forName: domain) }
        let originalUserTransparency = UserDefaults.standard.object(forKey: AppPreferences.transparencyKey) as? NSNumber
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bavbav-companion-theme-\(UUID())", isDirectory: true)
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            count += 1
            guard condition() else { throw Failure(message: message) }
        }
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        func snapshot(_ view: NSView, name: String, regions: [String: NSRect]) throws -> Pixels {
            var pixels = Pixels()
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw Failure(message: "native Companion snapshot unavailable")
            }
            for (regionName, frame) in regions {
                guard let region = view.bitmapImageRepForCachingDisplay(in: frame) else {
                    throw Failure(message: "\(regionName) rendered region snapshot unavailable")
                }
                view.cacheDisplay(in: frame, to: region)
                guard let regionPNG = region.representation(using: .png, properties: [:]) else {
                    throw Failure(message: "\(regionName) rendered region PNG encoding failed")
                }
                try regionPNG.write(to: directory.appendingPathComponent("companion-\(name)-\(regionName).png"), options: .atomic)
                var foreground = 0
                for y in 0..<region.pixelsHigh {
                    for x in 0..<region.pixelsWide {
                        guard let color = region.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                              color.alphaComponent > 0.98 else { continue }
                        if max(color.redComponent, color.greenComponent, color.blueComponent) > 0.65,
                           color.redComponent + color.greenComponent + color.blueComponent > 1.1 {
                            foreground += 1
                        }
                    }
                }
                pixels.foregroundByRegion[regionName] = foreground
                print("COMPANION RENDERED REGION: \(name)/\(regionName) frame=\(frame) opaqueForeground=\(foreground)")
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw Failure(message: "Companion snapshot PNG encoding failed")
            }
            try png.write(to: directory.appendingPathComponent("companion-\(name).png"), options: .atomic)
            for y in stride(from: 1, to: bitmap.pixelsHigh, by: 2) {
                for x in stride(from: 1, to: bitmap.pixelsWide, by: 2) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    pixels.sampled += 1
                    if color.alphaComponent < 0.02 { pixels.clear += 1 }
                    if color.alphaComponent > 0.98 {
                        pixels.opaque += 1
                        // Header/control accent, not a filled backdrop; alpha must remain opaque.
                        if color.greenComponent > color.redComponent + 0.20,
                           color.blueComponent > color.redComponent + 0.10 {
                            pixels.opaqueGreen += 1
                        }
                    }
                }
            }
            print("COMPANION THEME PIXELS: \(name) sampled=\(pixels.sampled) clear=\(pixels.clear) opaque=\(pixels.opaque) opaqueGreen=\(pixels.opaqueGreen)")
            return pixels
        }

        let preferences = AppPreferences(defaults: defaults)
        var callbackValues: [Double] = []
        preferences.onTransparencyChanged = { callbackValues.append($0) }
        let web = ChatGPTWebSession()
        let controller = CompanionWindowController(webSession: web, preferences: preferences)
        defer { controller.window.close() }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try check(controller.preferences === preferences, "Companion must share the supplied preference instance")
            let identity = controller.appIdentity.snapshot
            try check(identity.bundleURL == Bundle.main.bundleURL.standardizedFileURL,
                      "Companion identity must describe the main Bavbav app, not a helper or another install")
            try check(identity.bundleIdentifier == (Bundle.main.bundleIdentifier ?? "bilinmiyor"),
                      "Companion identity must use the main Bavbav bundle identifier")
            try check(identity.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                      "Companion runs within the Bavbav GUI process")
            try check(identity.build == (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"),
                      "permission guidance names the actually running build")
            try check(controller.window.title.contains("Bavbav") && controller.window.title.contains("⌘6"),
                      "native window identity makes the shared Bavbav host and shortcut explicit")
            try check(identity.permissionGuidance.contains("ayrı bir uygulama değil"),
                      "permission guidance does not direct users to a separate Companion app")
            try check(!controller.session.screenSharing && !controller.session.desktopControl.enabled
                      && !controller.session.voiceConversationActive && !controller.session.integratedStarting,
                      "constructing Companion and reading identity never starts integrated media/control")
            controller.appIdentity.refresh()
            try check(controller.appIdentity.snapshot.bundleURL == identity.bundleURL,
                      "read-only permission refresh retains the actual main app identity")
            try check(controller.window.level == .normal, "Companion must use the ordinary application window stack")
            try check(!controller.window.styleMask.contains(.titled), "Companion uses the same borderless Bavbav frame")
            try check(controller.window.canBecomeKey && controller.window.canBecomeMain, "borderless Companion remains keyboard focusable")
            try check(controller.window.isMovableByWindowBackground, "Companion preserves ordinary window dragging")
            guard let root = controller.window.contentView as? CornerResizeContainer else {
                throw Failure(message: "Companion missing native corner/focus wrapper")
            }
            try check(descendants(root).compactMap { $0 as? CornerResizeHandle }.count == 4, "all four native resize corners remain available")
            guard let ring = descendants(root).compactMap({ $0 as? WindowFocusRing }).first else {
                throw Failure(message: "Companion missing Bavbav focus ring")
            }
            try check(ring.hitTest(.zero) == nil, "foreground focus ring never intercepts input")
            try check(preferences.onTransparencyChanged != nil, "controller must not replace or remove the coordinator callback")

            for percent in [0.0, 50.0, 100.0, 0.0] {
                preferences.setTransparency(percent)
                // Give the observed SwiftUI host a run-loop opportunity; no window is ordered front.
                try await Task.sleep(nanoseconds: 30_000_000)
                root.layoutSubtreeIfNeeded()
                let opacity = 1 - percent / 100
                try check(controller.window.alphaValue == 1, "foreground/window alpha remains1 at \(percent)%")
                try check(!controller.window.ignoresMouseEvents, "transparent Companion stays interactive at \(percent)%")
                try check(controller.window.isOpaque == (percent == 0), "fully opaque compositor path at0%; translucent otherwise")
                try check(abs((controller.window.backgroundColor?.alphaComponent ?? -1) - (percent == 0 ? 1 : 0)) < 0.001,
                          "native window background does not retain residual transparency/fill")
                try check(controller.window.hasShadow == (opacity > 0 && opacity < 1), "no shadow work at fully opaque or fully transparent settings")
                try check(!descendants(root).contains(where: { $0 is NSVisualEffectView }), "no backdrop blur/effect view at \(percent)%")
                try check(!controller.window.isVisible, "theme check never presents Companion")
                try check(!controller.session.connected && !controller.session.speech.dictationBusy && !controller.session.speech.speaking,
                          "theme check never starts account inference or audio")
                try check(!controller.session.integratedStarting && !controller.session.voiceConversationActive
                          && !controller.session.screenSharing && !controller.session.requestingScreenPermission
                          && !controller.session.desktopControl.enabled && !controller.session.desktopControl.automaticClicks
                          && controller.session.preview == nil && controller.session.lastCapturedAt == nil,
                          "layout/transparency updates never start unified media, permissions, capture or clicks")
                try check(web.webView == nil, "theme check never creates/navigates the ChatGPT web view")
                // A hidden SwiftUI window exposes no semantic AX children. Test-only
                // native backgrounds carry actual laid-out bounds and shared live labels.
                let elements = descendants(root).filter { $0.identifier?.rawValue.hasPrefix("companion.") == true }
                let startButtons = elements.filter { $0.identifier?.rawValue == "companion.integratedStart" }
                try check(startButtons.count == 1, "cold Companion presents one combined Start button")
                guard let start = startButtons.first,
                      let stop = elements.first(where: { $0.identifier?.rawValue == "companion.stopAll" }),
                      let disclosure = elements.first(where: { $0.identifier?.rawValue == "companion.startDisclosure" }),
                      let advanced = elements.first(where: { $0.identifier?.rawValue == "companion.advanced" }) else {
                    throw Failure(message: "combined Start, STOP or visible scope disclosure missing")
                }
                try check(start.isAccessibilityEnabled() && stop.isAccessibilityEnabled(),
                          "cold Start and independent STOP are available at \(percent)%")
                try check(start.accessibilityLabel()?.contains("Ses + ekran + imleci başlat") == true,
                          "primary action explicitly names voice, screen and cursor")
                let scopeText = disclosure.accessibilityLabel() ?? ""
                try check(scopeText.contains("mikrofonu") && scopeText.contains("fiziksel ekranın")
                          && scopeText.contains("özel bilgiler") && scopeText.contains("tıklamalara") && scopeText.contains("STOP"),
                          "visible Start disclosure covers microphone, full physical display, private data, clicks and STOP")
                let startFrame = start.convert(start.bounds, to: root)
                let stopFrame = stop.convert(stop.bounds, to: root)
                let disclosureFrame = disclosure.convert(disclosure.bounds, to: root)
                for element in elements {
                    try check(!element.isAccessibilityElement() && element.hitTest(.zero) == nil && !element.isOpaque,
                              "test-only layout backgrounds export no AX, draw no opaque fill and intercept no events")
                }
                for (name, frame) in [("Start", startFrame), ("STOP", stopFrame)] {
                    try check(frame.width >= 100 && frame.height >= 24 && root.bounds.contains(frame),
                              "\(name) has a visible useful native hit target at \(percent)%")
                    let hit = root.hitTest(NSPoint(x: frame.midX, y: frame.midY))
                    try check(hit != nil && !(hit is WindowFocusRing) && !(hit is CornerResizeHandle),
                              "\(name) target reaches hosted content instead of decorative/corner overlays")
                }
                try check(disclosureFrame.height > 0 && root.bounds.contains(disclosureFrame)
                          && !disclosureFrame.intersects(startFrame) && !startFrame.intersects(stopFrame),
                          "scope disclosure and primary/STOP targets are visible without overlapping")
                try check((advanced.accessibilityValue() as? NSNumber)?.boolValue == false
                          && advanced.bounds.height < 50,
                          "Gelişmiş remains a collapsed rendered disclosure")
                try check(!elements.contains(where: { $0.identifier?.rawValue == "companion.voiceConversation" }),
                          "separate voice start stays inside collapsed advanced controls")
                let name = percent == 100 ? "transparent" : percent == 50 ? "half" : callbackValues.isEmpty ? "opaque" : "opaque-reset"
                let pixels = try snapshot(root, name: name, regions: ["start": startFrame, "stop": stopFrame, "disclosure": disclosureFrame])
                for regionName in ["start", "stop", "disclosure"] {
                    try check((pixels.foregroundByRegion[regionName] ?? 0) > 8,
                              "\(regionName) actual bitmap region contains readable opaque foreground at \(percent)%")
                }
                if percent == 0 {
                    try check(pixels.sampled > 100 && pixels.opaque > pixels.sampled * 99 / 100,
                              "actual opaque Companion bitmap covers even gaps at0%")
                    try check(pixels.opaqueGreen > 8, "actual opaque bitmap contains readable fully opaque accent text")
                } else if percent == 100 {
                    try check(pixels.clear > pixels.sampled / 5, "actual100% Companion bitmap has genuinely clear backdrop regions")
                    try check(pixels.opaqueGreen > 8, "actual100% Companion accent/text remains fully opaque")
                }
            }
            try check(callbackValues == [50, 100, 0], "shared coordinator callback receives every preference update unchanged")
            try check(AppPreferences(defaults: defaults).transparencyPercent == 0, "isolated preference reset persists")
            let currentUserTransparency = UserDefaults.standard.object(forKey: AppPreferences.transparencyKey) as? NSNumber
            try check(currentUserTransparency == originalUserTransparency, "user's saved transparency remains untouched")
            await controller.shutdown()
            try check(!controller.session.stopping, "hidden cold shutdown finishes without starting a worker")
            print("COMPANION THEME CHECK PASSED: \(count) checks; hidden real host, combined Start/disclosure/STOP hit targets, collapsed advanced controls, background-only alpha, opaque foreground, shared preference updates, native corners/focus; no audio/network/capture")
            print("COMPANION THEME SNAPSHOTS: \(directory.path)")
            return true
        } catch {
            fputs("COMPANION THEME CHECK FAILED: \((error as? Failure)?.message ?? error.localizedDescription)\n", stderr)
            print("COMPANION THEME SNAPSHOTS: \(directory.path)")
            return false
        }
    }
}
