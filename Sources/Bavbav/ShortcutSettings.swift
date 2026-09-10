import AppKit
import Combine

struct ShortcutStroke: Codable, Hashable {
    static let mask: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
    let code: UInt16
    let modifiers: UInt
    init(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) {
        self.code = code
        modifiers = flags.intersection(Self.mask).rawValue
    }
    init(_ event: NSEvent) { self.init(event.keyCode, event.modifierFlags) }
    var flags: NSEvent.ModifierFlags { .init(rawValue: modifiers) }
    var strongModifier: Bool { !flags.intersection([.command, .control, .option]).isEmpty }
    var label: String {
        (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
        + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
        + (Self.names[code] ?? "KEY \(code)")
    }
    static let names: [UInt16: String] = [
        0:"A", 1:"S", 2:"D", 3:"F", 4:"H", 5:"G", 6:"Z", 7:"X", 8:"C", 9:"V", 11:"B",
        12:"Q", 13:"W", 14:"E", 15:"R", 16:"Y", 17:"T", 18:"1", 19:"2", 20:"3", 21:"4",
        22:"6", 23:"5", 24:"=", 25:"9", 26:"7", 27:"-", 28:"8", 29:"0", 30:"]", 31:"O",
        32:"U", 33:"[", 34:"I", 35:"P", 36:"ENTER", 37:"L", 38:"J", 39:"'", 40:"K", 41:";",
        42:"\\", 43:",", 44:"/", 45:"N", 46:"M", 47:".", 48:"TAB", 49:"SPACE", 50:"GRAVE",
        51:"⌫", 53:"ESC", 64:"F17", 65:"NUM .", 67:"NUM *", 69:"NUM +", 71:"CLEAR",
        75:"NUM /", 76:"NUM ENTER", 78:"NUM -", 79:"F18", 80:"F19", 81:"NUM =",
        82:"NUM 0", 83:"NUM 1", 84:"NUM 2", 85:"NUM 3", 86:"NUM 4", 87:"NUM 5",
        88:"NUM 6", 89:"NUM 7", 91:"NUM 8", 92:"NUM 9", 96:"F5", 97:"F6", 98:"F7",
        99:"F3", 100:"F8", 101:"F9", 103:"F11", 105:"F13", 106:"F16", 107:"F14",
        109:"F10", 111:"F12", 113:"F15", 114:"HELP", 115:"HOME", 116:"PAGE ↑",
        117:"⌦", 118:"F4", 119:"END", 120:"F2", 121:"PAGE ↓", 122:"F1",
        123:"←", 124:"→", 125:"↓", 126:"↑"
    ]
    var menuKey: String {
        switch code {
        case 36: return "\r"
        case 48: return "\t"
        case 49: return " "
        case 53: return "\u{1b}"
        case 51: return "\u{8}"
        case 123: return "\u{f702}"
        case 124: return "\u{f703}"
        case 125: return "\u{f701}"
        case 126: return "\u{f700}"
        default:
            let name = Self.names[code] ?? ""
            return name.count == 1 ? name.lowercased() : ""
        }
    }
}

struct ShortcutBinding: Codable, Equatable {
    var strokes: [ShortcutStroke]
    var hold = false
    var holdMilliseconds = 440
    var disabled = false
    var label: String {
        disabled ? "DISABLED" : strokes.map(\.label).joined(separator: " + ") + (hold ? " HOLD" : "")
    }
}

struct ShortcutDefinition: Identifiable {
    let id: String
    let scope: String
    let group: String
    let title: String
    let operation: String
    let defaultBinding: ShortcutBinding
    var global = false
    var repeating = false
    var keys: String { defaultBinding.label }
    var action: String { title }
}

/// One record for each action AND each alternative key. Scope makes Enter-send,
/// Enter-empty-close, project-back and window-close independently configurable.
enum ShortcutCatalog {
    static let all: [ShortcutDefinition] = {
        var result: [ShortcutDefinition] = []
        func add(_ scope: String, _ group: String, _ op: String, _ title: String, _ code: UInt16,
                 _ flags: NSEvent.ModifierFlags = [], alias: String = "key", hold: Bool = false,
                 prefix: ShortcutStroke? = nil, global: Bool = false, repeating: Bool = false) {
            result.append(.init(id: "\(scope).\(op).\(alias)", scope: scope, group: group, title: title,
                operation: op, defaultBinding: .init(strokes: (prefix.map { [$0] } ?? []) + [.init(code, flags)], hold: hold),
                global: global, repeating: repeating))
        }
        func moves(_ scope: String, _ group: String) {
            add(scope, group, "up", "Select previous · letter key", 13, repeating: true)
            add(scope, group, "up", "Select previous · arrow key", 126, alias: "arrow", repeating: true)
            add(scope, group, "down", "Select next · letter key", 1, repeating: true)
            add(scope, group, "down", "Select next · arrow key", 125, alias: "arrow", repeating: true)
        }
        func enter(_ scope: String, _ group: String, _ op: String, _ title: String, space: Bool = false) {
            add(scope, group, op, title, 36)
            add(scope, group, op, title + " · keypad Enter", 76, alias: "keypad")
            if space { add(scope, group, op, title + " · Space", 49, alias: "space") }
        }
        for (op, title, code) in [("projects","Focus Projects",18), ("recents","Focus recent chats",19),
            ("standalone","Focus standalone chats",20), ("models","Focus model settings",21),
            ("journal","Focus journal",23)] {
            add("*", "Windows · global", op, title, UInt16(code), .command, global: true)
        }
        for (op,title,code,flags) in [
            ("preferences","Focus app settings",UInt16(7),NSEvent.ModifierFlags.command),
            ("hide","Hide Bavbav windows",4,.command),
            ("hideOthers","Hide other apps",4,[.command,.option]),
            ("refresh","Refresh projects and chats",15,.command),
            ("quit","Quit the app",12,.command)] {
            add("*","Application",op,title,code,flags)
        }
        for (op,title,code) in [("focusUp","Focus the window above",13), ("focusLeft","Focus the window on the left",0),
            ("focusDown","Focus the window below",1), ("focusRight","Focus the window on the right",2)] {
            add("*read","Window navigation · outside text editing",op,title,UInt16(code),.shift)
        }
        for (op,title,code) in [("selectAll","Select all text",0), ("copy","Copy selected text",8),
            ("paste","Paste text",9)] {
            add("*text","Text selection and clipboard",op,title,UInt16(code),.command)
        }
        let lists = [("projects.root","Projects"), ("projects.chats","Project chats"),
                     ("recents.list","Recent chats"), ("standalone.list","Standalone chats")]
        for (scope,group) in lists {
            moves(scope,group)
            add(scope,group,"open","Open selected item",49)
            add(scope,group,"rename","Rename selected item",49,.option)
            for state in ["full", "empty"] {
                let renameScope = "rename.\(scope).\(state)"
                let renameGroup = group + " · rename · " + (state == "full" ? "with text" : "empty")
                enter(renameScope,renameGroup,"commitRename",state == "full" ? "Save new name" : "Cancel empty name")
                add(renameScope,renameGroup,"cancelRename","Cancel renaming",47,.command)
            }
            add(scope,group,"reorder","Start reordering",49,hold:true)
            enter(scope,group,"write","Open selected chat's composer")
            add(scope,group,"close",scope == "projects.chats" ? "Back to Projects" : "Close this window",12)
            moves(scope + ".moving",group + " · reordering")
            add(scope + ".moving",group + " · reordering","commitOrder","Save new order",49)
            add(scope + ".moving",group + " · reordering","close","Cancel reordering and go back",12)
        }
        for (scope,group,title) in [("projects.root","Projects","Enter a new project name"),
                                   ("projects.chats","Project chats","Enter a new chat name")] {
            add(scope,group,"create",title,36,prefix:.init(49))
            add(scope,group,"create",title + " · keypad Enter",76,alias:"keypad",prefix:.init(49))
        }
        for kind in ["project","chat"] {
            for state in ["full","empty"] {
                let title = state == "full" ? "Confirm name and create" : "Cancel empty name"
                enter("create.\(kind).\(state)",kind == "project" ? "New project name · \(state == "full" ? "with text" : "empty")" :
                    "New chat name · \(state == "full" ? "with text" : "empty")","commitCreation",title)
            }
        }
        moves("standalone.launcher","Standalone chats · CHAT entry")
        add("standalone.launcher","Standalone chats · CHAT entry","open","Start a new chat",49)
        enter("standalone.launcher","Standalone chats · CHAT entry","write","Start a new chat and write")
        add("standalone.launcher","Standalone chats · CHAT entry","close","Close standalone chat list",12)
        for (scope,group) in [("models.rows","Model settings"),("models.model","Model selection"),("models.effort","Reasoning effort")] {
            moves(scope,group)
            add(scope,group,"open",scope == "models.rows" ? "Open options" : "Apply selection",49)
            enter(scope,group,"write","Write in the active chat")
            add(scope,group,"close","Close model settings",12)
        }
        enter("chat.read","Chat · reading","write","Open composer")
        add("chat.read","Chat · reading","close","Close this chat window",12)
        for (scope,group) in [("chat.read","Chat · reading"),("queue.list","Message queue"),
            ("queue.list.moving","Queue · reordering"),("interaction.list","Interaction cards"),
            ("chat.write.full","Message · writing"),("chat.write.empty","Message · empty composer"),
            ("interaction.write","Interaction card · writing")] {
            add(scope,group,"commands","Toggle command and tool activity",48,.shift)
        }
        for (scope,group) in [("chat.read","Chat · reading"),("queue.list","Message queue"),("interaction.list","Interaction cards")] {
            add(scope,group,"bottom","Jump to latest message · letter key",11)
            add(scope,group,"bottom","Jump to latest message · End",119,alias:"end")
        }
        for (scope,group) in [("chat.read","Chat · reading"),("queue.list","Message queue")] {
            add(scope,group,"queueToggle",scope == "chat.read" ? "Open queue" : "Close queue",36,prefix:.init(49))
            add(scope,group,"queueToggle","Toggle queue · keypad Enter",76,alias:"keypad",prefix:.init(49))
        }
        for (scope,group) in [("chat.write.full","Message · writing"),("chat.write.empty","Message · empty composer")] {
            add(scope,group,"composerTools","Open attachments and Codex tools",40,.command)
            add(scope,group,"composerAttach","Attach an image or document",31,.command)
            enter(scope,group,"send",scope.hasSuffix("full") ? "Send message" : "Close empty composer")
            add(scope,group,"newline","Insert newline",36,.shift)
            add(scope,group,"newline","Insert newline · keypad Enter",76,.shift,alias:"keypad")
            add(scope,group,"cancelWriting","Leave text editing",47,.command)
        }
        moves("composer.tools", "Message · attachments and tools")
        enter("composer.tools", "Message · attachments and tools", "composerToolOpen", "Open selected tool", space: true)
        add("composer.tools", "Message · attachments and tools", "composerToolsClose", "Close attachments menu",12)
        add("composer.tools", "Message · attachments and tools", "composerToolsClose", "Close attachments menu · Command",40,.command,alias:"command")
        add("composer.tools", "Message · attachments and tools", "composerGoalClear", "Clear active goal",51,.command)
        enter("composer.goal.write", "Message · goal", "composerGoalSave", "Save goal · cancel if empty")
        add("composer.goal.write", "Message · goal", "composerGoalCancel", "Cancel goal editing",47,.command)
        moves("queue.list","Message queue")
        add("queue.list","Message queue","steer","Steer active turn with selected message",49)
        add("queue.list","Message queue","reorder","Start reordering the queue",49,hold:true)
        add("queue.list","Message queue","editQueued","Move selected message back to composer",12)
        moves("queue.list.moving","Queue · reordering")
        add("queue.list.moving","Queue · reordering","editQueued","Stop reordering and edit message",12)
        moves("interaction.list","Interaction cards")
        enter("interaction.list","Interaction cards","confirmInteraction","Confirm selected answer",space:true)
        add("interaction.list","Interaction cards","close","Leave answer pending and close window",12)
        enter("interaction.write","Interaction card · writing","submitInteraction","Send answer")
        add("interaction.write","Interaction card · writing","cancelInteraction","Cancel answer editing",47,.command)
        for (scope,group) in [("prefs.home","Settings · home"),("prefs.shortcuts","Settings · shortcuts")] {
            moves(scope,group)
            enter(scope,group,"activatePreference","Open selected setting",space:true)
            add(scope,group,"backPreference",scope == "prefs.home" ? "Close settings" : "Back to settings home",12)
        }
        add("prefs.shortcuts","Settings · shortcuts","searchShortcuts","Focus shortcut search",3,.command)
        enter("prefs.search","Shortcut search","finishSearch","Focus search results")
        add("prefs.search","Shortcut search","finishSearch","Leave search field",47,.command,alias:"cancel")
        enter("prefs.confirm","Shortcut binding · confirmation","applyShortcut","Apply new binding")
        add("prefs.confirm","Shortcut binding · confirmation","cancelShortcut","Cancel binding change",12)
        add("prefs.confirm","Shortcut binding · confirmation","recordShortcut","Record keys again",15)
        add("prefs.confirm","Shortcut binding · confirmation","disableShortcut","Disable this shortcut",2)
        add("prefs.confirm","Shortcut binding · confirmation","resetShortcut","Reset this shortcut to default",51)
        add("prefs.confirm","Shortcut binding · confirmation","shorterHold","Decrease hold duration by 20 ms",13,repeating:true)
        add("prefs.confirm","Shortcut binding · confirmation","longerHold","Increase hold duration by 20 ms",1,repeating:true)
        for (op,title,code,alias) in [("less5","Decrease transparency by 5 · letter key",13,"key"),("less5","Decrease transparency by 5 · arrow key",126,"arrow"),
            ("more5","Increase transparency by 5 · letter key",1,"key"),("more5","Increase transparency by 5 · arrow key",125,"arrow"),
            ("less1","Decrease transparency by 1",123,"key"),("more1","Increase transparency by 1",124,"key")] {
            add("prefs.appearance","Settings · appearance",op,title,UInt16(code),alias:alias,repeating:true)
        }
        enter("prefs.appearance","Settings · appearance","resetAppearance","Reset transparency",space:true)
        add("prefs.appearance","Settings · appearance","backPreference","Back to settings home",12)
        for (scope,group) in [("calendar.month","Journal · month"),("calendar.day","Journal · day"),("calendar.note","Journal · note")] {
            add(scope,group,"up",scope == "calendar.month" ? "Previous day" : "Previous note",13,repeating:true)
            add(scope,group,"down",scope == "calendar.month" ? "Next day" : "Next note",1,repeating:true)
            add(scope,group,"calendarUp",scope == "calendar.month" ? "Previous week" : "Previous note · arrow key",126,repeating:true)
            add(scope,group,"calendarDown",scope == "calendar.month" ? "Next week" : "Next note · arrow key",125,repeating:true)
            for (op,title,code) in [("previousDay","Go to previous day",123),("nextDay","Go to next day",124),
                ("previousMonth","Go to previous month",0),("nextMonth","Go to next month",2)] {
                add(scope,group,op,title,UInt16(code),repeating:true)
            }
            enter(scope,group,"calendarOpen",scope == "calendar.month" ? "Open notes for this day" :
                (scope == "calendar.day" ? "Open selected note" : "Open source chat"),space:true)
            for (op,title,code) in [("calendarBack",scope == "calendar.month" ? "Close journal" : "Back to previous page",12),
                ("calendarToday","Go to today",17),("calendarPause","Toggle automatic notes",35),
                ("calendarRetry","Retry note extraction",15),("calendarUndo","Undo last deletion",32)] {
                add(scope,group,op,title,UInt16(code))
            }
            if scope != "calendar.month" {
                add(scope,group,"calendarEdit","Edit selected note",14)
                add(scope,group,"calendarDelete","Confirm deletion of selected note",51)
            }
        }
        enter("calendar.delete","Journal · deletion confirmation","confirmDelete","Delete note",space:true)
        add("calendar.delete","Journal · deletion confirmation","calendarBack","Cancel deletion",12)
        enter("calendar.write","Journal · editing","saveNote","Save note")
        add("calendar.write","Journal · editing","calendarBack","Cancel editing",47,.command)
        return result
    }()
    static func writing(_ scope: String) -> Bool {
        scope.contains(".write") || scope.hasPrefix("create.") || scope.hasPrefix("rename.") || scope == "text.other" || scope == "prefs.search"
    }
    static func overlaps(_ a: String, _ b: String) -> Bool {
        if a == b || a == "*" || b == "*" || a == "*text" || b == "*text" { return true }
        if a == "*read" { return !writing(b) }
        if b == "*read" { return !writing(a) }
        return false
    }
}

@MainActor
final class ShortcutSettings: ObservableObject {
    static let storageKey = "keyboard.bindings.v1"
    @Published private(set) var overrides: [String: ShortcutBinding] = [:]
    @Published private(set) var editingID: String?
    @Published private(set) var recording = false
    @Published var candidate: ShortcutBinding?
    @Published var error: String?
    var onChanged: (() -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    /// External registrations must succeed before committing local settings.
    var validateExternal: (([String: ShortcutBinding]) throws -> Void)?
    private let defaults: UserDefaults
    private var captured: [ShortcutStroke] = []
    private var held = Set<UInt16>()
    private var captureInvalid = false
    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey) {
            if let saved = try? JSONDecoder().decode([String: ShortcutBinding].self, from: data) {
                let known = saved.filter { id, _ in ShortcutCatalog.all.contains { $0.id == id } }
                // Validate the complete snapshot (including independently remapped aliases).
                if known.allSatisfy({ id, binding in validationError(id: id, binding: binding, proposed: known) == nil }) {
                    overrides = known
                } else { error = "Some saved shortcuts are invalid. Safe defaults are being used." }
            } else { error = "Saved shortcuts could not be read. Defaults are being used; the original settings are preserved." }
        }
    }
    func binding(_ definition: ShortcutDefinition) -> ShortcutBinding {
        overrides[definition.id] ?? definition.defaultBinding
    }
    func label(_ id: String) -> String {
        guard let definition = ShortcutCatalog.all.first(where: { $0.id == id }) else { return "—" }
        return binding(definition).label
    }
    func matches(scope: String, text: Bool = false) -> [ShortcutDefinition] {
        ShortcutCatalog.all.filter {
            ($0.scope == scope || $0.scope == "*" || ($0.scope == "*read" && !ShortcutCatalog.writing(scope))
                || ($0.scope == "*text" && text)) && !binding($0).disabled
        }
    }
    func single(_ event: NSEvent, scope: String) -> ShortcutDefinition? {
        matches(scope: scope).first { binding($0).strokes == [ShortcutStroke(event)] && !binding($0).hold }
    }
    func validationError(id: String, binding: ShortcutBinding, proposed: [String: ShortcutBinding]? = nil) -> String? {
        guard let definition = ShortcutCatalog.all.first(where: { $0.id == id }) else { return "Unknown action." }
        if binding.disabled { return nil }
        guard (1...2).contains(binding.strokes.count), Set(binding.strokes.map(\.code)).count == binding.strokes.count,
              binding.strokes.allSatisfy({ ShortcutStroke.names[$0.code] != nil && $0.modifiers & ~ShortcutStroke.mask.rawValue == 0 }),
              binding.hold == definition.defaultBinding.hold, !binding.hold || binding.strokes.count == 1,
              (200...2000).contains(binding.holdMilliseconds) else { return "Invalid key combination." }
        if binding.strokes.contains(where: { $0.code == 48 && $0.flags.contains(.command) }) {
            return "⌘Tab is reserved for the macOS app switcher and cannot be changed."
        }
        if definition.global || definition.scope == "*" || definition.scope == "*text" {
            guard binding.strokes.count == 1, binding.strokes[0].strongModifier else {
                return "This action requires one key with Command, Control, or Option."
            }
        }
        if ShortcutCatalog.writing(definition.scope) {
            guard binding.strokes.count == 1, let key = binding.strokes.first,
                  key.strongModifier || [36,76].contains(key.code) || (key.code == 48 && key.flags == .shift) else {
                return "To preserve normal typing, use Enter or a key with Command, Control, or Option."
            }
        }
        let snapshot = proposed ?? overrides
        for other in ShortcutCatalog.all where other.id != id && ShortcutCatalog.overlaps(definition.scope, other.scope) {
            let value = snapshot[other.id] ?? other.defaultBinding
            guard !value.disabled else { continue }
            if value.strokes == binding.strokes && value.hold == binding.hold {
                return "Conflict: \(other.group) · \(other.title). Change or disable that binding first."
            }
            if (other.scope == "*" || definition.scope == "*" || other.scope == "*text" || definition.scope == "*text"),
               value.strokes.first == binding.strokes.first {
                return "This key conflicts with a global window shortcut: \(other.title)."
            }
        }
        return nil
    }
    @discardableResult
    func set(_ id: String, _ value: ShortcutBinding?) -> Bool {
        guard let definition = ShortcutCatalog.all.first(where: { $0.id == id }) else { return false }
        let binding = value ?? definition.defaultBinding
        var proposed = overrides
        proposed[id] = binding == definition.defaultBinding ? nil : binding
        if let problem = validationError(id: id, binding: binding, proposed: proposed) { error = problem; return false }
        return commit(proposed)
    }
    @discardableResult
    func resetAll() -> Bool { commit([:]) }
    private func commit(_ proposed: [String: ShortcutBinding]) -> Bool {
        do {
            let data = try JSONEncoder().encode(proposed)
            try validateExternal?(proposed)
            defaults.set(data, forKey: Self.storageKey)
            overrides = proposed; error = nil
            onChanged?()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func beginRecording(_ id: String) {
        guard let definition = ShortcutCatalog.all.first(where: { $0.id == id }) else { return }
        editingID = id; candidate = binding(definition); error = nil
        recordAgain()
    }
    func recordAgain() {
        guard editingID != nil else { return }
        captured = []; held = []; captureInvalid = false; error = nil; recording = true
        onRecordingChanged?(true)
    }
    func capture(_ event: NSEvent) {
        guard recording else { return }
        if event.type == .keyDown {
            guard !event.isARepeat, !held.contains(event.keyCode) else { return }
            held.insert(event.keyCode)
            if captured.count < 2 { captured.append(ShortcutStroke(event)) }
            else { captureInvalid = true; error = "Use at most two keys together. Record the shortcut again."; return }
            candidate?.strokes = captured; candidate?.disabled = false
        } else if event.type == .keyUp {
            held.remove(event.keyCode)
            if held.isEmpty && !captured.isEmpty { recording = false; onRecordingChanged?(false) }
        }
    }
    @discardableResult
    func applyCandidate() -> Bool {
        guard !recording, !captureInvalid, let id = editingID, let candidate, set(id, candidate) else { return false }
        cancelEditing(); return true
    }
    func cancelEditing() {
        let wasRecording = recording
        recording = false; editingID = nil; candidate = nil; captured = []; held = []
        if wasRecording { onRecordingChanged?(false) }
    }
}
