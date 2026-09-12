import AppKit
import Combine
import WebKit

@MainActor
final class InputRouter {
    private weak var coordinator: PanelCoordinator?
    private let store: OverlayStore
    private let presentAppSettings: () -> Void
    private let navigateWindow: (WindowDirection) -> Void
    private let bindings: ShortcutSettings
    private var monitor: Any?
    private var subscription: AnyCancellable?
    private var longPressWork: DispatchWorkItem?
    private struct Press {
        let stroke: ShortcutStroke
        let windowNumber: Int
        let scope: String
        let panel: OverlayKind?
        let tap: ShortcutDefinition?
        let hold: ShortcutDefinition?
        let chords: [ShortcutDefinition]
        var started = false
        var held = false
    }
    private var press: Press?
    private var consumed: [UInt16: (Int, ShortcutStroke, Bool)] = [:]

    init(store: OverlayStore, coordinator: PanelCoordinator, presentAppSettings: (() -> Void)? = nil,
         navigateWindow: ((WindowDirection) -> Void)? = nil) {
        self.store = store; self.coordinator = coordinator
        bindings = coordinator.appPreferences.keyBindings
        self.presentAppSettings = presentAppSettings ?? { [weak coordinator] in coordinator?.showAppSettings() }
        self.navigateWindow = navigateWindow ?? { [weak coordinator] direction in _ = coordinator?.focusWindow(in: direction) }
        subscription = bindings.$overrides.dropFirst().sink { [weak self] _ in self?.cancelPendingPress() }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }
    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        longPressWork?.cancel()
    }
    func cancelPendingPress() {
        longPressWork?.cancel(); longPressWork = nil
        if let press, press.started {
            if press.scope.hasPrefix("queue.") { store.cancelQueueSpacePress(revert: true) }
            else if let panel = press.panel { store.cancelListPress(panel) }
        }
        press = nil
        consumed.removeAll()
    }
    func scope(for window: NSWindow?) -> String {
        if window is AppSettingsPanel {
            if bindings.editingID != nil { return "prefs.confirm" }
            if (window?.firstResponder as? NSTextView)?.isEditable == true { return "prefs.search" }
            return coordinator?.appSettings.shortcutScope ?? "prefs.home"
        }
        if window is JournalPanel { return coordinator?.journalWindow.shortcutScope ?? "calendar.month" }
        if let panel = (window as? OverlayPanel)?.overlayKind {
            if store.renameTarget?.panel == panel { return store.renameScope }
            if panel == .detail, store.composerVisible, store.composerToolsVisible {
                return store.composerGoalEditing ? "composer.goal.write" : "composer.tools"
            }
            if panel == .projects, store.leftCreationActive {
                let kind: String
                if case .project = store.leftCreationTarget { kind = "project" } else { kind = "chat" }
                return "create.\(kind)." + (store.leftCreationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "empty" : "full")
            }
            if store.isInteractionInputPresented(in: panel) { return "interaction.write" }
            if store.isComposerPresented(in: panel) {
                return "chat.write." + (store.composerHasPayload ? "full" : "empty")
            }
            if (window?.firstResponder as? NSTextView)?.isEditable == true { return "text.other" }
            if store.hasInteractionPresented(in: panel) { return "interaction.list" }
            switch panel {
            case .projects:
                return (store.leftRoute == .projects ? "projects.root" : "projects.chats") + (store.leftIsReordering ? ".moving" : "")
            case .recents: return "recents.list" + (store.recentIsReordering ? ".moving" : "")
            case .chatgpt:
                if store.chatGPTInteraction.selectedID == OverlayStore.chatGPTLauncherID { return "standalone.launcher" }
                return "standalone.list" + (store.chatGPTIsReordering ? ".moving" : "")
            case .settings: return !store.settingsIsChoosing ? "models.rows" : (store.settingsRow == .model ? "models.model" : "models.effort")
            case .detail: return store.queueModeVisible ? "queue.list" + (store.queueIsReordering ? ".moving" : "") : "chat.read"
            }
        }
        return (window?.firstResponder as? NSTextView)?.isEditable == true ? "text.other" : "other.read"
    }
    func handle(_ event: NSEvent) -> NSEvent? {
        let window = event.window ?? NSApp.keyWindow
        let number = window?.windowNumber ?? 0
        let stroke = ShortcutStroke(event)
        if event.keyCode == 48, event.modifierFlags.contains(.command) {
            cancelPendingPress(); bindings.cancelEditing(); return event
        }
        if window is AppSettingsPanel, bindings.recording {
            cancelPendingPress()
            bindings.capture(event)
            return nil
        }
        if let window, !(window is OverlayPanel), window.contentView is WKWebView { return event }
        let webFocused = store.chatGPTSession.hasWebFocus(in: window)
        if event.type == .keyDown, let panel = window as? OverlayPanel, panel.overlayKind == .detail,
           let thread = panel.representedThread, store.detailThread?.id != thread.id {
            store.focusDetailWindow(thread)
        }
        let scope = scope(for: window)
        let panel = (window as? OverlayPanel)?.overlayKind
        let text = window?.firstResponder as? NSTextView
        if text?.hasMarkedText() == true, !stroke.strongModifier { return event }
        let definitions = bindings.matches(scope: scope, text: text != nil || webFocused)
        if event.type == .keyUp {
            if let pending = press, pending.stroke.code == event.keyCode {
                guard pending.windowNumber == number else { cancelPendingPress(); return event }
                finishPress(window: window); consumed.removeValue(forKey: event.keyCode)
                return nil
            }
            if let old = consumed[event.keyCode], old.0 == number,
               old.1 == stroke || stroke.flags.isSubset(of: old.1.flags) {
                consumed.removeValue(forKey: event.keyCode); return nil
            }
            return event
        }
        guard event.type == .keyDown else { return event }
        // A held chord must not type into the name slot it has just opened.
        if event.isARepeat, let previous = consumed[event.keyCode], previous.0 == number, !previous.2 {
            return nil
        }
        if let pending = press {
            if pending.windowNumber != number { cancelPendingPress() }
            else if event.keyCode == pending.stroke.code { return nil }
            else if !pending.held, let chord = pending.chords.first(where: { bindings.binding($0).strokes.last == stroke }) {
                cancelPendingPress()
                consumed[event.keyCode] = (number, stroke, false)
                consumed[pending.stroke.code] = (number, pending.stroke, false)
                if !event.isARepeat { perform(chord, window: window, panel: panel) }
                return nil
            }
        }
        let candidates = definitions.filter { bindings.binding($0).strokes.first == stroke }
        let tap = candidates.first { bindings.binding($0).strokes.count == 1 && !bindings.binding($0).hold }
        let hold = candidates.first { bindings.binding($0).hold }
        let chords = candidates.filter { bindings.binding($0).strokes.count == 2 }
        if webFocused && candidates.allSatisfy({ $0.scope != "*" && $0.scope != "*text" }) { return event }
        if hold != nil || !chords.isEmpty {
            if event.isARepeat { return nil }
            cancelPendingPress()
            var pending = Press(stroke: stroke, windowNumber: number, scope: scope, panel: panel, tap: tap, hold: hold, chords: chords)
            if hold != nil, let panel {
                pending.started = scope.hasPrefix("queue.") ? store.beginQueueSpace() : store.beginSpace(panel)
            }
            press = pending
            if let hold, pending.started {
                let work = DispatchWorkItem { [weak self] in self?.triggerHold() }
                longPressWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(bindings.binding(hold).holdMilliseconds) / 1000, execute: work)
            }
            return nil
        }
        if let tap {
            if tap.operation != "up" && tap.operation != "down" { cancelPendingPress() }
            consumed[event.keyCode] = (number, stroke, tap.repeating)
            if !event.isARepeat || tap.repeating { perform(tap, window: window, panel: panel) }
            return nil
        }
        if [36,76].contains(event.keyCode), (scope.hasPrefix("create.") || scope.hasPrefix("rename.") || scope == "interaction.write" || scope == "calendar.write" || scope == "composer.goal.write") {
            return nil
        }
        if text != nil, let old = ShortcutCatalog.all.first(where: {
            $0.scope == "*text" && $0.defaultBinding.strokes == [stroke]
        }), bindings.binding(old) != old.defaultBinding { return nil }
        if event.keyCode == 53 && !ShortcutCatalog.writing(scope) { return nil }
        return event
    }
    func triggerHold() {
        guard var pending = press, pending.started, !pending.held, let panel = pending.panel else { return }
        pending.held = true; press = pending
        if pending.scope.hasPrefix("queue.") { store.crossQueueLongPressThreshold() }
        else { store.crossLongPressThreshold(panel) }
    }
    private func finishPress(window: NSWindow?) {
        guard let pending = press else { return }
        longPressWork?.cancel(); longPressWork = nil; press = nil
        if pending.held {
            if pending.scope.hasPrefix("queue.") { store.finishQueueSpace(longPressTriggered: true) }
        } else if let tap = pending.tap {
            if pending.started, let panel = pending.panel, tap.operation == "open" || tap.operation == "steer" {
                if pending.scope.hasPrefix("queue.") { store.finishQueueSpace(longPressTriggered: false) }
                else { store.releaseSpace(panel) }
            } else {
                if pending.started, let panel = pending.panel {
                    if pending.scope.hasPrefix("queue.") { store.cancelQueueSpacePress(revert: true) }
                    else { store.cancelListPress(panel) }
                }
                perform(tap, window: window, panel: pending.panel)
            }
        } else if pending.started, let panel = pending.panel {
            if pending.scope.hasPrefix("queue.") { store.cancelQueueSpacePress(revert: true) }
            else { store.cancelListPress(panel) }
        }
    }
    private func perform(_ definition: ShortcutDefinition, window: NSWindow?, panel: OverlayKind?) {
        let op = definition.operation
        if definition.scope.hasPrefix("prefs.") { coordinator?.appSettings.perform(op); return }
        if definition.scope.hasPrefix("calendar.") { coordinator?.journalWindow.perform(op); return }
        switch op {
        case "projects": coordinator?.showGroup(.projects)
        case "recents": coordinator?.showGroup(.recents)
        case "standalone": coordinator?.showGroup(.chatgpt)
        case "models": coordinator?.showGroup(.settings)
        case "journal": coordinator?.showJournal()
        case "preferences": presentAppSettings()
        case "hide": coordinator?.hideAll()
        case "hideOthers": NSApp.hideOtherApplications(nil)
        case "quit": NSApp.terminate(nil)
        case "refresh": Task { await store.refresh() }
        case "focusUp": navigateWindow(.up)
        case "focusLeft": navigateWindow(.left)
        case "focusDown": navigateWindow(.down)
        case "focusRight": navigateWindow(.right)
        case "focusUpLeft": navigateWindow(.upLeft)
        case "focusUpRight": navigateWindow(.upRight)
        case "focusDownLeft": navigateWindow(.downLeft)
        case "focusDownRight": navigateWindow(.downRight)
        case "selectAll", "copy", "paste":
            if let text = window?.firstResponder as? NSTextView {
                if op == "selectAll" { text.selectAll(nil) }
                else if op == "copy" { text.copy(nil) }
                else if text.isEditable { text.pasteAsPlainText(nil) }
            } else if store.chatGPTSession.hasWebFocus(in: window) {
                let selector = op == "selectAll" ? #selector(NSText.selectAll(_:)) :
                    (op == "copy" ? #selector(NSText.copy(_:)) : #selector(NSText.paste(_:)))
                _ = NSApp.sendAction(selector, to: nil, from: nil)
            }
        case "bottom": NotificationCenter.default.post(name: .chatJumpToBottom, object: window)
        case "commands": store.toggleDetailActivity()
        case "composerTools": store.toggleComposerTools()
        case "composerToolsClose": store.closeComposerTools()
        case "composerToolOpen": store.activateComposerTool()
        case "composerAttach": store.chooseComposerFiles()
        case "composerGoalSave": store.saveComposerGoal()
        case "composerGoalCancel": store.cancelComposerGoalEditing()
        case "composerGoalClear": store.clearComposerGoal()
        case "up", "down":
            let delta = op == "up" ? -1 : 1
            if definition.scope == "composer.tools" { store.navigateComposerTools(delta: delta) }
            else if definition.scope.hasPrefix("queue.") { store.navigateQueue(delta: delta) }
            else if definition.scope == "interaction.list" { store.navigateInteraction(delta: delta) }
            else if let panel { store.navigate(panel, delta: delta) }
        case "open": if let panel { store.activateSelection(panel) }
        case "write": if let panel { store.beginWriting(from: panel) }
        case "close": if let panel { coordinator?.dismiss(panel) }
        case "commitOrder": if let panel { _ = store.beginSpace(panel) }
        case "create": store.beginLeftCreation()
        case "commitCreation": store.commitLeftCreation()
        case "rename": if let panel { store.beginRename(in: panel) }
        case "commitRename": store.commitRename()
        case "cancelRename": store.cancelRename()
        case "send": store.submitMessage()
        case "newline": (window?.firstResponder as? NSTextView)?.insertNewline(nil)
        case "cancelWriting": store.cancelWriting()
        case "queueToggle": store.toggleQueueMode()
        case "steer": if store.beginQueueSpace() { store.finishQueueSpace(longPressTriggered: false) }
        case "editQueued":
            if store.queueInteraction.selectedID != nil { store.editSelectedQueuedPrompt() }
            else if let panel { coordinator?.dismiss(panel) }
        case "confirmInteraction": store.activateInteractionSelection()
        case "submitInteraction": store.submitInteractionText()
        case "cancelInteraction": store.cancelInteractionText()
        default: break
        }
    }
}
