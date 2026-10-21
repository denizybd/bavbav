import AppKit
import WebKit

/// Hidden native checks with a static local HTML document and an ephemeral
/// browser profile. No remote page, user account, media or OS prompt is used.
@MainActor
enum BrowserWindowCheck {
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ description: String) { errorDescription = description }
    }

    static func run() async -> Bool {
        let suite = "Bavbav.BrowserCheck.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let preferences = AppPreferences(defaults: defaults)
        let browser = BrowserWindowController(preferences: preferences, ephemeral: true)
        let window = browser.window
        var report: [String: Any] = [
            "success": false, "renderKind": "native-window-and-WKWebView-snapshot",
            "physicalUserInteraction": false, "productionDataUsed": false,
            "remoteNetworkUsed": false, "mediaRequested": false,
            "dataStore": "isolated-ephemeral", "windowIdentifier": BrowserWindowController.identifier,
            "hostPID": Int(ProcessInfo.processInfo.processIdentifier),
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? ""
        ]
        var assertions = 0
        defer {
            browser.shutdown()
            defaults.removePersistentDomain(forName: suite)
        }
        func check(_ value: @autoclosure () -> Bool, _ description: String) throws {
            assertions += 1
            if !value() { throw Failure(description) }
        }
        func argument(_ name: String) -> String? {
            guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
            return CommandLine.arguments[index + 1]
        }
        func key(_ code: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags = [], type: NSEvent.EventType = .keyDown, repeated: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: repeated, keyCode: code)!
        }
        do {
            for raw in ["https://example.com/a?q=1#b", "http://127.0.0.1:8080/path", "https://[::1]/"] {
                try check(BrowserNavigationPolicy.allows(URL(string: raw)!), "HTTP(S) URL accepted: \(raw)")
            }
            for raw in ["javascript:alert(1)", "data:text/html,test", "file:///tmp/browser-check", "mailto:a@example.com",
                        "bavbav://command", "https://user:password@example.com", "https://user@example.com", "https:///missing-host"] {
                try check(!BrowserNavigationPolicy.allows(URL(string: raw)!), "unsafe navigation rejected: \(raw)")
            }
            try check(BrowserNavigationPolicy.destination(for: "example.com/path?q=1")?.absoluteString == "https://example.com/path?q=1",
                      "bare host and path use HTTPS")
            try check(BrowserNavigationPolicy.destination(for: "localhost:8080/path")?.absoluteString == "https://localhost:8080/path",
                      "localhost port is an address")
            try check(BrowserNavigationPolicy.destination(for: "[::1]:8080/path")?.host != nil, "IPv6 address is supported")
            let query = "Türkçe fatigue & life? x=1#2"
            let search = BrowserNavigationPolicy.destination(for: query)!
            try check(search.host == "www.google.com" && URLComponents(url: search, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == query,
                      "search preserves Unicode and reserved characters as one query value")
            for raw in ["", "  ", "javascript:alert(1)", "file:///tmp/test", "data:text/html,test", "https://name:secret@example.com", "https://example.com/\nnext"] {
                try check(BrowserNavigationPolicy.destination(for: raw) == nil, "unsafe address input rejected")
            }

            let firstWeb = browser.prepare()
            report["preparedVisible"] = window.isVisible
            report["preparedCanBecomeKey"] = window.canBecomeKey
            report["preparedCanBecomeMain"] = window.canBecomeMain
            report["activationPolicy"] = NSApp.activationPolicy().rawValue
            try check(!window.isVisible, "browser preparation keeps the native window hidden")
            // A prohibited diagnostic application cannot activate or become
            // main. Verify normal-window structure here; report those native
            // capability values separately from real interactive acceptance.
            try check(window.level == .normal && window.styleMask.contains(.titled)
                      && window.styleMask.contains(.resizable) && window.styleMask.contains(.closable),
                      "browser uses normal window stacking and native close/resize")
            try check(window.contentView is CornerResizeContainer, "existing corner handles and green focus ring wrap browser content")
            try check(!firstWeb.configuration.websiteDataStore.isPersistent, "fixture uses a private ephemeral browser store")
            try check(firstWeb.configuration.userContentController.userScripts.isEmpty, "browser adds no page script or native agent bridge")
            try check(!firstWeb.configuration.preferences.javaScriptCanOpenWindowsAutomatically, "script-owned automatic popups are disabled")
            try check(firstWeb.configuration.mediaTypesRequiringUserActionForPlayback == .all, "media never autoplays without a user gesture")
            try check(browser.prepare() === firstWeb, "repeated prepare reuses one WebKit view")
            try check(browser.observationCount == 6 && browser.hasKeyMonitor, "one scoped monitor and bounded WebKit observations are installed")
            preferences.setTransparency(25)
            try check(!window.isOpaque, "browser observes shared transparency preferences")
            preferences.resetTransparency()
            try check(window.isOpaque, "zero transparency restores an opaque dark window")

            firstWeb.loadHTMLString(fixture, baseURL: URL(string: "https://bavbav-browser-check.invalid/"))
            window.contentView?.layoutSubtreeIfNeeded()
            var documentReady = false
            for _ in 0..<120 {
                documentReady = (try? await firstWeb.evaluateJavaScript("document.getElementById('receipt')?.textContent === 'Local WebKit document'") as? Bool) == true
                if documentReady && !firstWeb.isLoading { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            try check(documentReady, "actual WKWebView loads the local fixture document")
            let title = try await firstWeb.evaluateJavaScript("document.title") as? String
            try check(title == "Bavbav local browser check", "loaded document title is read from WebKit")
            report["documentReady"] = documentReady
            report["documentTitle"] = title
            report["windowVisible"] = window.isVisible
            report["windowWidth"] = Double(window.frame.width)
            report["windowHeight"] = Double(window.frame.height)

            let snapshot: NSImage? = await withCheckedContinuation { continuation in
                firstWeb.takeSnapshot(with: nil) { image, _ in continuation.resume(returning: image) }
            }
            guard let snapshot, let tiff = snapshot.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure("local WKWebView snapshot unavailable") }
            var colors = Set<String>()
            for x in stride(from: 0, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 32)) {
                for y in stride(from: 0, to: bitmap.pixelsHigh, by: max(1, bitmap.pixelsHigh / 24)) {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                        colors.insert("\(Int(color.redComponent * 255)),\(Int(color.greenComponent * 255)),\(Int(color.blueComponent * 255))")
                    }
                }
            }
            try check(bitmap.pixelsWide > 300 && bitmap.pixelsHigh > 200 && colors.count > 8,
                      "WebKit rendered a nonuniform document snapshot")
            report["renderWidth"] = bitmap.pixelsWide
            report["renderHeight"] = bitmap.pixelsHigh
            report["renderSampleColors"] = colors.count
            report["renderBytes"] = png.count
            if let path = argument("--browser-render") {
                try png.write(to: URL(fileURLWithPath: path), options: .atomic)
                report["renderWritten"] = true
            }

            let addressKey = key(37, "l", .command)
            try check(browser.handleKey(addressKey) == nil && browser.isAddressEditing, "configured Command L focuses the native address field")
            _ = browser.handleKey(key(37, "l", .command, type: .keyUp))
            let typingQ = key(12, "q")
            try check(browser.handleKey(typingQ) === typingQ, "Q passes through while native address text is edited")
            for (code, character) in [(UInt16(0), "a"), (8, "c"), (9, "v")] {
                let event = key(code, character, .command)
                try check(browser.handleKey(event) === event, "native Command \(character.uppercased()) passes through")
            }
            let remapped = ShortcutBinding(strokes: [.init(37, [.command, .shift])])
            try check(preferences.keyBindings.set("browser.read.address.key", remapped), "address shortcut can be customized")
            try check(browser.handleKey(addressKey) === addressKey, "old address shortcut is not hardcoded after remapping")
            try check(browser.handleKey(key(37, "L", [.command, .shift])) == nil, "custom address shortcut is resolved from preferences")
            _ = browser.handleKey(key(37, "L", [.command, .shift], type: .keyUp))
            try check(preferences.keyBindings.set("browser.read.address.key", nil), "fixture restores default address shortcut")

            window.makeFirstResponder(firstWeb)
            for id in ["typing", "multiline", "editable"] {
                _ = try await firstWeb.evaluateJavaScript("document.getElementById('\(id)').focus()")
                let editing = await browser.pageIsEditing()
                try check(editing, "page editing is recognized for \(id) without reading its value")
            }
            _ = try await firstWeb.evaluateJavaScript("document.getElementById('typing').focus()")
            try check(browser.handleKey(key(12, "q")) == nil, "web input Q awaits the isolated edit-focus probe")
            let repeatedQ = key(12, "q", repeated: true)
            var repeatPreserved = false
            for _ in 0..<80 {
                repeatPreserved = browser.handleKey(repeatedQ) === repeatedQ
                if repeatPreserved { break }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            try check(repeatPreserved && browser.webView === firstWeb, "holding Q in a page input preserves native autorepeat and keeps the browser open")
            _ = browser.handleKey(key(12, "q", type: .keyUp))
            _ = try await firstWeb.evaluateJavaScript("document.activeElement.blur(); document.body.focus()")
            let reading = await browser.pageIsEditing()
            try check(!reading, "document reading permits Q close")
            window.makeFirstResponder(firstWeb)
            try check(browser.handleKey(key(12, "q")) == nil, "reading Q is handled by the browser")
            for _ in 0..<80 {
                if browser.webView == nil { break }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            try check(browser.webView == nil && browser.addressField == nil, "Q close releases the live page and native address field")
            try check(firstWeb.navigationDelegate == nil && firstWeb.uiDelegate == nil, "closing detaches WebKit delegates")
            try check(browser.observationCount == 0 && !browser.hasKeyMonitor, "closing removes observers and scoped keyboard monitor")
            let reopened = browser.prepare()
            try check(reopened !== firstWeb && browser.window === window, "reopening rebuilds WebKit inside the same bounded window")
            try check(reopened.url == nil && !reopened.isLoading, "hidden preparation does not reload a remote URL")
            browser.shutdown()
            try check(browser.webView == nil && !browser.hasKeyMonitor, "shutdown is idempotent and leaves no live page monitor")
            if CommandLine.arguments.contains("--browser-live") {
                // An explicitly selected transport smoke check, separate from
                // the zero-network local fixture. Never use an account page.
                report["remoteNetworkUsed"] = true
                let liveWeb = browser.prepare()
                let first = URL(string: "https://example.com/")!
                let second = URL(string: "https://example.com/?bavbav-browser-check=2")!
                func waitForPage(_ url: URL) async -> Bool {
                    for _ in 0..<200 {
                        if liveWeb.url == url, !liveWeb.isLoading,
                           (try? await liveWeb.evaluateJavaScript("document.readyState === 'complete' && document.title === 'Example Domain'") as? Bool) == true {
                            return true
                        }
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    return false
                }
                browser.navigate(first.absoluteString)
                let firstLoaded = await waitForPage(first)
                try check(firstLoaded, "public HTTPS example.com loads inside the hidden native browser")
                browser.navigate(second.absoluteString)
                let secondLoaded = await waitForPage(second)
                try check(secondLoaded && liveWeb.canGoBack, "second public URL creates native WebKit history")
                browser.goBack()
                let backLoaded = await waitForPage(first)
                try check(backLoaded && liveWeb.canGoForward, "native browser Back restores the first public URL")
                browser.goForward()
                let forwardLoaded = await waitForPage(second)
                try check(forwardLoaded, "native browser Forward restores the second public URL")
                let previousOrigin = try await liveWeb.evaluateJavaScript("performance.timeOrigin") as? Double
                browser.reload()
                var reloaded = false
                for _ in 0..<200 {
                    if !liveWeb.isLoading, let origin = try? await liveWeb.evaluateJavaScript("performance.timeOrigin") as? Double,
                       origin != previousOrigin { reloaded = true; break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                try check(reloaded, "native browser Reload creates a fresh public document")
                report["publicHTTPSLoaded"] = true
                report["publicHistoryBackForward"] = true
                report["publicReload"] = reloaded
                report["publicHost"] = liveWeb.url?.host
                browser.shutdown()
            }
            report["success"] = true
            print("BAVBAV BROWSER CHECK PASSED: \(assertions) assertions; hidden native window, local WebKit render, isolated profile")
        } catch {
            report["error"] = error.localizedDescription
            print("BAVBAV BROWSER CHECK FAILED: \(error.localizedDescription)")
        }
        report["assertions"] = assertions
        if let path = argument("--browser-report"), let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? bytes.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        return report["success"] as? Bool == true
    }

    private static let fixture = """
    <!doctype html><html lang="en"><head><meta charset="utf-8"><title>Bavbav local browser check</title>
    <style>
    * { box-sizing: border-box } body { margin:0; padding:52px; min-height:560px; background:#0b0d10; color:#d8dfe9;
      font:16px -apple-system,BlinkMacSystemFont,sans-serif } .card { max-width:720px; padding:34px;
      border:1px solid #28313b; border-radius:18px; background:#151b22 } h1 { margin:12px 0 16px; font-size:35px }
    .pill { display:inline-block; padding:8px 12px; border-radius:20px; background:#50e2b8; color:#10231d; font-size:12px;
      font-weight:700 } p { color:#98a7b6; line-height:1.6 } input,textarea,[contenteditable] { display:block; width:100%;
      margin-top:12px; padding:11px; color:#d8dfe9; background:#0b0d10; border:1px solid #34414e; border-radius:7px }
    </style></head><body tabindex="-1"><div class="card"><div class="pill">BAVBAV · NATIVE BROWSER</div>
    <h1>Pages stay inside Bavbav.</h1><p id="receipt">Local WebKit document</p><p>This page was loaded from a static local HTML fixture.</p>
    <input id="typing" placeholder="Address and page typing remain native"><textarea id="multiline" rows="2" placeholder="Text area"></textarea>
    <div id="editable" contenteditable="true">Editable text</div></div></body></html>
    """
}
