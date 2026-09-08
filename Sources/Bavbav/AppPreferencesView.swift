import SwiftUI

struct AppPreferencesView: View {
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        VStack(spacing: 0) {
            header.fixedSize(horizontal: false, vertical: true).layoutPriority(1)
            separator
            Group {
                switch preferences.page {
                case .home: home
                case .shortcuts: ShortcutEditorView(preferences: preferences, bindings: preferences.keyBindings)
                case .appearance: appearance
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
            .clipped()
            separator
            footer.fixedSize(horizontal: false, vertical: true).layoutPriority(1)
        }
        .background(BavbavTheme.background.panelBackdrop())
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(BavbavTheme.border, lineWidth: 1)
        }
        .preferredColorScheme(.dark)
    }

    private var title: String {
        switch preferences.page {
        case .home: return "AYARLAR"
        case .shortcuts: return "SHORTCUTS"
        case .appearance: return "GÖRÜNÜM"
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Text(preferences.keyBindings.label("*.preferences.key"))
                .font(BavbavTheme.mono(10, weight: .bold))
                .foregroundStyle(BavbavTheme.accent).readableForeground()
                .frame(minWidth: 29, minHeight: 26)
                .background(BavbavTheme.accent.opacity(0.09).panelBackdrop())
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(BavbavTheme.mono(11, weight: .semibold))
                    .foregroundStyle(BavbavTheme.text).readableForeground()
                Text("BAVBAV / APPLICATION")
                    .font(BavbavTheme.mono(7, weight: .medium))
                    .foregroundStyle(BavbavTheme.muted).readableForeground()
            }
            Spacer(minLength: 4)
            if preferences.page != .home {
                Button { preferences.goBack() } label: {
                    Text("← GERİ")
                        .font(BavbavTheme.mono(8, weight: .bold))
                        .foregroundStyle(BavbavTheme.muted).readableForeground()
                        .padding(7)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Ayarların ana sayfasına dön")
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 53)
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: 8) {
            preferenceRow(index: 0, title: "Shortcuts", subtitle: "Klavye kısayolları", symbol: "keyboard")
            preferenceRow(index: 1, title: "Görünüm", subtitle: "Arka plan saydamlığı", symbol: "circle.lefthalf.filled")
            Spacer(minLength: 2)
            HStack(spacing: 5) {
                Circle().fill(BavbavTheme.accent).frame(width: 4, height: 4)
                Text("Değişiklikler otomatik kaydedilir.")
                    .font(BavbavTheme.mono(8))
                    .foregroundStyle(BavbavTheme.muted).readableForeground()
            }
        }
        .padding(12)
    }

    private func preferenceRow(index: Int, title: String, subtitle: String, symbol: String) -> some View {
        let selected = preferences.selectedIndex == index
        return Button {
            preferences.selectedIndex = index
            preferences.activateSelection()
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(selected ? BavbavTheme.accent : .clear)
                    .frame(width: 3, height: 27)
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(selected ? BavbavTheme.accent : BavbavTheme.muted).readableForeground()
                    .frame(width: 23)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(BavbavTheme.mono(12, weight: .medium))
                        .foregroundStyle(BavbavTheme.text).readableForeground()
                    Text(subtitle)
                        .font(BavbavTheme.mono(9))
                        .foregroundStyle(BavbavTheme.muted).readableForeground()
                }
                Spacer(minLength: 0)
                Text("›")
                    .font(BavbavTheme.mono(17))
                    .foregroundStyle(selected ? BavbavTheme.accent : BavbavTheme.muted).readableForeground()
            }
            .padding(.horizontal, 9)
            .frame(height: 63)
            .frame(maxWidth: .infinity)
            .background(selected ? BavbavTheme.raised : BavbavTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }


    private var appearance: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ARKA PLAN SAYDAMLIĞI")
                            .font(BavbavTheme.mono(9, weight: .semibold))
                            .foregroundStyle(BavbavTheme.text).readableForeground()
                        Text("Tüm sohbet ve köşe pencereleri")
                            .font(BavbavTheme.mono(8))
                            .foregroundStyle(BavbavTheme.muted).readableForeground()
                    }
                    Spacer(minLength: 4)
                    Text("%\(Int(preferences.transparencyPercent))")
                        .font(BavbavTheme.mono(28, weight: .light))
                        .foregroundStyle(BavbavTheme.accent).readableForeground()
                        .monospacedDigit()
                }
                VStack(spacing: 5) {
                    Slider(value: Binding(
                        get: { preferences.transparencyPercent },
                        set: { preferences.setTransparency($0) }
                    ), in: 0...100)
                    .tint(BavbavTheme.accent)
                    .accessibilityLabel("Arka plan saydamlığı")
                    .accessibilityValue("Yüzde \(Int(preferences.transparencyPercent))")
                    HStack {
                        Text("%0 · OPAK")
                        Spacer()
                        Text("%100 · ŞEFFAF ZEMİN")
                    }
                    .font(BavbavTheme.mono(7, weight: .medium))
                    .foregroundStyle(BavbavTheme.muted).readableForeground()
                }
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(BavbavTheme.accent).readableForeground()
                    Text("Zemin saydamlaşır; yazılar solmaz. Yüksek saydamlıkta otomatik kontrast ve ince koyu gölge okunurluğu destekler. %100’de de kontroller çalışır.")
                        .font(BavbavTheme.mono(8))
                        .foregroundStyle(BavbavTheme.muted).readableForeground()
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(BavbavTheme.surface.panelBackdrop())
                .clipShape(RoundedRectangle(cornerRadius: 5))
                Button { preferences.resetTransparency() } label: {
                    HStack(spacing: 6) {
                        Text(preferences.keyBindings.label("prefs.appearance.resetAppearance.space"))
                            .foregroundStyle(BavbavTheme.accent).readableForeground()
                        Text("Sıfırla · %0")
                            .foregroundStyle(BavbavTheme.text).readableForeground()
                    }
                    .font(BavbavTheme.mono(9, weight: .medium))
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    .background(BavbavTheme.raised.panelBackdrop())
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
            .padding(14)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if preferences.keyBindings.recording {
                footerKey("●", "TUŞ BEKLENİYOR")
            } else if preferences.keyBindings.editingID != nil {
                footerKey(preferences.keyBindings.label("prefs.confirm.applyShortcut.key"), "UYGULA")
                footerKey(preferences.keyBindings.label("prefs.confirm.recordShortcut.key"), "TEKRAR")
                footerKey(preferences.keyBindings.label("prefs.confirm.cancelShortcut.key"), "VAZGEÇ")
            } else {
            switch preferences.page {
            case .home:
                footerKey(preferences.keyBindings.label("prefs.home.down.key"), "SEÇ")
                footerKey(preferences.keyBindings.label("prefs.home.activatePreference.space"), "AÇ")
                footerKey(preferences.keyBindings.label("prefs.home.backPreference.key"), "KAPAT")
            case .shortcuts:
                footerKey(preferences.keyBindings.label("prefs.shortcuts.down.key"), "SEÇ")
                footerKey(preferences.keyBindings.label("prefs.shortcuts.activatePreference.key"), "DÜZENLE")
                footerKey(preferences.keyBindings.label("prefs.shortcuts.backPreference.key"), "GERİ")
            case .appearance:
                footerKey(preferences.keyBindings.label("prefs.appearance.less5.key"), "−5")
                footerKey(preferences.keyBindings.label("prefs.appearance.more5.key"), "+5")
                footerKey(preferences.keyBindings.label("prefs.appearance.resetAppearance.space"), "SIFIRLA")
                footerKey(preferences.keyBindings.label("prefs.appearance.backPreference.key"), "GERİ")
            }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
    }

    private func footerKey(_ key: String, _ action: String) -> some View {
        HStack(spacing: 3) {
            Text(key).foregroundStyle(BavbavTheme.text).readableForeground()
            Text(action).foregroundStyle(BavbavTheme.muted).readableForeground()
        }
        .font(BavbavTheme.mono(7, weight: .medium))
    }

    private var separator: some View {
        Rectangle().fill(BavbavTheme.border).frame(height: 1)
    }
}
