import AppKit

@MainActor
enum AppSwitchCheck {
    /// Check switcher prerequisites without activating another app, showing
    /// windows, injecting global keys or interrupting the user's session.
    static func run(router: InputRouter, panels: PanelCoordinator) -> Bool {
        guard NSApp.activationPolicy() == .regular,
              NSRunningApplication.current.activationPolicy == .regular,
              Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool != true,
              panels.allWindowsUseNormalLevel else {
            fputs("APP SWITCH CHECK FAILED: activation policy or bundle/window level\n", stderr)
            return false
        }
        let windows = NSApp.windows.compactMap { $0 as? OverlayPanel }
        guard windows.count >= 5,
              windows.allSatisfy({ $0.canBecomeKey && $0.canBecomeMain
                  && !$0.styleMask.contains(.nonactivatingPanel) && !$0.hidesOnDeactivate }) else {
            fputs("APP SWITCH CHECK FAILED: nonstandard window activation\n", stderr)
            return false
        }
        let before = panels.activePanel
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            for modifiers in [NSEvent.ModifierFlags.command, [.command, .shift]] {
                let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                                            timestamp: 0, windowNumber: windows[0].windowNumber, context: nil,
                                            characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
                guard router.handle(event) === event, panels.activePanel == before else {
                    fputs("APP SWITCH CHECK FAILED: Command-Tab intercepted\n", stderr)
                    return false
                }
            }
        }
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
              appMenu.items.contains(where: { $0.keyEquivalent == "h" && $0.action == #selector(NSApplication.hide(_:)) }),
              appMenu.items.contains(where: { $0.keyEquivalent == "q" && $0.action == #selector(NSApplication.terminate(_:)) }),
              windows.allSatisfy({ !$0.isVisible }) else {
            fputs("APP SWITCH CHECK FAILED: native menu or unexpected window activation\n", stderr)
            return false
        }
        print("BAVBAV APP SWITCH CHECK PASSED: regular app/Dock policy, activating main windows, normal levels, Cmd-Tab/Shift-Cmd-Tab pass-through, native Hide/Quit menu; no foreground switching performed")
        return true
    }
}
