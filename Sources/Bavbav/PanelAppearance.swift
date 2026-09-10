import SwiftUI

private struct PanelBackdropOpacityKey: EnvironmentKey {
    static let defaultValue = 1.0
}
struct ShortcutLabels {
    var overrides: [String: ShortcutBinding] = [:]
    func key(_ id: String) -> String {
        if let value = overrides[id] { return value.label }
        return ShortcutCatalog.all.first { $0.id == id }?.keys ?? "—"
    }
    func list(_ scope: String, moving: Bool = false, create: Bool = false) -> [(String, String)] {
        let active = scope + (moving ? ".moving" : "")
        var items = [(key(active + ".up.key"), "↑"), (key(active + ".down.key"), "↓"),
                     (key(active + (moving ? ".commitOrder.key" : ".open.key")), moving ? "SAVE" : "OPEN")]
        if create && !moving { items.append((key(active + ".create.key"), "NEW")) }
        if !moving && scope != "standalone.launcher" { items.append((key(active + ".rename.key"), "NAME")) }
        items.append((key(active + ".close.key"), scope == "projects.chats" ? "BACK" : "CLOSE"))
        return items
    }
}
private struct ShortcutLabelsKey: EnvironmentKey {
    static let defaultValue = ShortcutLabels()
}

extension EnvironmentValues {
    var shortcutLabels: ShortcutLabels {
        get { self[ShortcutLabelsKey.self] }
        set { self[ShortcutLabelsKey.self] = newValue }
    }
    var panelBackdropOpacity: Double {
        get { self[PanelBackdropOpacityKey.self] }
        set { self[PanelBackdropOpacityKey.self] = newValue }
    }
}

/// Applies only to a background fill, never its text, border or controls.
private struct PanelBackdropModifier: ViewModifier {
    @Environment(\.panelBackdropOpacity) private var opacity
    func body(content: Content) -> some View { content.opacity(opacity) }
}

extension View {
    func panelBackdrop() -> some View { modifier(PanelBackdropModifier()) }
}

struct PanelAppearanceRoot<Content: View>: View {
    @ObservedObject var preferences: AppPreferences
    let content: Content

    var body: some View {
        content.environment(\.panelBackdropOpacity, preferences.backgroundOpacity)
            .environment(\.shortcutLabels, ShortcutLabels(overrides: preferences.keyBindings.overrides))
            .environment(\.locale, Locale(identifier: "en_US"))
    }
}
