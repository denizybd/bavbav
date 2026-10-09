import AppKit

@MainActor
enum ApplicationMenu {
    static func install(bindings: ShortcutSettings? = nil) {
        let menu = NSMenu()
        let application = NSMenu(title: "Bavbav")
        let appItem = menu.addItem(withTitle: "Bavbav", action: nil, keyEquivalent: "")
        appItem.submenu = application
        application.addItem(withTitle: "About Bavbav", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        application.addItem(.separator())
        application.addItem(withTitle: "Hide Bavbav", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = application.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        application.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        application.addItem(.separator())
        application.addItem(withTitle: "Quit Bavbav", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        application.items.forEach { $0.target = NSApp }
        let settings = NSMenuItem(title: "Settings…", action: #selector(BavbavAppDelegate.showAppSettings(_:)), keyEquivalent: "x")
        settings.target = NSApp.delegate
        application.insertItem(settings, at: 1)
        let companion = NSMenuItem(title: "Companion · Ses ve ekran…", action: #selector(BavbavAppDelegate.showCompanion(_:)), keyEquivalent: "")
        companion.target = NSApp.delegate
        companion.representedObject = "*.companion.key"
        application.insertItem(companion, at: 2)

        let edit = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // Native AppKit key equivalents keep the six focus shortcuts available
        // from a text editor or an auxiliary window, not just Carbon hotkeys.
        let windows = NSMenu(title: "Windows")
        menu.addItem(withTitle: "Windows", action: nil, keyEquivalent: "").submenu = windows
        let panels: [(String, String, Selector)] = [
            ("Projects", "*.projects.key", #selector(BavbavAppDelegate.showProjects)),
            ("Recent Chats", "*.recents.key", #selector(BavbavAppDelegate.showRecents)),
            ("ChatGPT", "*.standalone.key", #selector(BavbavAppDelegate.showChatGPT)),
            ("Model and Effort", "*.models.key", #selector(BavbavAppDelegate.showSettings)),
            ("Calendar", "*.journal.key", #selector(BavbavAppDelegate.showJournal)),
            ("Companion · Ses ve ekran", "*.companion.key", #selector(BavbavAppDelegate.showCompanion(_:)))
        ]
        for (index, panel) in panels.enumerated() {
            let item = windows.addItem(withTitle: panel.0, action: panel.2, keyEquivalent: String(index + 1))
            item.target = NSApp.delegate
            item.representedObject = panel.1
            item.keyEquivalentModifierMask = [.command]
        }
        NSApp.windowsMenu = windows
        NSApp.mainMenu = menu
        if let bindings { update(menu, bindings: bindings) }
    }
    static func update(_ menu: NSMenu?, bindings: ShortcutSettings) {
        guard let menu else { return }
        for item in menu.items {
            if let submenu = item.submenu { update(submenu, bindings: bindings) }
            let id: String?
            switch item.action {
            case #selector(NSApplication.hide(_:)): id = "*.hide.key"
            case #selector(NSApplication.hideOtherApplications(_:)): id = "*.hideOthers.key"
            case #selector(NSApplication.terminate(_:)): id = "*.quit.key"
            case #selector(BavbavAppDelegate.showAppSettings(_:)): id = "*.preferences.key"
            case #selector(NSText.copy(_:)): id = "*text.copy.key"
            case #selector(NSText.paste(_:)): id = "*text.paste.key"
            case #selector(NSText.selectAll(_:)): id = "*text.selectAll.key"
            default: id = item.representedObject as? String
            }
            guard let id, let definition = ShortcutCatalog.all.first(where: { $0.id == id }) else { continue }
            let value = bindings.binding(definition)
            item.keyEquivalent = value.disabled ? "" : value.strokes.first?.menuKey ?? ""
            item.keyEquivalentModifierMask = value.strokes.first?.flags ?? []
        }
    }
}
