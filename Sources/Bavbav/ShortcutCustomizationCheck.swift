import AppKit
import BavbavCore
import SwiftUI

@MainActor
enum ShortcutCustomizationCheck {
    private struct Failure: Error { let message: String }
    static func run() async -> Bool {
        guard ProcessInfo.processInfo.environment["BAVBAV_CODEX_BIN"]?.hasSuffix("BavbavFakeCodex") == true else {
            print("SHORTCUT CHECK REQUIRES LOCAL FAKE SERVER"); return false
        }
        let suite = "Bavbav.ShortcutCheck.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let baseline = Set(NSApp.windows.map(ObjectIdentifier.init))
        let originalMenu = NSApp.mainMenu
        let store = OverlayStore(defaults: defaults, standaloneDirectory: directory)
        let panels = PanelCoordinator(store: store, windowSizeDefaults: defaults)
        store.onOpenDetail = nil; store.onWillOpenDetail = nil
        var requests = 0
        var directions: [WindowDirection] = []
        let router = InputRouter(store: store, coordinator: panels, presentAppSettings: { requests += 1 },
                                 navigateWindow: { directions.append($0) })
        let bindings = panels.appPreferences.keyBindings
        let prefs = panels.appPreferences
        let settings = panels.appSettings.window
        let project = OverlayPanel(kind: .projects, contentRect: .zero)
        let recent = OverlayPanel(kind: .recents, contentRect: .zero)
        let chat = OverlayPanel(kind: .detail, contentRect: NSRect(x: 0, y: 0, width: 600, height: 400))
        let calendar = panels.journalWindow.window
        defer {
            router.cancelPendingPress()
            bindings.cancelEditing()
            NSApp.mainMenu = originalMenu
            for window in NSApp.windows where !baseline.contains(ObjectIdentifier(window)) { window.orderOut(nil) }
            defaults.removePersistentDomain(forName: suite)
            // No user files: this UUID directory belongs only to this fixture.
            try? FileManager.default.removeItem(at: directory)
        }
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            checks += 1
            if !condition() { throw Failure(message: message) }
        }
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], window: NSWindow? = nil,
                 type: NSEvent.EventType = .keyDown, repeated: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: (window ?? settings).windowNumber, context: nil,
                characters: ShortcutStroke(code).menuKey, charactersIgnoringModifiers: ShortcutStroke(code).menuKey,
                isARepeat: repeated, keyCode: code)!
        }
        func tap(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], window: NSWindow? = nil) {
            _ = router.handle(key(code, flags, window: window))
            _ = router.handle(key(code, flags, window: window, type: .keyUp))
        }
        func set(_ id: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) throws {
            try check(bindings.set(id, .init(strokes: [.init(code, flags)])), "set \(id): \(bindings.error ?? "")")
        }
        func settle(_ condition: () -> Bool) async {
            for _ in 0..<120 {
                if condition() { return }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        do {
            let catalog = ShortcutCatalog.all
            try check(catalog.count > 150, "granular action catalog")
            try check(Set(catalog.map(\.id)).count == catalog.count, "stable unique IDs")
            for definition in catalog {
                try check(bindings.validationError(id: definition.id, binding: definition.defaultBinding) == nil,
                          "default conflict \(definition.id): \(bindings.validationError(id: definition.id, binding: definition.defaultBinding) ?? "")")
                try check(!definition.title.contains("/"), "no grouped actions: \(definition.id)")
                var disabled = definition.defaultBinding; disabled.disabled = true
                try check(bindings.set(definition.id, disabled), "every individual binding can be disabled")
                try check(!bindings.matches(scope: definition.scope, text: true).contains { $0.id == definition.id }, "disabled cannot match")
                try check(bindings.set(definition.id, nil), "individual reset")
            }
            try set("projects.root.up.key", 40)
            try check(bindings.label("projects.root.up.arrow") == "↑" && bindings.label("projects.chats.up.key") == "W",
                      "alias and other panel independent")
            let saved = defaults.data(forKey: ShortcutSettings.storageKey)
            try check(!bindings.set("projects.root.up.key", .init(strokes: [.init(1)])), "same-context conflict rejected")
            try check(defaults.data(forKey: ShortcutSettings.storageKey) == saved, "conflict never writes")
            try check(ShortcutSettings(defaults: defaults).label("projects.root.up.key") == "K", "reload durable customization")
            try check(!bindings.set("*.projects.key", .init(strokes: [.init(48,.command)])), "system app switcher reserved")
            try check(!bindings.set("*.projects.key", .init(strokes: [.init(6)])), "global plain letter rejected")
            try check(!bindings.set("chat.write.full.send.key", .init(strokes: [.init(12)])), "ordinary typing cannot send")
            try check(!bindings.set("chat.read.close.key", .init(strokes: [.init(7,.command),.init(12)])), "app command prefix cannot be stolen")
            let old = bindings.overrides
            bindings.validateExternal = { _ in throw Failure(message: "simulated global registration failure") }
            try check(!bindings.set("*.projects.key", .init(strokes: [.init(18,[.command,.control])])), "external registration checked")
            try check(bindings.overrides == old && defaults.data(forKey: ShortcutSettings.storageKey) == saved, "external failure rolls back")
            bindings.validateExternal = nil
            try check(bindings.resetAll(), "reset all")
            try check(bindings.overrides.isEmpty, "reset only clears custom bindings")
            // Real Carbon registration QA without taking any of the user's
            // existing Cmd+1...5 bindings or injecting input/activating windows.
            var off: [String: ShortcutBinding] = [:]
            for definition in catalog where definition.global {
                var value = definition.defaultBinding; value.disabled = true; off[definition.id] = value
                try check(bindings.set(definition.id,value), "isolate global registration fixture")
            }
            do {
                let center = try HotKeyCenter(bindings:bindings) { _ in }
                let blocker = try HotKeyCenter(bindings:bindings) { _ in }
                let flags: NSEvent.ModifierFlags = [.command,.control,.option]
                var initial = off; initial["*.projects.key"] = .init(strokes:[.init(80,flags)]) // F19
                var occupied = off; occupied["*.recents.key"] = .init(strokes:[.init(79,flags)]) // F18
                try center.reconfigure(initial)
                try center.setSuspended(true); try center.setSuspended(false)
                try blocker.reconfigure(occupied)
                var next = off
                next["*.projects.key"] = .init(strokes:[.init(64,flags)]) // F17
                next["*.recents.key"] = .init(strokes:[.init(79,flags)])
                var rejected = false
                do { try center.reconfigure(next) } catch { rejected = true }
                try check(rejected, "real Carbon detects existing binding")
                try blocker.reconfigure(off)
                rejected = false
                do { try blocker.reconfigure(initial) } catch { rejected = true }
                try check(rejected, "failed transaction restores old Carbon registration")
                try center.reconfigure(off)
                try blocker.reconfigure(initial)
                try blocker.reconfigure(off)
                try check(true, "real Carbon remap suspend resume unregister and rollback")
            }
            _ = bindings.resetAll()

            var captureStates: [Bool] = []
            bindings.onRecordingChanged = { captureStates.append($0) }
            bindings.beginRecording("*.projects.key")
            tap(18,[.command,.control])
            try check(!bindings.recording && bindings.candidate?.strokes == [.init(18,[.command,.control])], "global shortcut captured locally")
            try check(bindings.overrides.isEmpty, "capture requires explicit confirmation")
            tap(36)
            try check(bindings.editingID == nil && bindings.label("*.projects.key") == "⌃⌘1", "Enter confirms recording")
            try check(captureStates == [true,false], "global registrations suspended exactly during capture")
            try check(HotKeyCenter.configuration(bindings.overrides)[1] == .init(18,[.command,.control]), "Carbon gets edited binding")
            try check(HotKeyCenter.carbonModifiers(.init(18,[.command,.shift])) != HotKeyCenter.carbonModifiers(.init(18,.command)),
                      "Carbon preserves modifier mask")
            _ = bindings.resetAll()
            bindings.beginRecording("projects.root.create.key")
            _ = router.handle(key(3))
            _ = router.handle(key(36))
            _ = router.handle(key(36,type:.keyUp))
            try check(bindings.recording, "chord waits for all keys released")
            _ = router.handle(key(3,type:.keyUp))
            try check(bindings.candidate?.strokes == [.init(3),.init(36)], "two-key chord preserved")
            tap(36)
            try check(bindings.label("projects.root.create.key") == "F + ENTER", "chord committed")
            bindings.beginRecording("projects.root.close.key")
            tap(12)
            try check(bindings.candidate?.strokes == [.init(12)] && bindings.editingID != nil, "Q is recordable, not premature cancel")
            tap(12)
            try check(bindings.editingID == nil, "Q cancels preview without changing binding")
            bindings.beginRecording("projects.root.close.key")
            tap(36)
            try check(bindings.candidate?.strokes == [.init(36)], "Enter recordable")
            tap(12)
            bindings.beginRecording("projects.root.close.key")
            let switcher = key(48,.command)
            try check(router.handle(switcher) === switcher && bindings.editingID == nil, "Cmd Tab exits capture natively")
            _ = bindings.resetAll()

            try set("*.preferences.key", 7,[.command,.control])
            let oldSettings = key(7,.command)
            try check(router.handle(oldSettings) === oldSettings && requests == 0, "old settings shortcut removed")
            tap(7,[.command,.control])
            try check(requests == 1, "new settings shortcut runs")
            try set("*read.focusUp.key", 40,.shift)
            tap(13,.shift)
            try check(directions.isEmpty, "old direction removed")
            tap(40,.shift)
            try check(directions == [.up], "new direction")
            let editor = NSTextView(frame: NSRect(x: 0,y: 0,width: 250,height: 100))
            editor.string = "Typed W S Q"
            let textWindow = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
            textWindow.isReleasedWhenClosed = false; textWindow.contentView = editor; textWindow.makeFirstResponder(editor)
            let uppercase = key(40,.shift,window:textWindow)
            try check(router.handle(uppercase) === uppercase && directions.count == 1, "modified direction remains uppercase text")
            try set("*text.selectAll.key", 0,[.command,.control])
            tap(0,.command,window:textWindow)
            try check(editor.selectedRange().length == 0, "old native select-all blocked")
            tap(0,[.command,.control],window:textWindow)
            try check(editor.selectedRange().length == editor.string.utf16.count, "new select-all selects native Unicode text")
            ApplicationMenu.install(bindings: bindings)
            let appMenu = NSApp.mainMenu!.items[0].submenu!
            let menuSettings = appMenu.items.first { $0.action == #selector(BavbavAppDelegate.showAppSettings(_:)) }!
            try check(menuSettings.keyEquivalentModifierMask == [.command,.control], "menu uses same edited binding")
            let editMenu = NSApp.mainMenu!.items[1].submenu!
            try check(editMenu.items.first { $0.action == #selector(NSText.selectAll(_:)) }?.keyEquivalentModifierMask == [.command,.control],
                      "native clipboard menu synchronized")
            _ = bindings.resetAll()

            prefs.page = .shortcuts; prefs.selectedIndex = 0
            try set("prefs.shortcuts.down.key", 38)
            tap(1)
            try check(prefs.selectedIndex == 0, "old settings navigation removed")
            tap(38)
            try check(prefs.selectedIndex == 1, "new settings navigation")
            tap(125)
            try check(prefs.selectedIndex == 2, "independent arrow alias remains")
            prefs.shortcutSearch = "empty composer"
            try check(!prefs.filteredShortcuts.isEmpty && prefs.selectedIndex == 0, "search individual actions")
            prefs.shortcutSearch = ""
            _ = bindings.resetAll()
            prefs.page = .appearance
            try set("prefs.appearance.more1.key", 3)
            tap(3)
            try check(prefs.transparencyPercent == 1, "appearance remap applies real setting")
            tap(124)
            try check(prefs.transparencyPercent == 1, "old appearance key removed")
            prefs.setTransparency(0)
            try set("calendar.month.nextMonth.key", 38)
            let journalNav = panels.journalWindow.navigation
            let date = journalNav.selectedDate
            tap(2,window:calendar)
            try check(journalNav.selectedDate == date, "old calendar month key removed")
            tap(38,window:calendar)
            try check(journalNav.selectedDate != date, "new calendar month key")
            try check(bindings.label("calendar.day.nextMonth.key") == "D", "calendar pages independent")
            _ = bindings.resetAll()

            // Exercise real store transitions against only the local fixture server.
            await store.connectAndLoad()
            try set("projects.root.create.key", 3,[.command,.control])
            tap(3,[.command,.control],window:project)
            try check(store.leftCreationTarget == .project, "remapped project creation starts name slot")
            try set("create.project.empty.commitCreation.key", 36,.command)
            tap(36,window:project)
            try check(store.leftCreationActive, "old native Enter cannot submit remapped name slot")
            tap(36,.command,window:project)
            try check(!store.leftCreationActive, "new empty-name cancel")
            _ = bindings.resetAll()
            _ = router.handle(key(49,window:project))
            _ = router.handle(key(36,window:project))
            try check(router.handle(key(49,window:project,repeated:true)) == nil && store.leftCreationName.isEmpty,
                      "held chord prefix cannot type repeated spaces into new name slot")
            _ = router.handle(key(36,window:project,type:.keyUp))
            _ = router.handle(key(49,window:project,type:.keyUp))
            try check(store.leftCreationActive, "default chord still creates")
            tap(36,window:project)
            try check(!store.leftCreationActive, "default empty Enter cancels")
            try check(store.recentChats.count > 0, "recent fixture populated")
            store.recentInteraction.selectedID = store.recentChats.first?.id
            var reorder = ShortcutBinding(strokes:[.init(3,.control)], hold:true, holdMilliseconds:200)
            try check(bindings.set("recents.list.reorder.key",reorder), "hold key remapped independently")
            _ = router.handle(key(3,.control,window:recent))
            await settle { store.recentIsReordering }
            try check(store.recentIsReordering, "custom hold enters actual reorder")
            _ = router.handle(key(3,window:recent,type:.keyUp))
            try check(store.recentIsReordering, "modifier release before key-up keeps correct long hold")
            tap(49,window:recent)
            try check(!store.recentIsReordering, "independent commit key")
            _ = router.handle(key(3,.control,window:recent))
            router.cancelPendingPress(); router.triggerHold()
            try check(!store.recentIsReordering && store.recentInteraction.mode == .browsing, "focus loss cancels pending hold without activation")
            _ = router.handle(key(3,.control,window:recent))
            reorder.holdMilliseconds = 500
            try check(bindings.set("recents.list.reorder.key",reorder), "hold delay persists")
            router.triggerHold()
            try check(!store.recentIsReordering && store.recentInteraction.mode == .browsing, "editing bindings cancels armed timer")
            _ = bindings.resetAll()

            bindings.beginRecording("projects.root.create.key")
            for code: UInt16 in [3,5,14] { _ = router.handle(key(code)) }
            for code: UInt16 in [3,5,14] { _ = router.handle(key(code,type:.keyUp)) }
            try check(!bindings.recording && !bindings.applyCandidate(), "three-key capture cannot silently commit two keys")
            bindings.cancelEditing()
            bindings.beginRecording("projects.root.close.key")
            tap(3)
            tap(15)
            try check(bindings.recording, "preview recorder fully keyboard accessible")
            tap(3)
            tap(2)
            try check(bindings.label("projects.root.close.key") == "DISABLED", "disable via configurable preview key")
            _ = bindings.resetAll()

            let thread = CodexThread(id:"fixture-thread",projectID:nil,cwd:"/tmp/fixture",title:"Shortcut fixture",
                                     preview:"",updatedAt:Date(),state:.idle,hasMessages:true)
            chat.representedThread = thread
            store.focusDetailWindow(thread)
            await settle { !store.detailLoading }
            try set("chat.read.write.key", 14)
            tap(36,window:chat)
            try check(!store.composerVisible, "old Enter cannot open composer")
            tap(14,window:chat)
            try check(store.composerVisible, "custom open composer")
            try set("chat.write.empty.send.key", 36,.command)
            tap(36,window:chat)
            try check(store.composerVisible, "empty-close independently remapped")
            tap(36,.command,window:chat)
            try check(!store.composerVisible, "custom empty-close closes only writing")
            try check(store.detailThread?.id == thread.id, "empty-close keeps conversation open")
            tap(14,window:chat)
            store.composerText = "ECHO"
            try set("chat.write.full.send.key",36,[.command,.control])
            let oldSend = key(36,window:chat)
            try check(router.handle(oldSend) === oldSend && !store.messageSending && store.composerText == "ECHO",
                      "old send no longer submits")
            tap(36,[.command,.control],window:chat)
            await settle { !store.messageSending && store.visibleDetailItems.contains { $0.text == "BAVBAV_ECHO_OK" } }
            try check(store.visibleDetailItems.filter { $0.text == "ECHO" }.count == 1, "custom send exactly one prompt")
            try check(store.visibleDetailItems.filter { $0.text == "BAVBAV_ECHO_OK" }.count == 1, "custom send receives one reply")
            store.cancelWriting()
            try set("chat.read.commands.key", 17)
            let before = store.detailShowsActivity
            tap(48,.shift,window:chat)
            try check(store.detailShowsActivity == before, "old command visibility shortcut removed")
            tap(17,window:chat)
            try check(store.detailShowsActivity != before, "new command visibility shortcut")
            tap(14,window:chat)
            let beforeWriting = store.detailShowsActivity
            tap(48,.shift,window:chat)
            try check(store.detailShowsActivity != beforeWriting, "writing scope visibility independent")
            store.cancelWriting()
            _ = bindings.resetAll()
            try check(!panels.hasVisibleWindows && [settings, project, recent, chat, calendar].allSatisfy { !$0.isVisible },
                      "no fixture window shown or foreground activation")

            defaults.set(Data("broken".utf8), forKey:ShortcutSettings.storageKey)
            let broken = ShortcutSettings(defaults:defaults)
            try check(broken.overrides.isEmpty && broken.error != nil, "corrupt preferences safely fall back")
            try check(defaults.data(forKey:ShortcutSettings.storageKey) == Data("broken".utf8), "corrupt record retained until explicit edit")
            _ = bindings.resetAll()
            if let path = ProcessInfo.processInfo.environment["BAVBAV_SHORTCUT_SNAPSHOT_DIR"] {
                let target = URL(fileURLWithPath:path,isDirectory:true)
                try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
                prefs.page = .shortcuts
                settings.setContentSize(NSSize(width:440,height:520))
                for mode in ["list","record","preview","conflict"] {
                    if mode == "record" { bindings.beginRecording("projects.root.create.key") }
                    if mode == "preview" { tap(3); }
                    if mode == "conflict" {
                        bindings.beginRecording("projects.root.up.key"); tap(1); _ = bindings.applyCandidate()
                    }
                    // Let SwiftUI's deferred observable updates lay out before capture.
                    try? await Task.sleep(nanoseconds:100_000_000)
                    guard let view = settings.contentView else { throw Failure(message:"snapshot view") }
                    view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw Failure(message:"snapshot bitmap") }
                    view.cacheDisplay(in:view.bounds,to:bitmap)
                    guard let data = bitmap.representation(using:.png,properties:[:]) else { throw Failure(message:"snapshot PNG") }
                    try data.write(to:target.appendingPathComponent("shortcuts-\(mode).png"))
                }
            }
            bindings.cancelEditing()
            await store.shutdown()
            print("BAVBAV SHORTCUT CHECK PASSED: \(checks) checks; \(catalog.count) independent bindings, conflicts, persistence, capture, native menus/text, custom gestures, calendar, single fake-server send/reply; no user windows or global key injection")
            return true
        } catch {
            await store.shutdown()
            print("BAVBAV SHORTCUT CHECK FAILED after \(checks): \(error)")
            return false
        }
    }
}
