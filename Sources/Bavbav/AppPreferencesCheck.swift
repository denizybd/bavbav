import AppKit
import BavbavCore
import SwiftUI

@MainActor
enum AppPreferencesCheck {
    private struct Failure: Error { let message: String }

    /// Offline, hidden-window checks. Never open settings, send global input,
    /// activate the application, or connect to the user's Codex account.
    static func run() -> Bool {
        let suiteName = "dev.deniz.bavbav.preferences-check.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let baseline = Set(NSApp.windows.map(ObjectIdentifier.init))
        var checks = 0
        defer {
            for window in NSApp.windows where !baseline.contains(ObjectIdentifier(window)) {
                window.close()
            }
            defaults.removePersistentDomain(forName: suiteName)
        }
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            checks += 1
            if !condition() { throw Failure(message: message) }
        }
        func ownedOverlays() -> [OverlayPanel] {
            NSApp.windows.compactMap { $0 as? OverlayPanel }
                .filter { !baseline.contains(ObjectIdentifier($0)) }
        }

        do {
            let preferences = AppPreferences(defaults: defaults)
            try check(preferences.transparencyPercent == 0, "new install must be opaque")
            var changes: [Double] = []
            preferences.onTransparencyChanged = { changes.append($0) }
            for percent in [50.0, 100.0, 0.0] {
                preferences.setTransparency(percent)
                try check(preferences.transparencyPercent == percent, "set \(percent)%")
                try check(AppPreferences(defaults: defaults).transparencyPercent == percent,
                          "persist/reload \(percent)%")
            }
            try check(changes == [50, 100, 0], "one callback per change")
            preferences.setTransparency(-10)
            try check(preferences.transparencyPercent == 0 && changes.count == 3,
                      "lower clamp/no redundant callback")
            preferences.setTransparency(120)
            try check(preferences.transparencyPercent == 100, "upper clamp")
            preferences.setTransparency(49.7)
            try check(preferences.transparencyPercent == 50, "whole-percent rounding")
            let savedChanges = changes
            for invalid in [Double.nan, Double.infinity, -Double.infinity] {
                preferences.setTransparency(invalid)
                try check(preferences.transparencyPercent == 50 && changes == savedChanges,
                          "nonfinite input must not change settings")
            }
            defaults.set("invalid", forKey: AppPreferences.transparencyKey)
            try check(AppPreferences(defaults: defaults).transparencyPercent == 0,
                      "malformed persisted value fallback")
            defaults.set(-25.0, forKey: AppPreferences.transparencyKey)
            try check(AppPreferences(defaults: defaults).transparencyPercent == 0,
                      "persisted lower clamp")
            defaults.set(150.0, forKey: AppPreferences.transparencyKey)
            try check(AppPreferences(defaults: defaults).transparencyPercent == 100,
                      "persisted upper clamp")
            defaults.set(0.0, forKey: AppPreferences.transparencyKey)

            try check(preferences.page == .home && preferences.selectedIndex == 0, "home route")
            preferences.moveSelection(delta: -10)
            try check(preferences.selectedIndex == 0, "home lower selection bound")
            preferences.activateSelection()
            try check(preferences.page == .shortcuts, "shortcuts route")
            preferences.moveSelection(delta: 1_000)
            try check(preferences.selectedIndex == AppPreferences.shortcuts.count - 1,
                      "shortcut upper selection bound")
            preferences.activateSelection()
            try check(preferences.page == .shortcuts && preferences.keyBindings.recording, "selected shortcut opens recorder")
            try check(preferences.goBack() && preferences.page == .home && preferences.selectedIndex == 0,
                      "shortcuts Q returns home selection")
            preferences.moveSelection(delta: 10)
            try check(preferences.selectedIndex == 1, "home upper selection bound")
            preferences.activateSelection()
            try check(preferences.page == .appearance, "appearance route")
            try check(preferences.goBack() && preferences.page == .home && preferences.selectedIndex == 1,
                      "appearance Q returns home selection")
            try check(!preferences.goBack(), "home Q delegates window closing")
            try check(AppPreferences.shortcuts.contains { $0.keys == "⌘X" }, "shortcut catalog includes settings")

            let screen = NSRect(x: -1440, y: -100, width: 1440, height: 900)
            let settingsFrame = AppSettingsController.frame(in: screen)
            try check(settingsFrame.size == NSSize(width: 360, height: 320), "compact default size")
            try check(settingsFrame.midX == screen.midX && settingsFrame.maxY == screen.maxY - 14,
                      "settings must be top-center on a negative-origin screen")
            let smallScreen = NSRect(x: -500, y: -300, width: 240, height: 190)
            let smallFrame = AppSettingsController.frame(in: smallScreen)
            try check(smallScreen.contains(smallFrame) && smallFrame.midX == smallScreen.midX,
                      "small-screen bounds and centering")

            let store = OverlayStore()
            let coordinator = PanelCoordinator(store: store, windowSizeDefaults: defaults)
            let controller = coordinator.appSettings
            let overlays = ownedOverlays()
            try check(overlays.count == 5, "all five existing panel types included")
            try check(!coordinator.hasVisibleWindows && !controller.window.isVisible,
                      "constructing preferences must not show any window")
            try check(controller.window.alphaValue == 1 && !controller.window.ignoresMouseEvents,
                      "settings recovery window remains usable")
            try check(controller.window.level == .normal && !controller.window.isFloatingPanel,
                      "settings uses ordinary macOS window stacking")
            try check(controller.window.minSize == NSSize(width: 300, height: 280)
                      && !controller.window.styleMask.contains(.resizable), "settings corner-only sizing")
            try check((controller.window.contentView as? CornerResizeContainer)?.subviews
                .compactMap { $0 as? CornerResizeHandle }.count == 4, "settings has four resize handles")

            for percent in [50.0, 100.0, 0.0] {
                coordinator.appPreferences.setTransparency(percent)
                let expected = CGFloat(1 - percent / 100)
                try check(coordinator.appPreferences.backgroundOpacity == expected, "background alpha at \(percent)%")
                for panel in overlays {
                    try check(panel.alphaValue == 1, "\(panel.overlayKind) foreground alpha at \(percent)%")
                    try check(!panel.ignoresMouseEvents,
                              "\(panel.overlayKind) remains interactive at \(percent)%")
                    try check(panel.hasShadow == (percent < 100),
                              "\(panel.overlayKind) shadow at \(percent)%")
                }
                try check(controller.window.alphaValue == 1 && !controller.window.ignoresMouseEvents,
                          "recovery window at \(percent)%")
                try check(overlays.allSatisfy { !$0.isVisible }, "opacity changes must not show hidden windows")
            }

            coordinator.appPreferences.setTransparency(50)
            for id in ["preferences-thread-a", "preferences-thread-b"] {
                let thread = CodexThread(id: id, projectID: nil, cwd: "/tmp", title: "Preferences fixture",
                                         preview: "", updatedAt: Date(), state: .idle, hasMessages: false)
                store.onWillOpenDetail?(thread, .centered)
                let panel = ownedOverlays().first { $0.representedThread?.id == id }
                try check(panel?.alphaValue == 1 && panel?.ignoresMouseEvents == false,
                          "new chat inherits transparency: \(id)")
                try check(panel?.isVisible == false, "preparing fixture chat must remain hidden")
            }
            try check(ownedOverlays().count == 6 && coordinator.openDetailWindowCount == 2,
                      "extra-chat allocation exercised")
            coordinator.appPreferences.setTransparency(100)
            try check(ownedOverlays().allSatisfy { $0.alphaValue == 1 && !$0.ignoresMouseEvents },
                      "all existing and new chats keep foreground and input at 100%")
            try check(AppPreferences(defaults: defaults).transparencyPercent == 100,
                      "100% survives restart without silently resetting")
            coordinator.appPreferences.resetTransparency()
            try check(ownedOverlays().allSatisfy { $0.alphaValue == 1 && !$0.ignoresMouseEvents },
                      "reset restores all panels and mouse input")

            var settingsRequests = 0
            var directions: [WindowDirection] = []
            let router = InputRouter(store: store, coordinator: coordinator,
                                     presentAppSettings: { settingsRequests += 1 },
                                     navigateWindow: { directions.append($0) })
            func key(_ code: UInt16, _ text: String, type: NSEvent.EventType = .keyDown,
                     modifiers: NSEvent.ModifierFlags = [], repeated: Bool = false,
                     window: NSWindow? = nil) -> NSEvent {
                NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                 windowNumber: (window ?? controller.window).windowNumber, context: nil,
                                 characters: text, charactersIgnoringModifiers: text,
                                 isARepeat: repeated, keyCode: code)!
            }
            let initialComposer = store.composerText
            let initialWriting = store.composerVisible
            let initialThreadID = store.detailThread?.id
            let initialRoute = store.leftRoute
            let initialOverrides = store.activeOverrides
            let initialSettingsRow = store.settingsRow
            let prefs = coordinator.appPreferences
            try check(router.handle(key(7, "x", modifiers: .command)) == nil && settingsRequests == 1,
                      "Cmd+X requests application settings")
            try check(router.handle(key(7, "x", modifiers: .command, repeated: true)) == nil
                      && settingsRequests == 1, "held Cmd+X does not repeatedly open settings")
            for (code, letter) in [(UInt16(13), "w"), (0, "a"), (1, "s"), (2, "d")] {
                try check(router.handle(key(code, letter.uppercased(), modifiers: .shift)) == nil,
                          "Shift+\(letter) routes window navigation")
            }
            try check(directions == [.up, .left, .down, .right], "Shift WASD maps all four directions")
            for (code, letter) in [(UInt16(13), "w"), (1, "s"), (2, "d"), (125, "")] {
                let oldShortcut = key(code, letter, modifiers: .command)
                try check(router.handle(oldShortcut) === oldShortcut && settingsRequests == 1,
                          "old Command direction shortcut passes through")
            }
            try check(directions.count == 4, "old Command shortcuts never navigate")
            let shiftedSettings = key(7, "x", modifiers: [.command, .shift])
            try check(router.handle(shiftedSettings) === shiftedSettings && settingsRequests == 1,
                      "Shift+Cmd+X must not match Cmd+X")
            let editorWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                                        styleMask: [.borderless], backing: .buffered, defer: false)
            editorWindow.isReleasedWhenClosed = false
            let editor = NSTextView(frame: .zero)
            editor.string = "Unsent message fixture"
            editorWindow.contentView = editor
            editorWindow.makeFirstResponder(editor)
            for (code, letter) in [(UInt16(13), "W"), (0, "A"), (1, "S"), (2, "D")] {
                let uppercase = key(code, letter, modifiers: .shift, window: editorWindow)
                try check(router.handle(uppercase) === uppercase && directions.count == 4,
                          "uppercase \(letter) remains editable text")
            }
            try check(router.handle(key(0, "a", modifiers: .command, window: editorWindow)) == nil
                      && editor.selectedRange().length == editor.string.utf16.count && directions.count == 4,
                      "Cmd+A selects draft without navigating")
            let typedS = key(1, "s", window: editorWindow)
            try check(router.handle(typedS) === typedS && settingsRequests == 1,
                      "ordinary typed S must not open settings")
            let typedX = key(7, "x", window: editorWindow)
            try check(router.handle(typedX) === typedX && settingsRequests == 1,
                      "ordinary typed X must not open settings")
            try check(router.handle(key(7, "x", modifiers: .command, window: editorWindow)) == nil
                      && settingsRequests == 2 && editor.string == "Unsent message fixture",
                      "Cmd+X opens settings from native text input without cutting its draft")
            try check(key(1, "s").window === controller.window, "synthetic events target hidden settings")
            try check(router.handle(key(1, "s")) == nil && prefs.selectedIndex == 1,
                      "settings S routed locally")
            try check(router.handle(key(49, " ")) == nil && prefs.page == .appearance,
                      "settings Space opens appearance")
            try check(router.handle(key(49, " ", type: .keyUp)) == nil,
                      "settings owns matching Space release")
            try check(router.handle(key(1, "s")) == nil && prefs.transparencyPercent == 5,
                      "appearance S increases transparency")
            try check(router.handle(key(124, "")) == nil && prefs.transparencyPercent == 6,
                      "appearance right arrow adjusts by one")
            try check(router.handle(key(123, "")) == nil && prefs.transparencyPercent == 5,
                      "appearance left arrow adjusts by one")
            try check(router.handle(key(13, "w")) == nil && prefs.transparencyPercent == 0,
                      "appearance W decreases transparency")
            prefs.setTransparency(75)
            try check(router.handle(key(49, " ", repeated: true)) == nil && prefs.transparencyPercent == 75,
                      "held Space must not repeat reset")
            try check(router.handle(key(49, " ")) == nil && prefs.transparencyPercent == 0,
                      "appearance Space resets transparency")
            try check(router.handle(key(12, "q", repeated: true)) == nil && prefs.page == .appearance,
                      "held Q must not skip pages")
            try check(router.handle(key(12, "q")) == nil && prefs.page == .home && prefs.selectedIndex == 1,
                      "appearance Q returns without closing")
            try check(router.handle(key(13, "w")) == nil && prefs.selectedIndex == 0,
                      "home W selects shortcuts")
            try check(router.handle(key(36, "\r")) == nil && prefs.page == .shortcuts,
                      "Enter opens selected settings page without composer")
            try check(router.handle(key(1, "s")) == nil && prefs.selectedIndex == 1,
                      "shortcuts keyboard selection")
            try check(router.handle(key(53, "\u{1b}")) == nil && prefs.page == .shortcuts,
                      "Escape must not close settings")
            let modified = key(1, "s", modifiers: .control)
            try check(router.handle(modified) === modified && prefs.selectedIndex == 1,
                      "modified keys must not become settings navigation")
            try check(router.handle(key(12, "q")) == nil && prefs.page == .home,
                      "shortcuts Q returns without closing")
            try check(store.composerText == initialComposer && store.composerVisible == initialWriting
                      && store.detailThread?.id == initialThreadID && store.leftRoute == initialRoute,
                      "settings navigation must not mutate chat/composer/project state")
            try check(store.activeOverrides == initialOverrides && store.settingsRow == initialSettingsRow,
                      "Cmd+X and app appearance must not mutate Cmd+4 model settings")

            guard let menuItem = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.keyEquivalent == "x" }) else {
                throw Failure(message: "native macOS settings menu missing")
            }
            try check(menuItem.action == #selector(BavbavAppDelegate.showAppSettings(_:))
                      && menuItem.keyEquivalentModifierMask == .command,
                      "native Cmd+X menu binding")
            try check(menuItem.target as AnyObject? === NSApp.delegate as AnyObject?,
                      "native settings menu targets app delegate")

            if let path = ProcessInfo.processInfo.environment["BAVBAV_PREFERENCES_SNAPSHOT_DIR"] {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                controller.position(in: screen)
                for (name, page) in [("home", AppPreferencesPage.home), ("appearance", .appearance), ("shortcuts", .shortcuts)] {
                    prefs.page = page
                    prefs.selectedIndex = 0
                    prefs.setTransparency(50)
                    guard let content = controller.window.contentView else { throw Failure(message: "snapshot content missing") }
                    content.layoutSubtreeIfNeeded()
                    content.displayIfNeeded()
                    guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
                        throw Failure(message: "snapshot bitmap unavailable")
                    }
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    guard let data = bitmap.representation(using: .png, properties: [:]) else {
                        throw Failure(message: "snapshot encoding failed")
                    }
                    try data.write(to: directory.appendingPathComponent("settings-\(name).png"))
                }
            }
            try check(!coordinator.hasVisibleWindows && ownedOverlays().allSatisfy { !$0.isVisible }
                      && !controller.window.isVisible, "entire check must leave all windows hidden")
            try check(coordinator.allWindowsUseNormalLevel, "window stacking regression")
            for opacity in [1.0, 0.5, 0.0] {
                let fixture = ZStack(alignment: .topLeading) {
                    Color.blue.panelBackdrop()
                    Rectangle().fill(Color.white).frame(width: 6)
                    Rectangle().fill(Color.green).frame(width: 12, height: 12).offset(x: 16, y: 10)
                    Text("TEXT").foregroundStyle(.white).offset(x: 36, y: 10)
                }.frame(width: 120, height: 80).environment(\.panelBackdropOpacity, opacity)
                let renderer = ImageRenderer(content: fixture)
                renderer.scale = 1
                guard let image = renderer.cgImage else { throw Failure(message: "background fixture render failed") }
                let bitmap = NSBitmapImageRep(cgImage: image)
                try check(abs((bitmap.colorAt(x: 80, y: 60)?.alphaComponent ?? -1) - opacity) < 0.02,
                          "rendered background pixels fade at \(opacity)")
                try check((bitmap.colorAt(x: 3, y: 40)?.alphaComponent ?? 0) > 0.99,
                          "rendered line stays opaque at \(opacity)")
                try check((bitmap.colorAt(x: 20, y: 15)?.alphaComponent ?? 0) > 0.99,
                          "rendered icon stays opaque at \(opacity)")
                var textPixels = 0
                for y in 8..<30 { for x in 36..<100 {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       color.redComponent > 0.95, color.greenComponent > 0.95, color.alphaComponent > 0.95 { textPixels += 1 }
                } }
                try check(textPixels > 8, "rendered text remains visible at \(opacity)")
            }
            let document = RichMessageRenderer.render("hello `code`\n\n| A | B |\n|---|---|\n| one | two |", fontSize: 12, width: 400, markdown: true)
            let faded = document.textWithBackgroundOpacity(0)
            try check(faded.string == document.text.string, "background adjustment preserves rich text")
            var coloredBackgrounds = 0
            document.text.enumerateAttributes(in: NSRange(location: 0, length: document.text.length)) { attrs, range, _ in
                if let color = attrs[.backgroundColor] as? NSColor, color.alphaComponent > 0 {
                    coloredBackgrounds += 1
                    if (faded.attribute(.backgroundColor, at: range.location, effectiveRange: nil) as? NSColor)?.alphaComponent != 0 { coloredBackgrounds = -100 }
                }
            }
            try check(coloredBackgrounds > 0, "inline code background fades without changing cached document")
            print("BAVBAV PREFERENCES CHECK PASSED: \(checks) checks; background-only opacity, foreground pixel checks, input at 100%, hidden/new chats, persistence, keyboard isolation; no foreground activation")
            return true
        } catch {
            fputs("BAVBAV PREFERENCES CHECK FAILED: \((error as? Failure)?.message ?? error.localizedDescription)\n", stderr)
            return false
        }
    }
}
