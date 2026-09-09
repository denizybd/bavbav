import AppKit

@MainActor
enum AppIconCheck {
    private struct Failure: Error { let message: String }

    /// Exercises real process-local appearance KVO with an injected icon sink.
    /// No Dock icon, system preference, user window or account is changed.
    static func run() async -> Bool {
        var checks = 0
        let originalAppearance = NSApp.appearance
        let originalSystemStyle = UserDefaults.standard.string(forKey: "AppleInterfaceStyle")
        let originalIcon = NSApp.applicationIconImage
        let initialWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let initialActive = NSApp.isActive
        var controllers: [AppIconController] = []
        defer {
            controllers.forEach { $0.stop() }
            NSApp.appearance = originalAppearance
        }
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            checks += 1
            if !condition() { throw Failure(message: message) }
        }
        func flush() async {
            for _ in 0..<4 { await Task.yield() }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        func fixtureImage(_ color: NSColor) -> NSImage {
            NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
                color.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 6, dy: 6), xRadius: 12, yRadius: 12).fill()
                return true
            }
        }
        do {
            try check(NSApp.activationPolicy() == .prohibited, "icon QA never enters Dock or app switcher")
            for (name, expected) in [(NSAppearance.Name.aqua, AppIconAppearance.light),
                                     (.darkAqua, .dark), (.accessibilityHighContrastAqua, .light),
                                     (.accessibilityHighContrastDarkAqua, .dark)] {
                guard let appearance = NSAppearance(named: name) else { throw Failure(message: "missing native appearance \(name)") }
                try check(AppIconAppearance.matching(appearance) == expected, "native appearance mapping: \(name)")
            }

            let light = fixtureImage(.white), dark = fixtureImage(.black)
            var loadCounts: [AppIconAppearance: Int] = [:]
            var received: [NSImage] = []
            let controller = AppIconController(imageLoader: { appearance in
                loadCounts[appearance, default: 0] += 1
                return appearance == .light ? light : dark
            }, publish: { received.append($0) })
            controllers.append(controller)
            NSApp.appearance = NSAppearance(named: .aqua)
            controller.start()
            await flush()
            try check(received.count == 1 && received.last === light, "initial KVO publishes light variant")
            controller.start()
            NSApp.appearance = NSAppearance(named: .aqua)
            await flush()
            try check(received.count == 1, "duplicate start and equal appearance do not republish")
            NSApp.appearance = NSAppearance(named: .darkAqua)
            await flush()
            try check(received.count == 2 && received.last === dark, "actual process-local dark appearance change updates icon")
            NSApp.appearance = NSAppearance(named: .accessibilityHighContrastDarkAqua)
            await flush()
            try check(received.count == 2, "high-contrast dark uses same cached icon without republishing")
            NSApp.appearance = NSAppearance(named: .accessibilityHighContrastAqua)
            await flush()
            try check(received.count == 3 && received.last === light, "high-contrast light updates icon")
            try check(loadCounts[.light] == 1 && loadCounts[.dark] == 1, "two variants loaded once, never per notification")
            controller.stop()
            NSApp.appearance = NSAppearance(named: .darkAqua)
            await flush()
            try check(received.count == 3, "stopping observation prevents later changes")
            controller.start()
            await flush()
            try check(received.count == 4 && received.last === dark, "restart resolves current appearance")
            controller.stop()

            var missingCount = 0
            let missing = AppIconController(imageLoader: { _ in nil }, publish: { _ in missingCount += 1 })
            controllers.append(missing)
            missing.start()
            await flush()
            try check(missingCount == 0 && missing.publishedAppearance == nil, "missing artwork leaves bundle icon untouched")
            missing.stop()

            var fallback: [NSImage] = []
            let oneVariant = AppIconController(imageLoader: { $0 == .light ? light : nil }, publish: { fallback.append($0) })
            controllers.append(oneVariant)
            oneVariant.start()
            await flush()
            try check(fallback.count == 1 && fallback.last === light, "missing dark asset uses valid light fallback")
            NSApp.appearance = NSAppearance(named: .aqua)
            await flush()
            try check(fallback.count == 1, "fallback image does not churn on appearance change")
            oneVariant.stop()

            var stoppedCount = 0
            let stopped = AppIconController(imageLoader: { _ in light }, publish: { _ in stoppedCount += 1 })
            controllers.append(stopped)
            stopped.start()
            stopped.stop()
            await flush()
            try check(stoppedCount == 0, "queued initial notification is cancelled by stop")

            var releasedCount = 0
            var released: AppIconController? = AppIconController(imageLoader: { _ in light }, publish: { _ in releasedCount += 1 })
            weak var weakController = released
            released?.start()
            released = nil
            await flush()
            try check(weakController == nil && releasedCount == 0, "KVO and queued callback do not retain controller")

            let environment = ProcessInfo.processInfo.environment
            let resourceDirectory = environment["BAVBAV_ICON_RESOURCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? Bundle.main.resourceURL
            guard let resourceDirectory else { throw Failure(message: "missing packaged icon resource directory") }
            var rimLuminances: [AppIconAppearance: Double] = [:]
            for appearance in AppIconAppearance.allCases {
                let url = resourceDirectory.appendingPathComponent(appearance.resourceName).appendingPathExtension("png")
                guard let bitmap = NSBitmapImageRep(data: try Data(contentsOf: url)), let sourceImage = bitmap.cgImage else {
                    throw Failure(message: "invalid packaged icon: \(url.path)")
                }
                try check(bitmap.pixelsWide == 1024 && bitmap.pixelsHigh == 1024 && bitmap.hasAlpha,
                          "\(appearance.rawValue) artwork is 1024px with alpha")
                let horizontal = (0..<1024).filter { (bitmap.colorAt(x: $0, y: 512)?.alphaComponent ?? 0) > 0.95 }
                let vertical = (0..<1024).filter { (bitmap.colorAt(x: 512, y: $0)?.alphaComponent ?? 0) > 0.95 }
                for occupied in [horizontal, vertical] {
                    let span = (occupied.last ?? 0) - (occupied.first ?? 0) + 1
                    try check((790...850).contains(span), "\(appearance.rawValue) native icon footprint occupies about 80% of canvas")
                }
                if let rim = bitmap.colorAt(x: 512, y: 128)?.usingColorSpace(.deviceRGB) {
                    rimLuminances[appearance] = Double(rim.redComponent * 0.2126 + rim.greenComponent * 0.7152 + rim.blueComponent * 0.0722)
                }
                for fraction in [0.0, 0.02] {
                    let inset = Int(Double(bitmap.pixelsWide - 1) * fraction)
                    for x in [inset, bitmap.pixelsWide - 1 - inset] {
                        for y in [inset, bitmap.pixelsHigh - 1 - inset] {
                            try check((bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 1) < 0.02,
                                      "\(appearance.rawValue) corner is transparent at \(x),\(y)")
                        }
                    }
                }
                for size in [16, 32, 64] {
                    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                                  bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                        throw Failure(message: "could not render small icon")
                    }
                    context.interpolationQuality = .high
                    context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: size, height: size))
                    guard let image = context.makeImage() else { throw Failure(message: "small icon render missing") }
                    let small = NSBitmapImageRep(cgImage: image)
                    var opaque = 0, darkest = 1.0, brightest = 0.0
                    for y in 0..<size {
                        for x in 0..<size {
                            guard let color = small.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.95 else { continue }
                            let luma = Double(color.redComponent * 0.2126 + color.greenComponent * 0.7152 + color.blueComponent * 0.0722)
                            opaque += 1
                            darkest = min(darkest, luma); brightest = max(brightest, luma)
                        }
                    }
                    try check((small.colorAt(x: 0, y: 0)?.alphaComponent ?? 1) < 0.05,
                              "\(appearance.rawValue) icon keeps transparent corner at \(size)px")
                    try check(opaque > size * size / 3 && opaque < size * size,
                              "\(appearance.rawValue) visible small-size silhouette at \(size)px")
                    try check(brightest - darkest > 0.2, "\(appearance.rawValue) mark contrasts with tile at \(size)px")
                }
            }
            try check((rimLuminances[.light] ?? 0) > 0.7 && (rimLuminances[.dark] ?? 1) < 0.35,
                      "light artwork has a white tile and dark artwork a near-black tile")
            var packagedImage: NSImage?
            let packaged = AppIconController(resourceDirectory: resourceDirectory, publish: { packagedImage = $0 })
            controllers.append(packaged)
            packaged.start()
            await flush()
            try check(packagedImage?.isValid == true && packaged.publishedAppearance == .light,
                      "production resource loader publishes valid named artwork")
            packaged.stop()
            try check(NSApp.applicationIconImage === originalIcon, "injected tests never replace the actual Dock icon")
            try check(UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == originalSystemStyle,
                      "system appearance preference remains untouched")
            try check(Set(NSApp.windows.map(ObjectIdentifier.init)) == initialWindows && NSApp.isActive == initialActive,
                      "no user window is created or activated")
            print("BAVBAV APP ICON CHECK PASSED: \(checks) checks; transparent rounded assets, 16/32/64px contrast, real local appearance KVO and caches; no Dock, global theme or foreground changes")
            return true
        } catch {
            let message = (error as? Failure)?.message ?? error.localizedDescription
            fputs("BAVBAV APP ICON CHECK FAILED after \(checks) checks: \(message)\n", stderr)
            return false
        }
    }
}
