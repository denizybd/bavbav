import SwiftUI

extension Notification.Name {
    static let shortcutSearchRequested = Notification.Name("bavbav.shortcut-search")
}

struct ShortcutEditorView: View {
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var bindings: ShortcutSettings
    @State private var confirmReset = false
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(spacing: 7) {
            if let id = bindings.editingID,
               let definition = ShortcutCatalog.all.first(where: { $0.id == id }) {
                recorder(definition)
            } else {
                HStack(spacing: 7) {
                    TextField("İşlem, pencere veya tuş ara", text: $preferences.shortcutSearch)
                        .textFieldStyle(.plain).font(BavbavTheme.mono(10))
                        .padding(7).background(BavbavTheme.surface.panelBackdrop()).cornerRadius(4)
                        .accessibilityLabel("Kısayol ara")
                        .focused($searchFocused)
                    Button { confirmReset = true } label: {
                        Image(systemName: "arrow.counterclockwise").padding(6)
                    }.buttonStyle(.plain).help("Bütün kısayolları varsayılana döndür")
                }
                if let error = bindings.error { notice(error) }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(preferences.filteredShortcuts.enumerated()), id: \.element.id) { index, definition in
                                Button {
                                    preferences.selectedIndex = index
                                    bindings.beginRecording(definition.id)
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(definition.group.uppercased())
                                            .font(BavbavTheme.mono(7)).foregroundStyle(BavbavTheme.muted).readableForeground()
                                        HStack(alignment: .top, spacing: 8) {
                                            Text(definition.title)
                                                .font(BavbavTheme.mono(9)).foregroundStyle(BavbavTheme.text).readableForeground()
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            Text(bindings.binding(definition).label)
                                                .font(BavbavTheme.mono(9, weight: .semibold))
                                                .foregroundStyle(bindings.binding(definition).disabled ? BavbavTheme.muted : BavbavTheme.accent)
                                                .readableForeground().multilineTextAlignment(.trailing)
                                                .frame(maxWidth: 125, alignment: .trailing)
                                        }
                                        if bindings.overrides[definition.id] != nil {
                                            Text("ÖZEL").font(BavbavTheme.mono(6)).foregroundStyle(BavbavTheme.accent).readableForeground()
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                                    .background((preferences.selectedIndex == index ? BavbavTheme.raised : BavbavTheme.surface).panelBackdrop())
                                    .cornerRadius(4).contentShape(Rectangle())
                                }.buttonStyle(.plain).id(index)
                                    .accessibilityLabel("\(definition.group), \(definition.title), \(bindings.binding(definition).label)")
                            }
                            if preferences.filteredShortcuts.isEmpty { Text("Eşleşen işlem yok.").font(BavbavTheme.mono(9)) }
                            Text("⌘Tab macOS’a aittir. Tuşlar fiziksel konumlarıyla kaydedilir. Birleştirilmiş tuşlar birlikte basılır; her alternatif ayrı satırdır.")
                                .font(BavbavTheme.mono(8)).foregroundStyle(BavbavTheme.muted).readableForeground().padding(.vertical, 7)
                        }
                    }.clipped()
                    .onChange(of: preferences.selectedIndex) { index in proxy.scrollTo(index) }
                }
            }
        }
        .padding(11)
        .foregroundStyle(BavbavTheme.text)
        .onReceive(NotificationCenter.default.publisher(for: .shortcutSearchRequested)) { note in
            if note.object as? AppPreferences === preferences { searchFocused = true }
        }
        .onChange(of: bindings.editingID) { id in if id != nil { searchFocused = false } }
        .alert("Bütün kısayollar sıfırlansın mı?", isPresented: $confirmReset) {
            Button("Vazgeç", role: .cancel) {}
            Button("Sıfırla", role: .destructive) { _ = bindings.resetAll() }
        } message: { Text("Yalnızca klavye atamaları sıfırlanır. Sohbetler ve diğer ayarlar değişmez.") }
    }
    private func notice(_ value: String) -> some View {
        Text(value).font(BavbavTheme.mono(9)).foregroundStyle(BavbavTheme.warning).readableForeground()
            .fixedSize(horizontal: false, vertical: true)
    }
    private func recorder(_ definition: ShortcutDefinition) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 11) {
                Text(definition.group.uppercased()).font(BavbavTheme.mono(8)).foregroundStyle(BavbavTheme.muted)
                Text(definition.title).font(BavbavTheme.mono(11, weight: .medium))
                Text(bindings.recording ? "TUŞLARA BAS, SONRA BIRAK" : "YENİ ATAMA")
                    .font(BavbavTheme.mono(8)).foregroundStyle(BavbavTheme.muted)
                Text(bindings.candidate?.label ?? "—")
                    .font(BavbavTheme.mono(19, weight: .light)).foregroundStyle(BavbavTheme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .background(BavbavTheme.surface.panelBackdrop()).cornerRadius(5)
                if definition.defaultBinding.hold {
                    HStack {
                        Text("Basılı tutma süresi").font(BavbavTheme.mono(9))
                        Spacer()
                        Text("\(bindings.candidate?.holdMilliseconds ?? 440) ms").font(BavbavTheme.mono(10))
                    }
                    Slider(value: Binding(get: { Double(bindings.candidate?.holdMilliseconds ?? 440) },
                        set: { bindings.candidate?.holdMilliseconds = Int($0) }), in: 200...2000, step: 20)
                        .tint(BavbavTheme.accent).disabled(bindings.recording)
                }
                if let error = bindings.error { notice(error) }
                HStack {
                    Button("Uygula") { _ = bindings.applyCandidate() }.disabled(bindings.recording)
                    Button("Yeniden kaydet") { bindings.recordAgain() }
                    Button("Vazgeç") { bindings.cancelEditing() }
                }.buttonStyle(ShortcutEditorButtonStyle())
                HStack {
                    Button("Bu kısayolu kapat") {
                        var value = bindings.binding(definition); value.disabled = true
                        if bindings.set(definition.id, value) { bindings.cancelEditing() }
                    }
                    Button("Varsayılan") {
                        if bindings.set(definition.id, nil) { bindings.cancelEditing() }
                    }
                }.buttonStyle(ShortcutEditorButtonStyle()).disabled(bindings.recording)
                Text(bindings.recording
                     ? "Kayıt sırasında Q ve Enter da atanabilir. İptal için Vazgeç’e tıkla. Command Tab kaydı iptal eder."
                     : "\(bindings.label("prefs.confirm.applyShortcut.key")) uygula · \(bindings.label("prefs.confirm.cancelShortcut.key")) vazgeç · \(bindings.label("prefs.confirm.recordShortcut.key")) tekrar kaydet\n\(bindings.label("prefs.confirm.disableShortcut.key")) kapat · \(bindings.label("prefs.confirm.resetShortcut.key")) varsayılan\nÖzgün atama: \(definition.keys)")
                    .font(BavbavTheme.mono(8)).foregroundStyle(BavbavTheme.muted)
            }.readableForeground().frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minHeight: 0, maxHeight: .infinity).clipped()
    }
}

private struct ShortcutEditorButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(BavbavTheme.mono(9, weight: .medium))
            .foregroundStyle(enabled ? BavbavTheme.text : BavbavTheme.muted).readableForeground()
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background((configuration.isPressed ? BavbavTheme.raised : BavbavTheme.surface).panelBackdrop())
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(BavbavTheme.border,lineWidth:0.7))
    }
}
