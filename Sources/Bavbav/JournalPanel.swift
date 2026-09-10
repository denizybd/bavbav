import AppKit
import BavbavCore
import SwiftUI

final class JournalPanel: NSPanel, CornerResizeCommitHandler {
    var onResize: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    func cornerResizeDidFinish() { onResize?() }
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        title = "Bavbav Journal"
        isFloatingPanel = false; level = .normal; isOpaque = false; backgroundColor = .clear
        hasShadow = true; isReleasedWhenClosed = false; hidesOnDeactivate = false
        collectionBehavior = [.moveToActiveSpace]; isMovableByWindowBackground = true
        becomesKeyOnlyIfNeeded = false; minSize = NSSize(width: 360, height: 400)
    }
}

enum JournalRoute { case month, day, note }

@MainActor
final class JournalNavigation: ObservableObject {
    @Published var selectedDate = Date()
    @Published var route: JournalRoute = .month
    @Published var selectedID: String?
    @Published var editing = false
    @Published var draft = ""
    @Published var draftDay = ""
    @Published var editError: String?
    @Published var focusToken = 0
    @Published var confirmingDelete = false
    let service: JournalService
    init(service: JournalService) { self.service = service }
    var day: String { JournalRules.day(selectedDate) }
    var dayNotes: [JournalNote] { service.notes.filter { $0.day == day }.sorted { $0.createdAt < $1.createdAt } }
    var selected: JournalNote? { service.notes.first { $0.id == selectedID } }
    var monthTitle: String { selectedDate.formatted(.dateTime.year().month(.wide).locale(Locale(identifier: "en_US"))).uppercased() }
    var monthCells: [Date?] {
        let calendar = JournalRules.calendar()
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: selectedDate))!
        let offset = (calendar.component(.weekday, from: start) + 5) % 7
        let count = calendar.range(of: .day, in: .month, for: start)!.count
        return Array(repeating: nil, count: offset) + (0..<count).map { calendar.date(byAdding: .day, value: $0, to: start) }
    }
    func move(_ delta: Int) {
        if route == .month { changeDay(delta); return }
        let notes = dayNotes
        guard !notes.isEmpty else { selectedID = nil; return }
        let current = notes.firstIndex { $0.id == selectedID } ?? 0
        selectedID = notes[min(notes.count - 1, max(0, current + delta))].id
    }
    func changeDay(_ delta: Int) {
        selectedDate = JournalRules.calendar().date(byAdding: .day, value: delta, to: selectedDate) ?? selectedDate
        selectedID = nil
    }
    func changeMonth(_ delta: Int) {
        selectedDate = JournalRules.calendar().date(byAdding: .month, value: delta, to: selectedDate) ?? selectedDate
        route = .month; selectedID = nil
    }
    func today() { selectedDate = Date(); route = .month; selectedID = nil }
    func activate() {
        switch route {
        case .month: route = .day; selectedID = dayNotes.first?.id
        case .day: if selected != nil { route = .note }
        case .note: if let selected { service.onOpenSource?(selected.thread) }
        }
    }
    func beginEdit() {
        guard let selected else { return }
        draft = selected.summary; draftDay = selected.eventDay ?? ""
        editing = true; route = .note; editError = nil; focusToken += 1
    }
    func saveEdit() {
        guard let selected else { return }
        let date = draftDay.trimmingCharacters(in: .whitespacesAndNewlines)
        if service.edit(id: selected.id, summary: draft, day: date.isEmpty ? nil : date) {
            editing = false; editError = nil
            if let newDate = JournalRules.date(date) { selectedDate = newDate }
            NSApp.keyWindow?.makeFirstResponder(nil)
        } else { editError = "Use 1–240 characters for the note and YYYY-MM-DD for the date, or leave the date empty." }
    }
    func goBack() -> Bool {
        if confirmingDelete { confirmingDelete = false; return true }
        if editing { editing = false; editError = nil; return true }
        switch route {
        case .note: route = .day; return true
        case .day: route = .month; return true
        case .month: return false
        }
    }
    func confirmDelete() {
        guard let selectedID else { return }
        service.delete(id: selectedID)
        confirmingDelete = false; route = .day; self.selectedID = dayNotes.first?.id
    }
}

@MainActor
final class JournalWindowController {
    let window = JournalPanel()
    let navigation: JournalNavigation
    private let defaults: UserDefaults
    private let bindings: ShortcutSettings
    private weak var returnWindow: NSWindow?
    init(service: JournalService, preferences: AppPreferences, defaults: UserDefaults) {
        navigation = JournalNavigation(service: service)
        self.defaults = defaults
        bindings = preferences.keyBindings
        let container = CornerResizeContainer(frame: NSRect(origin: .zero, size: window.frame.size))
        container.setContent(NSHostingView(rootView: PanelAppearanceRoot(preferences: preferences,
                            content: JournalPanelView(navigation: navigation, service: service))))
        window.contentView = container
        window.onResize = { [weak self] in
            guard let self else { return }
            defaults.set([Double(window.frame.width), Double(window.frame.height)], forKey: "window-size.journal")
        }
    }
    func position(in frame: NSRect) {
        let saved = defaults.array(forKey: "window-size.journal") as? [Double]
        let valid = saved?.count == 2 && saved!.allSatisfy { $0.isFinite && $0 > 0 }
        let size = NSSize(width: valid ? max(360, saved![0]) : 440, height: valid ? max(400, saved![1]) : 520)
        let w = min(size.width, max(1, frame.width - 28)), h = min(size.height, max(1, frame.height - 28))
        window.setFrame(NSRect(x: frame.midX - w / 2, y: frame.midY - h / 2, width: w, height: h), display: false)
    }
    func show(in frame: NSRect) {
        if !window.isKeyWindow, let previous = NSApp.keyWindow, previous !== window { returnWindow = previous }
        if !window.isVisible { position(in: frame) }
        window.makeKeyAndOrderFront(nil)
    }
    func close() {
        window.orderOut(nil)
        if let returnWindow, returnWindow.isVisible { returnWindow.makeKeyAndOrderFront(nil) }
        returnWindow = nil
    }
    var shortcutScope: String {
        if navigation.editing { return "calendar.write" }
        if navigation.confirmingDelete { return "calendar.delete" }
        switch navigation.route {
        case .month: return "calendar.month"
        case .day: return "calendar.day"
        case .note: return "calendar.note"
        }
    }
    func handleKey(_ event: NSEvent) -> Bool {
        guard let definition = bindings.single(event, scope: shortcutScope) else {
            return !navigation.editing && event.keyCode == 53
        }
        if event.type == .keyDown && (!event.isARepeat || definition.repeating) { perform(definition.operation) }
        return true
    }
    func perform(_ operation: String) {
        switch operation {
        case "up": navigation.move(-1)
        case "down": navigation.move(1)
        case "calendarUp": navigation.route == .month ? navigation.changeDay(-7) : navigation.move(-1)
        case "calendarDown": navigation.route == .month ? navigation.changeDay(7) : navigation.move(1)
        case "previousDay": navigation.changeDay(-1)
        case "nextDay": navigation.changeDay(1)
        case "previousMonth": navigation.changeMonth(-1)
        case "nextMonth": navigation.changeMonth(1)
        case "calendarOpen": navigation.activate()
        case "calendarEdit": navigation.beginEdit()
        case "calendarDelete": if navigation.selected != nil { navigation.confirmingDelete = true }
        case "calendarBack":
            if !navigation.goBack() { close() }
            if !navigation.editing { window.makeFirstResponder(nil) }
        case "calendarToday": navigation.today()
        case "calendarPause": navigation.service.toggleEnabled()
        case "calendarRetry": navigation.service.retry()
        case "calendarUndo": navigation.service.undoDelete()
        case "confirmDelete": navigation.confirmDelete()
        case "saveNote": navigation.saveEdit()
        default: break
        }
    }
}

struct JournalPanelView: View {
    @Environment(\.shortcutLabels) private var shortcuts
    @ObservedObject var navigation: JournalNavigation
    @ObservedObject var service: JournalService
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("05 / JOURNAL").font(BavbavTheme.mono(10, weight: .bold)).foregroundStyle(BavbavTheme.accent).readableForeground()
                    Text("Small notes. Lasting context.").font(BavbavTheme.mono(10)).foregroundStyle(BavbavTheme.muted).readableForeground()
                }
                Spacer()
                Button(service.state.enabled ? "● AUTO" : "○ PAUSE") { service.toggleEnabled() }
                    .font(BavbavTheme.mono(9, weight: .bold)).foregroundStyle(service.state.enabled ? BavbavTheme.accent : BavbavTheme.warning)
                    .readableForeground().buttonStyle(.plain).help("Toggle automatic notes · \(shortcuts.key("calendar.month.calendarPause.key"))")
            }.padding(18).fixedSize(horizontal: false, vertical: true)
            Divider().overlay(BavbavTheme.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if navigation.confirmingDelete {
                        Text("Delete this note?").font(BavbavTheme.mono(12, weight: .bold))
                        Text("\(shortcuts.key("calendar.delete.confirmDelete.key")) DELETE · \(shortcuts.key("calendar.delete.calendarBack.key")) CANCEL").font(BavbavTheme.mono(9)).foregroundStyle(BavbavTheme.warning)
                        Button("Delete") { navigation.confirmDelete() }.buttonStyle(.plain)
                    } else if navigation.editing {
                        editor
                    } else if navigation.route == .month {
                        month
                    } else if navigation.route == .day {
                        day
                    } else if let note = navigation.selected {
                        detail(note)
                    }
                }.padding(18).foregroundStyle(BavbavTheme.text).readableForeground()
            }
            .id(navigation.route)
            .clipped()
            Divider().overlay(BavbavTheme.border)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    if service.working { ProgressView().controlSize(.mini) }
                    Text(service.status).lineLimit(3)
                        .foregroundStyle(service.error == nil ? BavbavTheme.accent : BavbavTheme.warning)
                }
                Text(footer).foregroundStyle(BavbavTheme.muted)
                Text("EXTRA CODEX USAGE · \(service.state.usageDay == JournalRules.day(Date()) ? service.state.requestsToday : 0)/\(JournalService.dailyRequestLimit) JOBS / DAY")
                    .foregroundStyle(BavbavTheme.muted)
            }.font(BavbavTheme.mono(8, weight: .medium)).readableForeground().padding(14)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BavbavTheme.background.panelBackdrop())
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(BavbavTheme.border, lineWidth: 1))
    }
    private var footer: String {
        if navigation.editing { return "\(shortcuts.key("calendar.write.saveNote.key")) SAVE · \(shortcuts.key("calendar.write.calendarBack.key")) CANCEL" }
        if navigation.confirmingDelete { return "Waiting for deletion confirmation." }
        switch navigation.route {
        case .month: return "\(shortcuts.key("calendar.month.up.key")) ← DAY · \(shortcuts.key("calendar.month.down.key")) DAY → · \(shortcuts.key("calendar.month.previousMonth.key")) ← MONTH · \(shortcuts.key("calendar.month.nextMonth.key")) MONTH →\n\(shortcuts.key("calendar.month.calendarOpen.space")) OPEN · \(shortcuts.key("calendar.month.calendarToday.key")) TODAY · \(shortcuts.key("calendar.month.calendarBack.key")) CLOSE\n\(shortcuts.key("calendar.month.calendarPause.key")) AUTO · \(shortcuts.key("calendar.month.calendarRetry.key")) RETRY"
        case .day: return "\(shortcuts.key("calendar.day.up.key")) ↑ · \(shortcuts.key("calendar.day.down.key")) ↓ · \(shortcuts.key("calendar.day.calendarOpen.space")) OPEN · \(shortcuts.key("calendar.day.calendarEdit.key")) EDIT · \(shortcuts.key("calendar.day.calendarBack.key")) JOURNAL"
        case .note: return "\(shortcuts.key("calendar.note.calendarOpen.space")) SOURCE CHAT · \(shortcuts.key("calendar.note.calendarEdit.key")) EDIT · \(shortcuts.key("calendar.note.calendarDelete.key")) DELETE · \(shortcuts.key("calendar.note.calendarUndo.key")) UNDO · \(shortcuts.key("calendar.note.calendarBack.key")) BACK"
        }
    }
    private var month: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button("‹") { navigation.changeMonth(-1) }
                Spacer()
                Text(navigation.monthTitle).font(BavbavTheme.mono(12, weight: .bold))
                Spacer()
                Button("›") { navigation.changeMonth(1) }
            }.buttonStyle(.plain)
            LazyVGrid(columns: columns, spacing: 5) {
                ForEach(["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"], id: \.self) { name in
                    Text(name).font(BavbavTheme.mono(8)).foregroundStyle(BavbavTheme.muted).frame(maxWidth: .infinity)
                }
                ForEach(Array(navigation.monthCells.enumerated()), id: \.offset) { _, date in
                    if let date {
                        let day = JournalRules.day(date)
                        let count = service.notes.filter { $0.day == day }.count
                        Button {
                            navigation.selectedDate = date
                            navigation.activate()
                        } label: {
                            VStack(spacing: 5) {
                                Text("\(JournalRules.calendar().component(.day, from: date))").font(BavbavTheme.mono(12, weight: .medium))
                                Circle().fill(count > 0 ? BavbavTheme.accent : .clear).frame(width: 3, height: 3)
                            }
                            .frame(maxWidth: .infinity).frame(height: 40)
                            .background((navigation.day == day ? BavbavTheme.raised : BavbavTheme.surface).panelBackdrop())
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(navigation.day == day ? BavbavTheme.accent : .clear, lineWidth: 0.8))
                        }.buttonStyle(.plain).help("\(day) · Notes: \(count)")
                    } else { Color.clear.frame(height: 40) }
                }
            }
            Text("\(navigation.day) · Notes: \(navigation.dayNotes.count)").font(BavbavTheme.mono(10)).foregroundStyle(BavbavTheme.accent)
            if let note = navigation.dayNotes.first {
                Text(note.summary).font(BavbavTheme.mono(10)).lineLimit(3)
            } else {
                Text("No notes yet for this day. Important events and confirmed decisions become short notes from your conversations.")
                    .font(BavbavTheme.mono(10)).foregroundStyle(BavbavTheme.muted)
            }
        }
    }
    private var day: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(navigation.day).font(BavbavTheme.mono(14, weight: .bold))
            if navigation.dayNotes.isEmpty { Text("No notes for this day.").font(BavbavTheme.mono(11)).foregroundStyle(BavbavTheme.muted) }
            ForEach(navigation.dayNotes) { note in
                Button { navigation.selectedID = note.id; navigation.route = .note } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(note.kind.label + (note.eventDay == nil ? " · DATE UNCERTAIN" : ""))
                            .font(BavbavTheme.mono(8, weight: .bold)).foregroundStyle(note.kind == .plan ? BavbavTheme.warning : BavbavTheme.accent)
                        Text(note.summary).font(BavbavTheme.mono(11)).multilineTextAlignment(.leading)
                        Text(note.channel + " / " + note.thread.title).font(BavbavTheme.mono(8)).foregroundStyle(BavbavTheme.muted).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .background(BavbavTheme.surface.panelBackdrop()).clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(navigation.selectedID == note.id ? BavbavTheme.accent : BavbavTheme.border, lineWidth: 0.8))
                }.buttonStyle(.plain)
            }
        }
    }
    private func detail(_ note: JournalNote) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(note.kind.label).font(BavbavTheme.mono(9, weight: .bold)).foregroundStyle(BavbavTheme.accent)
            Text(note.summary).font(BavbavTheme.mono(14, weight: .medium)).textSelection(.enabled)
            Text(note.eventDay ?? "Event date uncertain · Discussed on: \(note.recordedDay)")
                .font(BavbavTheme.mono(9)).foregroundStyle(BavbavTheme.muted)
            if note.edited { Text("EDITED").font(BavbavTheme.mono(8)).foregroundStyle(BavbavTheme.warning) }
            Divider().overlay(BavbavTheme.border)
            Text("SOURCE / \(note.thread.title)").font(BavbavTheme.mono(9, weight: .bold))
            ForEach(Array(note.sources.enumerated()), id: \.offset) { _, source in
                Text("“\(source.quote)”").font(BavbavTheme.mono(11)).foregroundStyle(BavbavTheme.muted).textSelection(.enabled)
            }
            HStack {
                Button("Open source chat ↗") { service.onOpenSource?(note.thread) }
                Spacer()
                Button("Edit") { navigation.beginEdit() }
                Button("Delete") { navigation.confirmingDelete = true }.foregroundStyle(BavbavTheme.warning)
            }.font(BavbavTheme.mono(10)).foregroundStyle(BavbavTheme.accent).buttonStyle(.plain)
        }
    }
    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("EDIT NOTE").font(BavbavTheme.mono(11, weight: .bold))
            CompactInputField(text: $navigation.draft, focusToken: navigation.focusToken, secure: false, onSubmit: navigation.saveEdit)
                .frame(height: 36)
            Text("Date · YYYY-MM-DD · leave empty if uncertain").font(BavbavTheme.mono(9)).foregroundStyle(BavbavTheme.muted)
            TextField("", text: $navigation.draftDay).textFieldStyle(.plain).font(BavbavTheme.mono(12))
                .onSubmit { navigation.saveEdit() }.padding(8).background(BavbavTheme.surface.panelBackdrop())
            if let error = navigation.editError { Text(error).font(BavbavTheme.mono(9)).foregroundStyle(BavbavTheme.warning) }
            Button("Save") { navigation.saveEdit() }.buttonStyle(.plain).foregroundStyle(BavbavTheme.accent)
        }
    }
}
