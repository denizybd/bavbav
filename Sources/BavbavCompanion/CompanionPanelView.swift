import SwiftUI

public struct CompanionPanelView: View {
    @ObservedObject private var session: CompanionSession
    @ObservedObject private var speech: CompanionSpeech
    private let green = Color(red: 0.26, green: 0.89, blue: 0.71)
    public init(session: CompanionSession) {
        self.session = session; self.speech = session.speech
    }
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("COMPANION").font(.system(.title2, design: .monospaced).bold()).foregroundStyle(green)
                        Text("SES + SEÇİLİ PENCERE").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("BİTİR / STOP", role: .destructive) { session.stop() }
                        .help("Mikrofonu, görüntü paylaşımını, yanıtı ve sesi durdurur. Diğer sohbetlere dokunmaz.")
                }
                Text("macOS Türkçe konuşma → mevcut Codex hesabı → Mac sesi. Bu, ChatGPT'nin yerleşik Voice özelliği değildir.")
                    .font(.callout).foregroundStyle(.secondary)
                Text(session.status).font(.callout).textSelection(.enabled).accessibilityIdentifier("companion.status")
                HStack {
                    Button(session.connected ? "Hesap bağlı" : "Hesaba bağlan") { Task { await session.connect() } }
                        .disabled(session.connected || session.connecting || session.stopping)
                    Text("Kendi Companion sohbeti · API anahtarı yok").font(.caption).foregroundStyle(.secondary)
                }
                GroupBox("TÜRKÇE SES") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Button(speech.listening ? "Dinlemeyi bitir" : "Başlat · konuş") {
                                if speech.listening { session.finishDictation() }
                                else { Task { await session.startListening() } }
                            }.disabled(session.sending || session.connecting || session.stopping || speech.preparing)
                            Button("Sustur") { session.mute() }.disabled(!speech.listening)
                            Button("Yanıt sesini durdur") { speech.stopSpeaking() }.disabled(!speech.speaking)
                        }
                        Text(speech.status).font(.caption).foregroundStyle(.secondary)
                        Button("Türkçe sesi dene") { speech.speak("Merhaba Deniz. Bavbav ses denemesi. Beni duyabiliyor musun?") }
                            .disabled(session.sending)
                        Toggle("Yanıtları Türkçe seslendir", isOn: $session.speakReplies)
                            .onChange(of: session.speakReplies) { if !$0 { speech.stopSpeaking() } }
                        if !speech.supportsLocalTurkish {
                            Toggle("Cihaz içi Türkçe yoksa Apple konuşma hizmetine izin ver", isOn: $session.allowAppleService)
                                .onChange(of: session.allowAppleService) { if !$0 { speech.stopListening() } }
                            Text("Bu seçenek sesin Apple'a gönderilebilmesine izin verir. OpenAI'a yalnızca kontrol edip gönderdiğin metin gider.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("PENCERE · TEK KARE, AÇIK ONAY") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Button("Pencere seç / yenile") { Task { await session.listWindows() } }.disabled(session.capturing || session.sending)
                            Button("Paylaşımı kapat") { session.revokeShare() }.disabled(session.selection == nil)
                        }
                        if !session.windows.isEmpty {
                            Picker("Pencere", selection: Binding<UInt32?>(get: { session.selection?.id }, set: { id in
                                session.selectWindow(session.windows.first { $0.id == id })
                            })) {
                                Text("Bir pencere seç…").tag(nil as UInt32?)
                                ForEach(session.windows) { Text($0.label).tag(Optional($0.id)) }
                            }
                            .disabled(session.sending)
                        }
                        Button(session.capturing ? "Hazırlanıyor…" : "Yalnızca seçili pencereyi önizle") { Task { await session.capturePreview() } }
                            .disabled(session.selection == nil || session.capturing || session.sending)
                        if let data = session.preview, let image = NSImage(data: data) {
                            Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 180)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            Toggle("Bu kareyi sonraki mesajla paylaş", isOn: $session.includePreview).disabled(session.sending)
                        }
                        Text("Tüm ekran, arka plan kaydı ve sistem sesi alınmaz. Pencere seçmek paylaşmak değildir.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                if !session.lines.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(session.lines) { line in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(line.speaker).font(.system(.caption, design: .monospaced).bold()).foregroundStyle(green)
                                Text(line.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }.padding(14).background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("METNİ KONTROL ET → GÖNDER").font(.system(.caption, design: .monospaced)).foregroundStyle(green)
                    TextEditor(text: $session.draft).font(.body).frame(minHeight: 90, maxHeight: 150)
                        .scrollContentBackground(.hidden).padding(8)
                        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        .disabled(session.sending || speech.listening)
                        .accessibilityLabel("Companion mesajı")
                    HStack {
                        Text("Konuşma kendiliğinden gönderilmez.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(session.sending ? "Yanıt bekleniyor…" : "Gönder") { Task { await session.send() } }
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(!session.connected || session.sending || (session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !session.includePreview))
                    }
                }
                Text("LOGIC PRO KONTROLÜ · HAZIR DEĞİL\nBu sürüm yalnızca konuşur ve onayladığın pencere karesini yorumlar. Fare, klavye veya Logic Pro işlemi yapmaz.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(22)
        }
        .background(Color(red: 0.035, green: 0.045, blue: 0.050))
        .preferredColorScheme(.dark)
        .tint(green)
    }
}
