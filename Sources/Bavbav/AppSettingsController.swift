import AppKit
import SwiftUI

final class AppSettingsPanel: NSPanel, CornerResizeCommitHandler {
    var onResize: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    func cornerResizeDidFinish() { onResize?() }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 320),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        title = "Bavbav Settings"
        isFloatingPanel = false
        level = .normal
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.moveToActiveSpace]
        isMovableByWindowBackground = true
        becomesKeyOnlyIfNeeded = false
        minSize = NSSize(width: 300, height: 280)
    }
}

/// App-wide settings are deliberately independent of Cmd+4's per-chat model
/// settings. Only background fills fade; controls always remain visible.
@MainActor
final class AppSettingsController {
    let window = AppSettingsPanel()
    let preferences: AppPreferences
    var onCloseWithoutReturnWindow: (() -> Void)?
    private weak var returnWindow: NSWindow?
    private let defaults: UserDefaults

    init(preferences: AppPreferences, defaults: UserDefaults) {
        self.preferences = preferences
        self.defaults = defaults
        let container = CornerResizeContainer(frame: NSRect(origin: .zero, size: window.frame.size))
        container.setContent(NSHostingView(rootView: PanelAppearanceRoot(preferences: preferences, content: AppPreferencesView(preferences: preferences))))
        window.contentView = container
        window.onResize = { [weak self] in
            guard let self else { return }
            self.defaults.set([Double(self.window.frame.width), Double(self.window.frame.height)], forKey: "window-size.app-settings")
        }
    }

    static func frame(in visibleFrame: NSRect, size: NSSize = NSSize(width: 360, height: 320)) -> NSRect {
        let width = min(size.width, max(1, visibleFrame.width - 28))
        let height = min(size.height, max(1, visibleFrame.height - 28))
        return NSRect(x: visibleFrame.midX - width / 2, y: visibleFrame.maxY - 14 - height,
                      width: width, height: height)
    }

    func position(in visibleFrame: NSRect) {
        var size = NSSize(width: 360, height: 320)
        if let saved = defaults.array(forKey: "window-size.app-settings") as? [Double], saved.count == 2,
           saved.allSatisfy({ $0.isFinite && $0 > 0 }) {
            size = NSSize(width: max(300, saved[0]), height: max(280, saved[1]))
        }
        window.setFrame(Self.frame(in: visibleFrame, size: size), display: false)
    }

    func show(in visibleFrame: NSRect) {
        if !window.isKeyWindow, let previous = NSApp.keyWindow, previous !== window {
            returnWindow = previous
        }
        if !window.isVisible { position(in: visibleFrame) }
        window.alphaValue = 1
        window.ignoresMouseEvents = false
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        preferences.keyBindings.cancelEditing()
        window.orderOut(nil)
        if let previous = returnWindow, previous.isVisible, previous.alphaValue > 0 {
            previous.makeKeyAndOrderFront(nil)
        } else {
            onCloseWithoutReturnWindow?()
        }
        returnWindow = nil
    }

    @discardableResult
    func handleKey(_ event: NSEvent) -> Bool {
        guard let definition = preferences.keyBindings.single(event, scope: shortcutScope) else { return event.keyCode == 53 }
        if event.type == .keyDown && (!event.isARepeat || definition.repeating) { perform(definition.operation) }
        return true
    }
    var shortcutScope: String {
        if preferences.keyBindings.editingID != nil { return "prefs.confirm" }
        switch preferences.page {
        case .home: return "prefs.home"
        case .shortcuts: return "prefs.shortcuts"
        case .appearance: return "prefs.appearance"
        }
    }
    func perform(_ operation: String) {
        switch operation {
        case "up": preferences.moveSelection(delta: -1)
        case "down": preferences.moveSelection(delta: 1)
        case "less5": preferences.adjustTransparency(delta: -5)
        case "more5": preferences.adjustTransparency(delta: 5)
        case "less1": preferences.adjustTransparency(delta: -1)
        case "more1": preferences.adjustTransparency(delta: 1)
        case "resetAppearance": preferences.resetTransparency()
        case "activatePreference":
            window.makeFirstResponder(nil)
            preferences.activateSelection()
        case "backPreference": if !preferences.goBack() { close() }
        case "searchShortcuts": NotificationCenter.default.post(name: .shortcutSearchRequested, object: preferences)
        case "finishSearch": window.makeFirstResponder(nil)
        case "applyShortcut": _ = preferences.keyBindings.applyCandidate()
        case "cancelShortcut": preferences.keyBindings.cancelEditing()
        case "recordShortcut": preferences.keyBindings.recordAgain()
        case "disableShortcut", "resetShortcut":
            let bindings = preferences.keyBindings
            if let id = bindings.editingID, let definition = ShortcutCatalog.all.first(where: { $0.id == id }) {
                var value = bindings.binding(definition); value.disabled = true
                if bindings.set(id, operation == "resetShortcut" ? nil : value) { bindings.cancelEditing() }
            }
        case "shorterHold", "longerHold":
            if preferences.keyBindings.candidate?.hold == true {
                let old = preferences.keyBindings.candidate?.holdMilliseconds ?? 440
                preferences.keyBindings.candidate?.holdMilliseconds = min(2000,max(200,old + (operation == "shorterHold" ? -20 : 20)))
            }
        default: break
        }
    }
}
