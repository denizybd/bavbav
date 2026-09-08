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
        disabled ? "KAPALI" : strokes.map(\.label).joined(separator: " + ") + (hold ? " TUT" : "")
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
            add(scope, group, "up", "Yukarı seç · harf tuşu", 13, repeating: true)
            add(scope, group, "up", "Yukarı seç · ok tuşu", 126, alias: "arrow", repeating: true)
            add(scope, group, "down", "Aşağı seç · harf tuşu", 1, repeating: true)
            add(scope, group, "down", "Aşağı seç · ok tuşu", 125, alias: "arrow", repeating: true)
        }
        func enter(_ scope: String, _ group: String, _ op: String, _ title: String, space: Bool = false) {
            add(scope, group, op, title, 36)
            add(scope, group, op, title + " · sayısal Enter", 76, alias: "keypad")
            if space { add(scope, group, op, title + " · Space", 49, alias: "space") }
        }
        for (op, title, code) in [("projects","Projeler penceresini odakla",18), ("recents","Son sohbetleri odakla",19),
            ("standalone","ChatGPT penceresini odakla",20), ("models","Model ayarlarını odakla",21),
            ("journal","Takvimi odakla",23)] {
            add("*", "Pencereler · sistem genelinde", op, title, UInt16(code), .command, global: true)
        }
        for (op,title,code,flags) in [
            ("preferences","Uygulama ayarlarını odakla",UInt16(7),NSEvent.ModifierFlags.command),
            ("hide","Bavbav pencerelerini gizle",4,.command),
            ("hideOthers","Diğer uygulamaları gizle",4,[.command,.option]),
            ("refresh","Projeleri ve sohbetleri yenile",15,.command),
            ("quit","Uygulamadan çık",12,.command)] {
            add("*","Uygulama",op,title,code,flags)
        }
        for (op,title,code) in [("focusUp","Üstteki pencereye geç",13), ("focusLeft","Soldaki pencereye geç",0),
            ("focusDown","Alttaki pencereye geç",1), ("focusRight","Sağdaki pencereye geç",2)] {
            add("*read","Pencereler arasında · yazmıyorken",op,title,UInt16(code),.shift)
        }
        for (op,title,code) in [("selectAll","Metnin tümünü seç",0), ("copy","Seçili metni kopyala",8),
            ("paste","Metin yapıştır",9)] {
            add("*text","Metin seçimi ve pano",op,title,UInt16(code),.command)
        }
        let lists = [("projects.root","Projeler"), ("projects.chats","Projenin sohbetleri"),
                     ("recents.list","Son sohbetler"), ("standalone.list","ChatGPT sohbetleri")]
        for (scope,group) in lists {
            moves(scope,group)
            add(scope,group,"open","Seçili öğeyi aç",49)
            add(scope,group,"rename","Seçili öğenin adını düzenle",49,.option)
            for state in ["full", "empty"] {
                let renameScope = "rename.\(scope).\(state)"
                let renameGroup = group + " · ad düzenleme · " + (state == "full" ? "dolu" : "boş")
                enter(renameScope,renameGroup,"commitRename",state == "full" ? "Yeni adı kaydet" : "Boş adı iptal et")
                add(renameScope,renameGroup,"cancelRename","Ad değişikliğinden vazgeç",47,.command)
            }
            add(scope,group,"reorder","Sıralamayı değiştirmeye başla",49,hold:true)
            enter(scope,group,"write","Seçili sohbetin yazma alanını aç")
            add(scope,group,"close",scope == "projects.chats" ? "Projeler listesine dön" : "Bu pencereyi kapat",12)
            moves(scope + ".moving",group + " · sıralama")
            add(scope + ".moving",group + " · sıralama","commitOrder","Yeni sırayı kaydet",49)
            add(scope + ".moving",group + " · sıralama","close","Sıralamadan vazgeç ve geri dön",12)
        }
        for (scope,group,title) in [("projects.root","Projeler","Yeni projenin adını yaz"),
                                   ("projects.chats","Projenin sohbetleri","Yeni sohbetin adını yaz")] {
            add(scope,group,"create",title,36,prefix:.init(49))
            add(scope,group,"create",title + " · sayısal Enter",76,alias:"keypad",prefix:.init(49))
        }
        for kind in ["project","chat"] {
            for state in ["full","empty"] {
                let title = state == "full" ? "Adı onayla ve oluştur" : "Boş adı iptal et"
                enter("create.\(kind).\(state)",kind == "project" ? "Yeni proje adı · \(state == "full" ? "dolu" : "boş")" :
                    "Yeni sohbet adı · \(state == "full" ? "dolu" : "boş")","commitCreation",title)
            }
        }
        moves("standalone.launcher","ChatGPT · CHAT satırı")
        add("standalone.launcher","ChatGPT · CHAT satırı","open","Yeni sohbet aç",49)
        enter("standalone.launcher","ChatGPT · CHAT satırı","write","Yeni sohbet aç ve yaz")
        add("standalone.launcher","ChatGPT · CHAT satırı","close","ChatGPT listesini kapat",12)
        for (scope,group) in [("models.rows","Model ayarları"),("models.model","Model seçimi"),("models.effort","Çaba seçimi")] {
            moves(scope,group)
            add(scope,group,"open",scope == "models.rows" ? "Seçenekleri aç" : "Seçimi uygula",49)
            enter(scope,group,"write","Etkin sohbette yaz")
            add(scope,group,"close","Model penceresini kapat",12)
        }
        enter("chat.read","Sohbet · okuma","write","Yazma alanını aç")
        add("chat.read","Sohbet · okuma","close","Bu sohbet penceresini kapat",12)
        for (scope,group) in [("chat.read","Sohbet · okuma"),("queue.list","Mesaj kuyruğu"),
            ("queue.list.moving","Kuyruk · sıralama"),("interaction.list","Karar kartları"),
            ("chat.write.full","Mesaj · yazma"),("chat.write.empty","Mesaj · boş yazma alanı"),
            ("interaction.write","Karar kartı · yazma")] {
            add(scope,group,"commands","Komut mesajlarının görünürlüğünü değiştir",48,.shift)
        }
        for (scope,group) in [("chat.read","Sohbet · okuma"),("queue.list","Mesaj kuyruğu"),("interaction.list","Karar kartları")] {
            add(scope,group,"bottom","Sohbetin en altına git · harf tuşu",11)
            add(scope,group,"bottom","Sohbetin en altına git · End",119,alias:"end")
        }
        for (scope,group) in [("chat.read","Sohbet · okuma"),("queue.list","Mesaj kuyruğu")] {
            add(scope,group,"queueToggle",scope == "chat.read" ? "Kuyruğu aç" : "Kuyruğu kapat",36,prefix:.init(49))
            add(scope,group,"queueToggle","Kuyruk görünürlüğünü değiştir · sayısal Enter",76,alias:"keypad",prefix:.init(49))
        }
        for (scope,group) in [("chat.write.full","Mesaj · yazma"),("chat.write.empty","Mesaj · boş yazma alanı")] {
            enter(scope,group,"send",scope.hasSuffix("full") ? "Mesajı gönder" : "Boş yazma alanını kapat")
            add(scope,group,"newline","Yeni satır ekle",36,.shift)
            add(scope,group,"newline","Yeni satır ekle · sayısal Enter",76,.shift,alias:"keypad")
            add(scope,group,"cancelWriting","Yazmayı iptal et",47,.command)
        }
        moves("queue.list","Mesaj kuyruğu")
        add("queue.list","Mesaj kuyruğu","steer","Seçili mesajı çalışan tura ilet",49)
        add("queue.list","Mesaj kuyruğu","reorder","Kuyruğu sıralamaya başla",49,hold:true)
        add("queue.list","Mesaj kuyruğu","editQueued","Seçili mesajı yazma alanına geri al",12)
        moves("queue.list.moving","Kuyruk · sıralama")
        add("queue.list.moving","Kuyruk · sıralama","editQueued","Sıralamadan çık ve mesajı düzenle",12)
        moves("interaction.list","Karar kartları")
        enter("interaction.list","Karar kartları","confirmInteraction","Seçili yanıtı onayla",space:true)
        add("interaction.list","Karar kartları","close","Yanıtı beklet ve pencereyi kapat",12)
        enter("interaction.write","Karar kartı · yazma","submitInteraction","Yanıtı gönder")
        add("interaction.write","Karar kartı · yazma","cancelInteraction","Yanıtı yazmaktan vazgeç",47,.command)
        for (scope,group) in [("prefs.home","Ayarlar · ana sayfa"),("prefs.shortcuts","Ayarlar · kısayollar")] {
            moves(scope,group)
            enter(scope,group,"activatePreference","Seçili ayarı aç",space:true)
            add(scope,group,"backPreference",scope == "prefs.home" ? "Ayarları kapat" : "Ayarlar ana sayfasına dön",12)
        }
        add("prefs.shortcuts","Ayarlar · kısayollar","searchShortcuts","Kısayol aramasına yaz",3,.command)
        enter("prefs.search","Kısayol araması","finishSearch","Sonuç listesine geç")
        add("prefs.search","Kısayol araması","finishSearch","Aramayı yazmaktan çık",47,.command,alias:"cancel")
        enter("prefs.confirm","Kısayol atama · onay","applyShortcut","Yeni atamayı uygula")
        add("prefs.confirm","Kısayol atama · onay","cancelShortcut","Atamaktan vazgeç",12)
        add("prefs.confirm","Kısayol atama · onay","recordShortcut","Tuşu yeniden kaydet",15)
        add("prefs.confirm","Kısayol atama · onay","disableShortcut","Bu kısayolu kapat",2)
        add("prefs.confirm","Kısayol atama · onay","resetShortcut","Bu kısayolu varsayılana döndür",51)
        add("prefs.confirm","Kısayol atama · onay","shorterHold","Basılı tutma süresini 20 ms azalt",13,repeating:true)
        add("prefs.confirm","Kısayol atama · onay","longerHold","Basılı tutma süresini 20 ms artır",1,repeating:true)
        for (op,title,code,alias) in [("less5","Saydamlığı 5 azalt · harf",13,"key"),("less5","Saydamlığı 5 azalt · ok",126,"arrow"),
            ("more5","Saydamlığı 5 artır · harf",1,"key"),("more5","Saydamlığı 5 artır · ok",125,"arrow"),
            ("less1","Saydamlığı 1 azalt",123,"key"),("more1","Saydamlığı 1 artır",124,"key")] {
            add("prefs.appearance","Ayarlar · görünüm",op,title,UInt16(code),alias:alias,repeating:true)
        }
        enter("prefs.appearance","Ayarlar · görünüm","resetAppearance","Saydamlığı sıfırla",space:true)
        add("prefs.appearance","Ayarlar · görünüm","backPreference","Ayarlar ana sayfasına dön",12)
        for (scope,group) in [("calendar.month","Takvim · ay"),("calendar.day","Takvim · gün"),("calendar.note","Takvim · not")] {
            add(scope,group,"up",scope == "calendar.month" ? "Önceki gün" : "Önceki not",13,repeating:true)
            add(scope,group,"down",scope == "calendar.month" ? "Sonraki gün" : "Sonraki not",1,repeating:true)
            add(scope,group,"calendarUp",scope == "calendar.month" ? "Önceki hafta" : "Önceki not · ok",126,repeating:true)
            add(scope,group,"calendarDown",scope == "calendar.month" ? "Sonraki hafta" : "Sonraki not · ok",125,repeating:true)
            for (op,title,code) in [("previousDay","Önceki güne geç",123),("nextDay","Sonraki güne geç",124),
                ("previousMonth","Önceki aya geç",0),("nextMonth","Sonraki aya geç",2)] {
                add(scope,group,op,title,UInt16(code),repeating:true)
            }
            enter(scope,group,"calendarOpen",scope == "calendar.month" ? "Günün notlarını aç" :
                (scope == "calendar.day" ? "Seçili notu aç" : "Kaynak sohbeti aç"),space:true)
            for (op,title,code) in [("calendarBack",scope == "calendar.month" ? "Takvimi kapat" : "Önceki sayfaya dön",12),
                ("calendarToday","Bugüne dön",17),("calendarPause","Otomatik not almayı değiştir",35),
                ("calendarRetry","Not almayı yeniden dene",15),("calendarUndo","Son silmeyi geri al",32)] {
                add(scope,group,op,title,UInt16(code))
            }
            if scope != "calendar.month" {
                add(scope,group,"calendarEdit","Seçili notu düzenle",14)
                add(scope,group,"calendarDelete","Seçili notu silme onayını aç",51)
            }
        }
        enter("calendar.delete","Takvim · silme onayı","confirmDelete","Notu sil",space:true)
        add("calendar.delete","Takvim · silme onayı","calendarBack","Silmekten vazgeç",12)
        enter("calendar.write","Takvim · not yazma","saveNote","Notu kaydet")
        add("calendar.write","Takvim · not yazma","calendarBack","Düzenlemekten vazgeç",47,.command)
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
                } else { error = "Kaydedilmiş bazı kısayollar geçersiz. Güvenli varsayılanlar kullanılıyor." }
            } else { error = "Kısayol kaydı okunamadı. Varsayılanlar kullanılıyor; eski kayıt korunuyor." }
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
        guard let definition = ShortcutCatalog.all.first(where: { $0.id == id }) else { return "Bilinmeyen işlem." }
        if binding.disabled { return nil }
        guard (1...2).contains(binding.strokes.count), Set(binding.strokes.map(\.code)).count == binding.strokes.count,
              binding.strokes.allSatisfy({ ShortcutStroke.names[$0.code] != nil && $0.modifiers & ~ShortcutStroke.mask.rawValue == 0 }),
              binding.hold == definition.defaultBinding.hold, !binding.hold || binding.strokes.count == 1,
              (200...2000).contains(binding.holdMilliseconds) else { return "Geçersiz tuş birleşimi." }
        if binding.strokes.contains(where: { $0.code == 48 && $0.flags.contains(.command) }) {
            return "⌘Tab macOS uygulama geçişine ait; değiştirilemez."
        }
        if definition.global || definition.scope == "*" || definition.scope == "*text" {
            guard binding.strokes.count == 1, binding.strokes[0].strongModifier else {
                return "Bu işlem tek tuşla birlikte Command, Control veya Option gerektirir."
            }
        }
        if ShortcutCatalog.writing(definition.scope) {
            guard binding.strokes.count == 1, let key = binding.strokes.first,
                  key.strongModifier || [36,76].contains(key.code) || (key.code == 48 && key.flags == .shift) else {
                return "Yazmayı bozmamak için Enter ya da Command, Control veya Option içeren bir tuş seç."
            }
        }
        let snapshot = proposed ?? overrides
        for other in ShortcutCatalog.all where other.id != id && ShortcutCatalog.overlaps(definition.scope, other.scope) {
            let value = snapshot[other.id] ?? other.defaultBinding
            guard !value.disabled else { continue }
            if value.strokes == binding.strokes && value.hold == binding.hold {
                return "Çakışma: \(other.group) · \(other.title). Önce bu atamayı değiştir veya kapat."
            }
            if (other.scope == "*" || definition.scope == "*" || other.scope == "*text" || definition.scope == "*text"),
               value.strokes.first == binding.strokes.first {
                return "Bu tuş sistem genelindeki pencere kısayoluyla çakışıyor: \(other.title)."
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
            else { captureInvalid = true; error = "En fazla iki tuşu birlikte kullanabilirsin. Yeniden kaydet."; return }
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
