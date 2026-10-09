import SwiftUI

/// The host supplies its palette and background preference; no content-wide alpha is applied.
public struct CompanionPanelAppearance {
    public let background: Color
    public let surface: Color
    public let raised: Color
    public let border: Color
    public let text: Color
    public let muted: Color
    public let accent: Color
    public let danger: Color
    public let backgroundOpacity: Double
    public let foregroundStrength: Double

    public init(background: Color = Color(red: 0.043, green: 0.051, blue: 0.063),
                surface: Color = Color(red: 0.070, green: 0.082, blue: 0.102),
                raised: Color = Color(red: 0.090, green: 0.106, blue: 0.129),
                border: Color = Color(red: 0.145, green: 0.165, blue: 0.200),
                text: Color = Color(red: 0.847, green: 0.875, blue: 0.914),
                muted: Color = Color(red: 0.470, green: 0.510, blue: 0.565),
                accent: Color = Color(red: 0.314, green: 0.886, blue: 0.722),
                danger: Color = Color(red: 0.930, green: 0.365, blue: 0.420),
                backgroundOpacity: Double = 1, foregroundStrength: Double? = nil) {
        self.background = background; self.surface = surface; self.raised = raised
        self.border = border; self.text = text; self.muted = muted; self.accent = accent; self.danger = danger
        self.backgroundOpacity = backgroundOpacity.isFinite ? min(1, max(0, backgroundOpacity)) : 1
        let contrast = foregroundStrength ?? (0.65 - self.backgroundOpacity) / 0.65
        self.foregroundStrength = contrast.isFinite ? min(1, max(0, contrast)) : 0
    }
}

public struct CompanionPanelView: View {
    @ObservedObject private var session: CompanionSession
    @ObservedObject private var speech: CompanionSpeech
    @ObservedObject private var control: CompanionDesktopControl
    private let appearance: CompanionPanelAppearance
    private let onStop: (() -> Void)?
    @State private var showingAdvanced = false
    @State private var integratedStartTask: Task<Void, Never>?
    @State private var integratedStartGeneration = UUID()

    public init(session: CompanionSession, appearance: CompanionPanelAppearance = CompanionPanelAppearance(),
                onStop: (() -> Void)? = nil) {
        self.session = session; self.speech = session.speech
        self.control = session.desktopControl
        self.appearance = appearance
        self.onStop = onStop
    }

    private var integratedActive: Bool {
        session.connected && session.voiceConversationActive && session.screenSharing && control.enabled
    }

    private var integratedStartTitle: String {
        session.integratedStarting ? "Başlatılıyor · izinler beklenebilir…"
            : integratedActive ? "Ses + ekran + imleç açık" : "Ses + ekran + imleci başlat"
    }

    private let stopTitle = "BİTİR / STOP"
    private let advancedTitle = "Gelişmiş"
    private var separateVoiceTitle: String {
        session.voiceConversationActive ? "Yalnızca sesli sohbeti durdur" : "Sesli sohbeti ayrı başlat"
    }
    private let startDisclosureText = "Başlat, mikrofonu ve Türkçe sesli sohbeti açar; seçili fiziksel ekranın (seçilmediyse ana ekranın) tamamını mevcut hesabın üzerinden modele paylaşır ve görünür uygulamalarda istediğin sıradan tıklamalara izin verir. Açık uygulamalar, bildirimler ve görünür özel bilgiler de paylaşılır. STOP bunların hepsini durdurur."

    public var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 22).padding(.vertical, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    integratedStart
                    liveState
                    voiceActivity
                    if let data = session.preview, let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .accessibilityLabel("En son hazırlanan tam ekran karesi")
                            .accessibilityIdentifier("companion.screenPreview")
                    }
                    if !session.lines.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(session.lines) { line in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(line.speaker).font(.system(.caption, design: .monospaced).bold()).foregroundStyle(appearance.accent)
                                    Text(line.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }.modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
                            }
                        }.padding(14).background(appearance.surface.opacity(appearance.backgroundOpacity), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(appearance.border, lineWidth: 1))
                    }
                    messageComposer
                    DisclosureGroup(advancedTitle, isExpanded: $showingAdvanced) {
                        advancedControls.padding(.top, 12)
                    }
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
                    .accessibilityIdentifier("companion.advanced")
                    .background(CompanionPanelLayoutProbe(identifier: "companion.advanced", text: advancedTitle, value: showingAdvanced))
                }.padding(.horizontal, 22).padding(.bottom, 22)
            }
            .scrollContentBackground(.hidden)
        }
        .background(appearance.background.opacity(appearance.backgroundOpacity))
        .foregroundStyle(appearance.text)
        .preferredColorScheme(.dark)
        .tint(appearance.accent)
        .toggleStyle(.checkbox)
        .buttonStyle(CompanionButtonStyle(appearance: appearance))
        .onDisappear { cancelPendingIntegratedStart() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text("COMPANION").font(.system(.title2, design: .monospaced).bold()).foregroundStyle(appearance.accent)
                Text("SES + EKRAN + SANAL İMLEÇ").font(.system(.caption, design: .monospaced)).foregroundStyle(appearance.muted)
            }.modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
            Spacer()
            Button(stopTitle, role: .destructive) {
                cancelPendingIntegratedStart()
                if let onStop { onStop() } else { session.stop() }
            }
            .help("Mikrofonu, ekran paylaşımını, sanal imleci, tıklamaları ve sesi durdurur. Diğer sohbetlere dokunmaz.")
            .accessibilityIdentifier("companion.stopAll")
            .background(CompanionPanelLayoutProbe(identifier: "companion.stopAll", text: stopTitle))
        }
    }

    private var integratedStart: some View {
        section("BİRLİKTE BAŞLAT") {
            VStack(alignment: .leading, spacing: 11) {
                Text(startDisclosureText)
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                    .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
                    .accessibilityIdentifier("companion.startDisclosure")
                    .background(CompanionPanelLayoutProbe(identifier: "companion.startDisclosure", text: startDisclosureText))
                if !session.displays.isEmpty { displayMenu }
                Button(action: beginIntegratedStart) {
                    Text(integratedStartTitle)
                        .frame(maxWidth: .infinity, minHeight: 24)
                }
                .background(CompanionPanelLayoutProbe(identifier: "companion.integratedStart", text: integratedStartTitle))
                .disabled(integratedActive || integratedStartTask != nil || session.integratedStarting || session.stopping || session.connecting || session.sending || session.capturing || (speech.dictationBusy && !session.voiceConversationActive))
                .help("Bu düğme sesli sohbeti, tam ekran paylaşımını ve istediğin sıradan tıklamaları birlikte başlatır. Gerekli macOS izinlerini sen verirsin.")
                .accessibilityIdentifier("companion.integratedStart")
                Text(session.integratedStatus).font(.callout).textSelection(.enabled)
                    .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
                    .accessibilityIdentifier("companion.integratedStatus")
                if !speech.supportsLocalTurkish {
                    Toggle("Cihaz içi Türkçe yoksa sesimi Apple konuşma hizmetine göndermeye izin ver", isOn: $session.allowAppleService)
                        .font(.caption)
                        .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
                        .onChange(of: session.allowAppleService) {
                            if !$0 { session.pauseVoiceConversation(); speech.stopListening() }
                        }
                    Text("Bu seçenek isteğe bağlıdır; otomatik açılmaz. Türkçe tanıma için Apple hizmeti gerekiyorsa bu izin olmadan mikrofon başlatılmaz.")
                        .font(.caption).foregroundStyle(appearance.muted)
                        .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
                }
                Text("macOS Türkçe konuşma → mevcut Codex hesabı → Mac sesi. ChatGPT'nin yerleşik Voice özelliği değildir; API anahtarı gerektirmez.")
                    .font(.caption).foregroundStyle(appearance.muted)
                    .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
            }
        }
    }

    private func beginIntegratedStart() {
        guard integratedStartTask == nil, !session.integratedStarting else { return }
        let generation = UUID()
        let displayID = session.displaySelection?.id
        integratedStartGeneration = generation
        integratedStartTask = Task { @MainActor in
            guard !Task.isCancelled, integratedStartGeneration == generation else { return }
            await session.startIntegratedSession(preferredDisplayID: displayID)
            guard !Task.isCancelled, integratedStartGeneration == generation else { return }
            integratedStartTask = nil
        }
    }

    private func cancelPendingIntegratedStart() {
        integratedStartGeneration = UUID()
        integratedStartTask?.cancel()
        integratedStartTask = nil
    }

    private var liveState: some View {
        VStack(alignment: .leading, spacing: 8) {
            stateLine(session.connected ? "● HESAP BAĞLI" : session.connecting ? "○ HESABA BAĞLANIYOR" : "○ HESAP BAĞLI DEĞİL",
                      active: session.connected, identifier: "companion.accountState")
            stateLine(session.screenSharing ? "● EKRAN PAYLAŞIMI AÇIK" : "○ EKRAN KAPALI · Ses + ekran + imleci başlat düğmesini kullan",
                      active: session.screenSharing, identifier: "companion.screenSharing")
            if let captured = session.lastCapturedAt {
                Text("Son kare: \(captured.formatted(date: .omitted, time: .standard)) · konuşmanla veya mesajınla birlikte gönderilir")
                    .font(.caption).foregroundStyle(appearance.muted)
                    .accessibilityIdentifier("companion.capturedFrameStatus")
            } else {
                Text(session.screenSharing ? "Henüz güncel kare hazırlanmadı." : "Ekran karesi alınmıyor veya gönderilmiyor.")
                    .font(.caption).foregroundStyle(appearance.muted)
                    .accessibilityIdentifier("companion.capturedFrameStatus")
            }
            if let sharedAt = session.lastSharedAt {
                Text("Görüntülü son yanıt: \(sharedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(appearance.muted)
            }
            stateLine(control.enabled ? "● SANAL İMLEÇ KONTROLÜ AÇIK" : "○ SANAL İMLEÇ KONTROLÜ KAPALI",
                      active: control.enabled, identifier: "companion.controlState")
            Text(control.status).font(.caption).textSelection(.enabled)
                .accessibilityIdentifier("companion.desktopControlStatus")
            stateLine(speech.listening ? "● MİKROFON DİNLİYOR" : speech.dictationBusy ? "○ KONUŞMA HAZIRLANIYOR / TAMAMLANIYOR" : "○ MİKROFON KAPALI",
                      active: speech.listening, identifier: "companion.microphoneState")
            Text(session.status).font(.caption).textSelection(.enabled)
                .accessibilityIdentifier("companion.status")
        }
        .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
        .padding(11).frame(maxWidth: .infinity, alignment: .leading)
        .background(appearance.surface.opacity(appearance.backgroundOpacity), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(appearance.border, lineWidth: 1))
    }

    @ViewBuilder private var voiceActivity: some View {
        if session.voiceConversationActive || !session.voiceTranscript.isEmpty || !session.liveReply.isEmpty {
            section("KONUŞMA") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(session.voiceStatus).font(.callout).textSelection(.enabled)
                        .accessibilityIdentifier("companion.voiceStatus")
                    if session.voiceConversationActive && speech.listening {
                        Button("Konuşmayı bitir · yanıtla") { session.finishDictation() }
                            .help("Sessizlik algısını beklemeden söylediğin metni tamamlayıp gönderir.")
                            .accessibilityIdentifier("companion.finishVoiceTurn")
                    }
                    if !session.voiceTranscript.isEmpty {
                        activityText("SEN · TANINAN KONUŞMA", text: session.voiceTranscript, identifier: "companion.voiceTranscript")
                    }
                    if session.sending && !session.liveReply.isEmpty {
                        activityText("CODEX · CANLI YANIT", text: session.liveReply, identifier: "companion.liveReply")
                    }
                    Text("Konuşman bitince otomatik gönderilir; yanıt seslendirilir, ardından mikrofon yeniden açılır. Yanıt okunurken mikrofon kapalıdır.")
                        .font(.caption).foregroundStyle(appearance.muted)
                }.modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
            }
        }
    }

    private var messageComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("YAZILI MESAJ").font(.system(.caption, design: .monospaced)).foregroundStyle(appearance.accent)
                .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
            TextEditor(text: $session.draft).font(.body).frame(minHeight: 70, maxHeight: 140)
                .scrollContentBackground(.hidden)
                .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
                .padding(8)
                .background(appearance.raised.opacity(appearance.backgroundOpacity), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(appearance.border, lineWidth: 1))
                .disabled(session.voiceConversationActive || session.sending || speech.dictationBusy || session.integratedStarting)
                .accessibilityLabel("Companion mesajı")
            HStack {
                Text(session.voiceConversationActive ? "Sesli sohbet açık · yazılı taslağın korunuyor." : "Yazılı taslak yalnızca Gönder'e bastığında gider.")
                    .font(.caption).foregroundStyle(appearance.muted)
                    .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
                Spacer()
                Button(session.sending ? "Yanıt bekleniyor…" : "Gönder") { Task { await session.send() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(session.voiceConversationActive || session.integratedStarting || !session.connected || session.sending || session.capturing || session.stopping || speech.dictationBusy || (session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !session.includePreview))
            }
        }
    }

    private var displayMenu: some View {
        Menu {
            ForEach(session.displays) { display in
                Button(display.label) { session.selectDisplay(display) }
            }
        } label: {
            HStack {
                Text("Paylaşılacak ekran: \(session.displaySelection?.label ?? "ana fiziksel ekran")").lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
            }
            .font(.system(size: 12, design: .monospaced))
            .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
            .padding(8)
            .background(appearance.raised.opacity(appearance.backgroundOpacity), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(appearance.border, lineWidth: 1))
        }.menuStyle(.borderlessButton)
        .accessibilityLabel("Tamamı paylaşılacak fiziksel ekran")
        .disabled(session.integratedStarting || session.screenSharing || session.capturing || session.stopping)
    }

    private var advancedControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            section("AYRI SES KONTROLLERİ") {
                VStack(alignment: .leading, spacing: 10) {
                    Button(session.connected ? "Hesap bağlı" : "Hesaba bağlan") { Task { await session.connect() } }
                        .disabled(session.connected || session.connecting || session.stopping || session.integratedStarting)
                    Button(separateVoiceTitle) {
                        if session.voiceConversationActive { session.pauseVoiceConversation() }
                        else { Task { await session.startVoiceConversation() } }
                    }
                    .background(CompanionPanelLayoutProbe(identifier: "companion.voiceConversation", text: separateVoiceTitle))
                    .disabled(session.integratedStarting || (!session.voiceConversationActive && (session.stopping || session.connecting || session.sending || session.capturing || speech.dictationBusy)))
                    .accessibilityIdentifier("companion.voiceConversation")
                    HStack {
                        Button(speech.finalizing ? "Metin tamamlanıyor…" : (speech.listening ? "Metne yazmayı bitir" : "Yalnızca metne yaz")) {
                            if speech.listening { session.finishDictation() }
                            else { Task { await session.startListening() } }
                        }.disabled(session.integratedStarting || session.voiceConversationActive || session.sending || session.capturing || session.connecting || session.stopping || speech.preparing || speech.finalizing)
                        Button("Sustur") { session.mute() }
                            .disabled(session.integratedStarting || (!speech.dictationBusy && !session.voiceConversationActive))
                        Button("Yanıt sesini durdur") { session.stopReplyAudio() }
                            .disabled(!speech.speaking && !session.voiceConversationActive)
                    }
                    if !session.voiceConversationActive { Text(speech.status).font(.caption).foregroundStyle(appearance.muted) }
                    Toggle("Yanıtları Türkçe seslendir", isOn: $session.speakReplies)
                        .disabled(session.integratedStarting)
                        .onChange(of: session.speakReplies) {
                            if !$0 { session.pauseVoiceConversation(); session.stopReplyAudio() }
                        }
                    Button("Türkçe sesi dene") { speech.speak("Merhaba Deniz. Bavbav ses denemesi. Beni duyabiliyor musun?") }
                        .disabled(session.integratedStarting || session.voiceConversationActive || session.sending || session.stopping || speech.dictationBusy)
                        .help("Yalnızca Mac ses çıkışı denemesidir; gerçek sohbet yanıtı değildir.")
                    Text("Mac sesi: \(speech.selectedVoiceName) · \(speech.selectedVoiceQuality)")
                        .font(.caption).foregroundStyle(appearance.muted)
                    if let seconds = session.firstReplySeconds {
                        Text(String(format: "İlk yanıt: %.1f sn", seconds) + (session.replySeconds.map { String(format: " · tamamlanma: %.1f sn", $0) } ?? ""))
                            .font(.system(.caption, design: .monospaced)).foregroundStyle(appearance.muted)
                            .accessibilityIdentifier("companion.replyLatency")
                    }
                    if let seconds = session.firstAudioSeconds {
                        Text("Gerçek ses başlangıcı: \(seconds, specifier: "%.1f") sn")
                            .font(.system(.caption, design: .monospaced)).foregroundStyle(appearance.muted)
                            .accessibilityIdentifier("companion.firstAudioLatency")
                    }
                }
            }
            section("EKRAN VE İMLEÇ AYARLARI") {
                VStack(alignment: .leading, spacing: 10) {
                    Button(session.requestingScreenPermission ? "İzin bekleniyor…" : "Ekranları göster / yenile") {
                        Task { await session.listDisplays() }
                    }
                    .disabled(session.integratedStarting || session.requestingScreenPermission || session.capturing || session.screenSharing || session.stopping)
                    .help("Ekran listesini yeniler ve macOS Ekran Kaydı iznini sorabilir. Paylaşımı başlatmaz.")
                    Stepper(value: $session.screenShareInterval, in: 3...60, step: 1) {
                        Text("Kareler arasında en az \(Int(session.screenShareInterval)) saniye")
                            .font(.system(size: 12, design: .monospaced))
                    }.accessibilityLabel("Ekran paylaşımı aralığı, saniye")
                    Toggle("Ekran değişikliklerini ayrıca kendiliğinden yorumla", isOn: $session.observeScreenChanges)
                        .disabled(control.enabled || session.integratedStarting)
                    Text("Kapalıyken son kare konuşmana veya mesajına eklenir. Açarsan ayrıca ekran yorumları üretilir; hesap kullanımı ve bekleme artabilir.")
                        .font(.caption).foregroundStyle(appearance.muted)
                    HStack {
                        Button("Yalnızca ekran paylaşımını durdur", role: .destructive) { session.stopScreenSharing() }
                            .disabled(!session.screenSharing)
                        Button("Yalnızca kontrolü durdur", role: .destructive) { session.stopDesktopControl() }
                            .disabled(!control.enabled)
                    }
                    Text("Sanal imleç istediğin sıradan tıklamaları uygular. Gerçek giriş sistemi ortaktır; bağımsız ikinci donanım imleci değildir. Klavye/yazma, satın alma, silme ve güvenlik izinleri uygulanmaz. Logic Pro özel miks otomasyonu hazır değildir.")
                        .font(.caption).foregroundStyle(appearance.muted)
                    Text("Gerekli Ekran Kaydı, Erişilebilirlik, Mikrofon ve Konuşma Tanıma izinlerini macOS'ta sen verirsin. Video veya sistem sesi kaydedilmez. Yalnızca son kare tutulur; STOP ya da pencereyi kapatma yeni kareleri ve tıklamaları keser. Önceden gönderilen kareler geri alınmaz.")
                        .font(.caption).foregroundStyle(appearance.muted)
                }
            }
        }.modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
    }

    private func stateLine(_ text: String, active: Bool, identifier: String) -> some View {
        Text(text).font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(active ? appearance.accent : appearance.text)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(identifier)
    }

    private func activityText(_ title: String, text: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(.caption, design: .monospaced).bold()).foregroundStyle(appearance.accent)
            Text(text).font(.callout).lineLimit(8).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(appearance.raised.opacity(appearance.backgroundOpacity), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(appearance.border, lineWidth: 1))
        .accessibilityIdentifier(identifier)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(.caption, design: .monospaced).bold()).foregroundStyle(appearance.accent)
                .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
            content()
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(appearance.surface.opacity(appearance.backgroundOpacity), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(appearance.border, lineWidth: 1))
    }
}

/// SwiftUI omits its semantic accessibility children while a window is hidden.
/// These transparent, noninteractive native backgrounds preserve the real laid-out
/// bounds and live labels for hidden rendering checks without presenting a window.
private struct CompanionPanelLayoutProbe: View {
    let identifier: String
    let text: String
    var value: Bool? = nil
    private static let checking = ProcessInfo.processInfo.environment["BAVBAV_COMPANION_WINDOW_CHECK"] == "1"
    @ViewBuilder var body: some View {
        if Self.checking {
            CompanionPanelNativeLayoutProbe(identifier: identifier, text: text, value: value)
        }
    }
}

private struct CompanionPanelNativeLayoutProbe: NSViewRepresentable {
    let identifier: String
    let text: String
    let value: Bool?
    @Environment(\.isEnabled) private var enabled
    func makeNSView(context: Context) -> CompanionPanelLayoutMarker {
        let view = CompanionPanelLayoutMarker()
        view.setAccessibilityElement(false)
        return view
    }
    func updateNSView(_ view: CompanionPanelLayoutMarker, context: Context) {
        view.identifier = NSUserInterfaceItemIdentifier(identifier)
        view.setAccessibilityLabel(text)
        view.setAccessibilityEnabled(enabled)
        view.setAccessibilityValue(value.map { NSNumber(value: $0) })
    }
}

private final class CompanionPanelLayoutMarker: NSView {
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct CompanionReadableForeground: ViewModifier {
    let strength: Double
    func body(content: Content) -> some View {
        if strength > 0 {
            content.brightness(0.22 * strength)
                .shadow(color: .black.opacity(0.95 * strength), radius: 0.4 * strength)
                .shadow(color: .black.opacity(0.9 * strength), radius: 1.4 * strength)
        } else { content }
    }
}

private struct CompanionButtonStyle: ButtonStyle {
    let appearance: CompanionPanelAppearance
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(enabled ? (configuration.role == .destructive ? appearance.danger : appearance.text) : appearance.muted)
            .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background((configuration.isPressed ? appearance.raised : appearance.background)
                .opacity(appearance.backgroundOpacity), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(configuration.role == .destructive ? appearance.danger : appearance.border, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 5))
    }
}
