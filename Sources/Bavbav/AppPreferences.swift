import Combine
import Foundation

enum AppPreferencesPage: Equatable {
    case home
    case shortcuts
    case appearance
}

/// Local application preferences, independent of the active chat's model settings.
@MainActor
final class AppPreferences: ObservableObject {
    static let transparencyKey = "appearance.window-transparency-percent"

    @Published private(set) var transparencyPercent: Double
    var backgroundOpacity: Double { 1 - transparencyPercent / 100 }
    @Published var page: AppPreferencesPage = .home
    @Published var selectedIndex = 0
    @Published var shortcutSearch = "" { didSet { selectedIndex = 0 } }
    let keyBindings: ShortcutSettings
    private var bindingsSubscription: AnyCancellable?
    var filteredShortcuts: [ShortcutDefinition] {
        let query = shortcutSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.shortcuts.filter {
            query.isEmpty || "\($0.group) \($0.title) \(keyBindings.binding($0).label)"
                .localizedStandardContains(query)
        }
    }

    var onTransparencyChanged: ((Double) -> Void)?
    private let defaults: UserDefaults

    static let shortcuts = ShortcutCatalog.all

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        keyBindings = ShortcutSettings(defaults: defaults)
        if let saved = defaults.object(forKey: Self.transparencyKey) as? NSNumber,
           saved.doubleValue.isFinite {
            transparencyPercent = min(100, max(0, saved.doubleValue)).rounded()
        } else {
            transparencyPercent = 0
        }
        bindingsSubscription = keyBindings.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func setTransparency(_ percent: Double) {
        guard percent.isFinite else { return }
        let value = min(100, max(0, percent)).rounded()
        guard value != transparencyPercent else { return }
        transparencyPercent = value
        defaults.set(value, forKey: Self.transparencyKey)
        onTransparencyChanged?(value)
    }

    func adjustTransparency(delta: Double) {
        setTransparency(transparencyPercent + delta)
    }

    func resetTransparency() {
        setTransparency(0)
    }

    func moveSelection(delta: Int) {
        switch page {
        case .home:
            selectedIndex = min(1, max(0, selectedIndex + delta))
        case .shortcuts:
            selectedIndex = max(0, min(filteredShortcuts.count - 1, max(0, selectedIndex + delta)))
        case .appearance:
            // Match the slider: W/up decreases, S/down increases transparency.
            adjustTransparency(delta: Double(delta) * 5)
        }
    }

    func activateSelection() {
        switch page {
        case .home:
            page = selectedIndex == 0 ? .shortcuts : .appearance
            selectedIndex = 0
        case .shortcuts:
            guard filteredShortcuts.indices.contains(selectedIndex) else { return }
            keyBindings.beginRecording(filteredShortcuts[selectedIndex].id)
        case .appearance:
            resetTransparency()
        }
    }

    /// Returning false tells the window controller that Q may close this panel.
    @discardableResult
    func goBack() -> Bool {
        keyBindings.cancelEditing()
        guard page != .home else { return false }
        selectedIndex = page == .shortcuts ? 0 : 1
        page = .home
        return true
    }
}
