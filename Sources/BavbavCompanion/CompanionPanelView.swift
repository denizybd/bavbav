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
    @State private var shareConsent = false
    @State private var controlConsent = false
    public init(session: CompanionSession, appearance: CompanionPanelAppearance = CompanionPanelAppearance(),
                onStop: (() -> Void)? = nil) {
        self.session = session; self.speech = session.speech
        self.control = session.desktopControl
        self.appearance = appearance
        self.onStop = onStop
    }
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("COMPANION").font(.system(.title2, design: .monospaced).bold()).foregroundStyle(appearance.accent)
                            .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
                        Text("SES + EKRAN + SANAL İMLEÇ").font(.system(.caption, design: .monospaced)).foregroundStyle(appearance.muted)
                            .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
                    }
                    Spacer()
                    Button("BİTİR / STOP", role: .destructive) {
                        shareConsent = false
                        controlConsent = false
                        if let onStop { onStop() } else { session.stop() }
                    }
                        .help("Mikrofonu, ekran paylaşımını, sanal imleci, tıklamaları ve sesi durdurur. Diğer sohbetlere dokunmaz.")
                }
                Text("macOS Türkçe konuşma → mevcut Codex hesabı → Mac sesi. Bu, ChatGPT'nin yerleşik Voice özelliği değildir.")
                    .font(.callout).foregroundStyle(appearance.muted)
                    .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
                Text(session.status).font(.callout).textSelection(.enabled).accessibilityIdentifier("companion.status")
                    .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
                HStack {
                    Button(session.connected ? "Hesap bağlı" : "Hesaba bağlan") { Task { await session.connect() } }
                        .disabled(session.connected || session.connecting || session.stopping)
                    Text("Mevcut hesabın kullanılıyor · API anahtarı gerekmiyor").font(.caption).foregroundStyle(appearance.muted)
                        .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
                }
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: session.screenSharing ? "eye.fill" : "eye.slash")
                    Text(session.screenSharing
                         ? "EKRAN AÇIK · Güncel kare konuşmana eklenir. Açık uygulamalar ve bildirimler de görünür. STOP paylaşımı ve kontrolü keser."
                         : "EKRAN KAPALI · Model şu anda ekranını görmüyor. Ekran Kaydı izni, onay ve Paylaşımı başlat gerekiyor.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(session.screenSharing ? appearance.accent : appearance.text)
                .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
                .padding(11).frame(maxWidth: .infinity, alignment: .leading)
                .background(appearance.surface.opacity(appearance.backgroundOpacity), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(session.screenSharing ? appearance.accent : appearance.border, lineWidth: 1))
                section("TÜRKÇE SES") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Button(session.voiceConversationActive ? "Sesli sohbeti bitir" : "Sesli sohbeti başlat") {
                                if session.voiceConversationActive { session.pauseVoiceConversation() }
                                else { Task { await session.startVoiceConversation() } }
                            }
                            .disabled(!session.voiceConversationActive && (session.stopping || session.connecting || session.sending || session.capturing || speech.dictationBusy))
                            .accessibilityIdentifier("companion.voiceConversation")
                            Spacer()
                            Text(session.voiceConversationActive ? "● SESLİ SOHBET" : "○ KAPALI")
                                .font(.system(.caption, design: .monospaced).bold())
                                .foregroundStyle(session.voiceConversationActive ? appearance.accent : appearance.muted)
                                .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
                        }
                        Text("Konuşman bitince otomatik gönderilir; gerçek yanıt seslendirilir, ardından mikrofon yeniden açılır. Yanıt okunurken mikrofon kapalıdır.")
                            .font(.caption).foregroundStyle(appearance.muted)
                            .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
                        if session.voiceConversationActive && speech.listening {
                            Button("Konuşmayı bitir · yanıtla") { session.finishDictation() }
                                .help("Sessizlik algısını beklemeden söylediğin metni tamamlayıp gönderir.")
                                .accessibilityIdentifier("companion.finishVoiceTurn")
                        }
                        if !session.voiceStatus.isEmpty {
                            Text(session.voiceStatus).font(.callout).textSelection(.enabled)
                                .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
                                .accessibilityIdentifier("companion.voiceStatus")
                        }
                        if !session.voiceTranscript.isEmpty {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("SEN · TANINAN KONUŞMA")
                                    .font(.system(.caption, design: .monospaced).bold())
                                    .foregroundStyle(appearance.accent)
                                Text(session.voiceTranscript).font(.callout).lineLimit(6).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(appearance.raised.opacity(appearance.backgroundOpacity), in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(appearance.border, lineWidth: 1))
                            .accessibilityIdentifier("companion.voiceTranscript")
                        }
                        if session.sending && !session.liveReply.isEmpty {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("CODEX · CANLI YANIT")
                                    .font(.system(.caption, design: .monospaced).bold())
                                    .foregroundStyle(appearance.accent)
                                Text(session.liveReply).font(.callout).lineLimit(8).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(appearance.raised.opacity(appearance.backgroundOpacity), in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(appearance.border, lineWidth: 1))
                            .accessibilityIdentifier("companion.liveReply")
                        }
                        HStack {
                            Button(speech.finalizing ? "Metin tamamlanıyor…" : (speech.listening ? "Metne yazmayı bitir" : "Yalnızca metne yaz")) {
                                if speech.listening { session.finishDictation() }
                                else { Task { await session.startListening() } }
                            }.disabled(session.voiceConversationActive || session.sending || session.capturing || session.connecting || session.stopping || speech.preparing || speech.finalizing)
                            Button("Sustur") {
                                if session.voiceConversationActive { session.pauseVoiceConversation() }
                                session.mute()
                            }.disabled(!speech.dictationBusy && !session.voiceConversationActive)
                            Button("Yanıt sesini durdur") { session.stopReplyAudio() }
                                .disabled(!speech.speaking && !session.voiceConversationActive)
                        }
                        if !session.voiceConversationActive {
                            Text(speech.status).font(.caption).foregroundStyle(appearance.muted)
                                .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
                        }
                        Button("Türkçe sesi dene") { speech.speak("Merhaba Deniz. Bavbav ses denemesi. Beni duyabiliyor musun?") }
                            .disabled(session.voiceConversationActive || session.sending || session.stopping || speech.dictationBusy)
                            .help("Yalnızca Mac ses çıkışı denemesidir; gerçek sohbet yanıtı değildir.")
                        Text("Mac sesi: \(speech.selectedVoiceName) · \(speech.selectedVoiceQuality). Kurulu geliştirilmiş Türkçe ses varsa otomatik seçilir.")
                            .font(.caption).foregroundStyle(appearance.muted)
                            .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
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
                        Toggle("Yanıtları Türkçe seslendir", isOn: $session.speakReplies)
                            .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
                            .onChange(of: session.speakReplies) {
                                if !$0 { session.pauseVoiceConversation(); session.stopReplyAudio() }
                            }
                        if !speech.supportsLocalTurkish {
                            Toggle("Cihaz içi Türkçe yoksa Apple konuşma hizmetine izin ver", isOn: $session.allowAppleService)
                                .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
                                .onChange(of: session.allowAppleService) {
                                    if !$0 { session.pauseVoiceConversation(); speech.stopListening() }
                                }
                            Text("Bu seçenek sesin Apple'a gönderilebilmesine izin verir. Tanınan metin sesli sohbette otomatik, yalnızca metne yaz modunda Gönder'e bastığında mevcut hesabına gider.")
                                .font(.caption).foregroundStyle(appearance.muted)
                                .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
                        }
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                section("TÜM EKRAN · ARALIKLI PAYLAŞIM") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Button(session.requestingScreenPermission ? "İzin bekleniyor…" : "Ekranları göster / yenile") {
                                Task { await session.listDisplays() }
                            }
                                .disabled(session.requestingScreenPermission || session.capturing || session.screenSharing || session.stopping)
                                .help("macOS Ekran Kaydı iznini sorabilir. Görüntü gönderimi ayrıca onaylanıp başlatılır.")
                            Spacer()
                            Text(session.screenSharing ? "● PAYLAŞILIYOR" : "○ KAPALI")
                                .font(.system(.caption, design: .monospaced).bold())
                                .foregroundStyle(session.screenSharing ? appearance.accent : appearance.muted)
                                .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
                                .accessibilityIdentifier("companion.screenSharing")
                        }
                        if session.requestingScreenPermission {
                            Text("macOS Ekran Kaydı iznini bekliyor. İzin ekranında Bavbav'a erişim ver; burada ekran görüntüsü henüz gönderilmiyor.")
                                .font(.caption).foregroundStyle(appearance.muted)
                                .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
                        } else if session.displays.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Ekran görünmüyorsa Sistem Ayarları → Gizlilik ve Güvenlik → Ekran ve Sistem Sesi Kaydı bölümünde Bavbav'ı etkinleştir, ardından ekranları yenile. macOS isterse Bavbav'ı yeniden aç.")
                                    .font(.caption).foregroundStyle(appearance.muted)
                                    .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
                                Button("Sistem Ayarları") {
                                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
                                }
                            }
                        }
                        if !session.displays.isEmpty {
                            Menu {
                                Button("Bir ekran seç…") { shareConsent = false; session.selectDisplay(nil) }
                                ForEach(session.displays) { display in
                                    Button(display.label) { shareConsent = false; session.selectDisplay(display) }
                                }
                            } label: {
                                HStack {
                                    Text(session.displaySelection?.label ?? "Bir ekran seç…").lineLimit(1)
                                    Spacer()
                                    Image(systemName: "chevron.up.chevron.down")
                                }
                                .font(.system(size: 12, design: .monospaced))
                                .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
                                .padding(8)
                                .background(appearance.raised.opacity(appearance.backgroundOpacity), in: RoundedRectangle(cornerRadius: 5))
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(appearance.border, lineWidth: 1))
                            }.menuStyle(.borderlessButton)
                            .accessibilityLabel("Tamamı paylaşılacak ekran")
                            .disabled(session.screenSharing || session.capturing || session.stopping)
                        }
                        Stepper(value: $session.screenShareInterval, in: 3...60, step: 1) {
                            Text("Kareler arasında en az \(Int(session.screenShareInterval)) saniye")
                                .font(.system(size: 12, design: .monospaced))
                                .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
                        }.accessibilityLabel("Ekran paylaşımı aralığı, saniye")
                        Text("Açtığında bu ekrandaki tüm görünür içerik, diğer uygulamalar ve bildirimler dahil, mevcut hesabın üzerinden modele gönderilir.")
                            .font(.caption).foregroundStyle(appearance.muted)
                            .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
                        if !session.screenSharing {
                            Toggle("Bu ekranın tamamını aralıklarla paylaşmayı onaylıyorum", isOn: $shareConsent)
                                .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
                                .disabled(session.displaySelection == nil || session.stopping)
                        }
                        HStack {
                            Button(session.capturing ? "Kare hazırlanıyor…" : "Paylaşımı başlat · tüm ekran") {
                                Task { await session.startScreenSharing() }
                            }.disabled(!shareConsent || session.displaySelection == nil || !session.connected || session.connecting || session.stopping || session.screenSharing || session.capturing || session.sending || (speech.dictationBusy && !session.voiceConversationActive))
                            Button("Paylaşımı durdur", role: .destructive) {
                                shareConsent = false
                                session.stopScreenSharing()
                            }.disabled(!session.screenSharing)
                        }
                        if let sharedAt = session.lastSharedAt {
                            Text("Görüntülü son yanıt: \(sharedAt.formatted(date: .omitted, time: .standard))")
                                .font(.system(.caption, design: .monospaced)).foregroundStyle(appearance.muted)
                                .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
                        }
                        if let captured = session.lastCapturedAt {
                            Text("Son kare: \(captured.formatted(date: .omitted, time: .standard)) · yalnızca en güncel kare tutulur")
                                .font(.system(.caption, design: .monospaced)).foregroundStyle(appearance.muted)
                                .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
                        }
                        Toggle("Ekran değişikliklerini ayrıca kendiliğinden yorumla", isOn: $session.observeScreenChanges)
                            .disabled(control.enabled)
                            .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
                        Text("Kapalı olması daha hızlıdır: ekran aralıklarla hazırlanır, konuşman veya mesajınla birlikte modele gider. Açarsan ayrıca ekran yorumları üretilir; hesap kullanımı ve yanıt beklemesi artabilir.")
                            .font(.caption).foregroundStyle(appearance.muted)
                        if let data = session.preview, let image = NSImage(data: data) {
                            Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 180)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .accessibilityLabel("En son hazırlanan ekran karesi")
                        }
                        Text("Video veya sistem sesi kaydedilmez. Kareler kuyrukta birikmez; yalnızca son kare tutulur ve isteğinle gönderilir. Paylaşımı durdur, STOP veya pencereyi kapatma yeni kareleri ve tıklamaları keser. Önceden gönderilen kareler geri alınmaz.")
                            .font(.caption).foregroundStyle(appearance.muted)
                            .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                section("SANAL İMLEÇ · BİLGİSAYAR KONTROLÜ") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(control.enabled ? "● KONTROL AÇIK" : "○ KONTROL KAPALI")
                                .font(.system(.caption, design: .monospaced).bold())
                                .foregroundStyle(control.enabled ? appearance.accent : appearance.muted)
                            Spacer()
                            if control.enabled {
                                Button("Kontrolü bitir", role: .destructive) {
                                    controlConsent = false; control.stop()
                                }
                            }
                        }
                        Text("Görünür uygulamalar arasında yeşil sanal imleçle, isteğin üzerine sıradan tıklamalar yapabilir. macOS gerçek giriş sistemi ortaktır; bağımsız ikinci donanım imleci değildir. Klavye/yazma, satın alma, silme ve güvenlik izinleri bu ilk sürümde uygulanmaz.")
                            .font(.caption).foregroundStyle(appearance.muted)
                        if !control.enabled {
                            Toggle("Görünür uygulamalarda istediğim tıklamaların uygulanmasına izin veriyorum", isOn: $controlConsent)
                                .disabled(!session.screenSharing || session.stopping)
                            Button("Sanal imleç kontrolünü başlat") {
                                session.observeScreenChanges = false
                                session.enableDesktopControl()
                            }.disabled(!controlConsent || !session.screenSharing || !session.connected || session.stopping)
                        }
                        Text(control.status).font(.callout).textSelection(.enabled)
                            .accessibilityIdentifier("companion.desktopControlStatus")
                        Text("Erişilebilirlik izni macOS tarafından ayrıca istenir. Ekran paylaşımı tek başına tıklama izni değildir. STOP tüm kontrolü anında durdurur. Logic Pro için özel araç/miks otomasyonu hazır değildir.")
                            .font(.caption).foregroundStyle(appearance.muted)
                    }.modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
                }
                if !session.lines.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(session.lines) { line in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(line.speaker).font(.system(.caption, design: .monospaced).bold()).foregroundStyle(appearance.accent)
                                    .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
                                Text(line.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
                            }
                        }
                    }.padding(14).background(appearance.surface.opacity(appearance.backgroundOpacity), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(appearance.border, lineWidth: 1))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("METNİ KONTROL ET → GÖNDER").font(.system(.caption, design: .monospaced)).foregroundStyle(appearance.accent)
                        .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
                    TextEditor(text: $session.draft).font(.body).frame(minHeight: 90, maxHeight: 150)
                        .scrollContentBackground(.hidden)
                        .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
                        .padding(8)
                        .background(appearance.raised.opacity(appearance.backgroundOpacity), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(appearance.border, lineWidth: 1))
                        .disabled(session.voiceConversationActive || session.sending || speech.dictationBusy)
                        .accessibilityLabel("Companion mesajı")
                    HStack {
                        Text(session.voiceConversationActive ? "Sesli sohbet açık · bu yazılı taslak korunuyor." : "Yalnızca metne yaz modu otomatik göndermez.").font(.caption).foregroundStyle(appearance.muted)
                            .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
                        Spacer()
                        Button(session.sending ? "Yanıt bekleniyor…" : "Gönder") { Task { await session.send() } }
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(session.voiceConversationActive || !session.connected || session.sending || session.capturing || session.stopping || speech.dictationBusy || (session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !session.includePreview))
                    }
                }
                Text("LOGIC PRO ÖZEL OTOMASYONU · HAZIR DEĞİL\nSanal imleçte yalnızca doğrulanmış sıradan tıklamalar vardır. Plugin, miks, kayıt, klavye ve dosya işlemleri hazır sayılmaz.")
                    .font(.caption).foregroundStyle(appearance.muted)
                    .modifier(CompanionReadableForeground(strength: appearance.foregroundStrength))
            }.padding(22)
        }
        .scrollContentBackground(.hidden)
        .background(appearance.background.opacity(appearance.backgroundOpacity))
        .foregroundStyle(appearance.text)
        .preferredColorScheme(.dark)
        .tint(appearance.accent)
        .toggleStyle(.checkbox)
        .buttonStyle(CompanionButtonStyle(appearance: appearance))
        .onChange(of: session.screenSharing) { if !$0 { shareConsent = false; controlConsent = false } }
        .onChange(of: session.connected) { if !$0 { shareConsent = false; controlConsent = false } }
        .onChange(of: control.enabled) { if !$0 { controlConsent = false } }
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
    }
}
