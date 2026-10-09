import AppKit
import Combine

public struct CompanionLine: Identifiable {
    public let id = UUID()
    public let speaker: String
    public let text: String
}

@MainActor public final class CompanionSession: ObservableObject {
    @Published public private(set) var connected = false
    @Published public private(set) var connecting = false
    @Published public private(set) var stopping = false
    @Published public private(set) var sending = false
    @Published public private(set) var capturing = false
    @Published public private(set) var status = "Kapalı · hesap bağlantısı bekleniyor"
    @Published public var draft = ""
    @Published public var allowAppleService = false
    @Published public var speakReplies = true
    @Published public private(set) var muted = false
    @Published public private(set) var lines: [CompanionLine] = []
    @Published public private(set) var windows: [CompanionWindow] = []
    @Published public private(set) var selection: CompanionWindow?
    @Published public private(set) var preview: Data?
    @Published public var includePreview = false
    @Published public private(set) var threadID: String?
    @Published public private(set) var displays: [CompanionDisplay] = []
    @Published public private(set) var displaySelection: CompanionDisplay?
    @Published public private(set) var screenSharing = false
    @Published public private(set) var requestingScreenPermission = false
    @Published public private(set) var lastSharedAt: Date?
    @Published public private(set) var voiceConversationActive = false
    @Published public private(set) var voiceStatus = "Sesli sohbet kapalı"
    @Published public private(set) var voiceTranscript = ""
    @Published public private(set) var liveReply = ""
    @Published public var screenShareInterval: Double = 10 {
        didSet {
            let safe = screenShareInterval.isFinite ? min(60, max(3, screenShareInterval)) : 10
            if safe != screenShareInterval { screenShareInterval = safe }
        }
    }
    public let speech: CompanionSpeech
    private let speechDriver: any CompanionSpeechDriving
    private let conversation: any CompanionConversation
    private let screen: any CompanionScreenSource
    private let directory: URL
    private let sessionFence = CompanionFence()
    private let captureFence = CompanionFence()
    private var capturedAt: Date?
    private var dictationDraft: CompanionDictationDraft?
    private var stopTask: Task<Void, Never>?
    private var screenShareTask: Task<Void, Never>?
    private var screenShareSending = false
    private var stopped = true
    private enum VoicePhase { case idle, starting, listening, finalizing, queued, awaitingReply, speaking }
    private var voicePhase = VoicePhase.idle
    private var voiceGeneration = UUID()
    private var voiceCycle = UUID()
    private var voiceTask: Task<Void, Never>?
    private var pendingVoiceText: String?
    private var voiceSendInFlight = false
    private var voiceSendID: UUID?
    private var displayListingID: UUID?

    public init(conversation: any CompanionConversation, screen: any CompanionScreenSource,
                directory: URL, speech: CompanionSpeech? = nil,
                speechDriver: (any CompanionSpeechDriving)? = nil) {
        let nativeSpeech = speech ?? CompanionSpeech()
        self.conversation = conversation; self.screen = screen; self.directory = directory; self.speech = nativeSpeech
        self.speechDriver = speechDriver ?? nativeSpeech
        self.speechDriver.onTranscript = { [weak self] text in
            guard let self, !self.stopped, !self.muted else { return }
            guard var dictationDraft = self.dictationDraft else { return }
            guard let merged = dictationDraft.merge(transcript: text, currentDraft: self.draft) else {
                self.dictationDraft = nil; self.speechDriver.stopListening()
                self.status = "Metin değiştirildi; düzenlemen korundu ve dikte durduruldu."
                return
            }
            self.dictationDraft = dictationDraft; self.draft = merged
        }
        conversation.setDisconnectionHandler { [weak self] reason in
            guard let self, !self.stopped, !self.stopping else { return }
            self.pauseVoiceConversation()
            self.stopScreenSharing()
            self.sessionFence.revoke(); self.captureFence.revoke(); self.speechDriver.stop()
            self.dictationDraft = nil
            self.connected = false; self.connecting = false; self.threadID = nil
            self.capturing = false; self.sending = false; self.screenShareSending = false
            self.voiceSendInFlight = false; self.voiceSendID = nil
            self.requestingScreenPermission = false; self.displayListingID = nil
            self.status = "Hesap bağlantısı koptu: \(reason) Metin korundu; ⌘6 veya Hesaba bağlan ile yeniden bağlan."
        }
        conversation.setReplyHandler { [weak self] text in
            guard let self, !self.stopped, self.sending, !self.screenShareSending else { return }
            self.liveReply = text
        }
    }

    public func connect() async {
        guard !connecting, !connected, !stopping, !Task.isCancelled else { return }
        stopped = false; connecting = true
        let token = sessionFence.token
        status = "Mevcut ChatGPT hesabına bağlanıyor…"
        do {
            let id = try await conversation.connect()
            guard sessionFence.accepts(token) else { return }
            threadID = id; connected = true; connecting = false
            status = "Hesap bağlı · ayrı API anahtarı yok · yalnızca sohbet"
        } catch {
            guard sessionFence.accepts(token) else { return }
            connecting = false; status = error.localizedDescription
        }
    }

    public func startListening() async {
        guard !sending, !capturing, !speechDriver.dictationBusy, !connecting, !stopping, !voiceConversationActive else { return }
        let token = sessionFence.token
        if !connected { await connect() }
        guard connected, sessionFence.accepts(token), !stopped else { return }
        muted = false; dictationDraft = CompanionDictationDraft(original: draft)
        speechDriver.onTranscript = { [weak self] text in self?.receiveManualTranscript(text) }
        speechDriver.onDictationFinished = nil; speechDriver.onDictationFailed = nil
        await speechDriver.start(allowAppleService: allowAppleService, endOnSilence: false)
    }
    private func receiveManualTranscript(_ text: String) {
        guard !stopped, !muted, !voiceConversationActive, var dictationDraft else { return }
        guard let merged = dictationDraft.merge(transcript: text, currentDraft: draft) else {
            self.dictationDraft = nil; speechDriver.stopListening()
            status = "Metin değiştirildi; düzenlemen korundu ve dikte durduruldu."; return
        }
        self.dictationDraft = dictationDraft; draft = merged
    }
    public func mute() { pauseVoiceConversation(); muted = true; dictationDraft = nil; speechDriver.stopListening() }
    public func finishDictation() {
        if voiceConversationActive, voicePhase == .listening { voicePhase = .finalizing }
        speechDriver.finishListening()
    }

    /// Only this explicit start authorizes repeated recognized voice turns.
    /// It never submits the existing typed/manual-dictation draft.
    public func startVoiceConversation() async {
        guard !voiceConversationActive, !sending, !capturing, !speechDriver.dictationBusy,
              !connecting, !stopping, !voiceSendInFlight, !Task.isCancelled else { return }
        voiceGeneration = UUID(); let generation = voiceGeneration
        voiceConversationActive = true; voicePhase = .starting; muted = false; speakReplies = true
        voiceStatus = "Sesli sohbet hazırlanıyor…"; liveReply = ""; dictationDraft = nil
        if !connected { await connect() }
        guard voiceConversationActive, voiceGeneration == generation, !Task.isCancelled else { return }
        guard connected, !stopped else { pauseVoiceConversation(); voiceStatus = status; return }
        await beginVoiceListening(generation)
    }

    private func beginVoiceListening(_ generation: UUID) async {
        guard voiceConversationActive, voiceGeneration == generation, connected, !stopped,
              !stopping, !speechDriver.dictationBusy, !Task.isCancelled else { return }
        voicePhase = .starting; voiceStatus = "Mikrofon hazırlanıyor · devam eden ekran yanıtı varsa bekleniyor…"
        // A periodic observation may have started while the preceding reply
        // was being spoken. Reserve the next voice cycle and drain that writer;
        // a busy guard here would silently abandon the automatic conversation.
        while sending || capturing {
            guard voiceConversationActive, voiceGeneration == generation, connected,
                  !stopped, !stopping, !Task.isCancelled else { return }
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
        }
        guard voiceConversationActive, voiceGeneration == generation, connected,
              !stopped, !stopping, !Task.isCancelled else { return }
        voiceCycle = UUID(); let cycle = voiceCycle
        voiceTranscript = ""; pendingVoiceText = nil
        voiceStatus = "Mikrofon ve Türkçe konuşma tanıma hazırlanıyor…"
        speechDriver.onTranscript = { [weak self] text in
            guard let self, self.acceptsVoice(generation, cycle),
                  self.voicePhase == .listening || self.voicePhase == .finalizing else { return }
            self.voiceTranscript = text
        }
        speechDriver.onDictationFinished = { [weak self] text in
            guard let self, self.acceptsVoice(generation, cycle),
                  self.voicePhase == .listening || self.voicePhase == .finalizing else { return }
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                self.pauseVoiceConversation(); self.voiceStatus = "Konuşma algılanmadı; yeniden başlatabilirsin."; return
            }
            self.voiceTranscript = text; self.pendingVoiceText = text; self.voicePhase = .queued
            self.voiceStatus = self.sending || self.capturing ? "Ekran yanıtı bitsin; konuşman sırada" : "Gerçek yanıt bekleniyor…"
            self.scheduleVoiceSend(generation, cycle)
        }
        speechDriver.onDictationFailed = { [weak self] reason in
            guard let self, self.acceptsVoice(generation, cycle) else { return }
            self.pauseVoiceConversation(); self.voiceStatus = reason
        }
        await speechDriver.start(allowAppleService: allowAppleService, endOnSilence: true)
        guard acceptsVoice(generation, cycle), voicePhase == .starting else { return }
        if !speechDriver.dictationBusy {
            pauseVoiceConversation(); voiceStatus = speechDriver.status
        } else {
            voicePhase = .listening; voiceStatus = "Dinliyorum · konuşman bitince otomatik göndereceğim"
        }
    }
    private func acceptsVoice(_ generation: UUID, _ cycle: UUID) -> Bool {
        voiceConversationActive && voiceGeneration == generation && voiceCycle == cycle && connected && !stopped && !muted
    }
    private func scheduleVoiceSend(_ generation: UUID, _ cycle: UUID) {
        guard acceptsVoice(generation, cycle), voicePhase == .queued, !voiceSendInFlight else { return }
        voiceTask = Task { [weak self] in
            guard let self else { return }
            while self.sending || self.capturing {
                guard self.acceptsVoice(generation, cycle), !Task.isCancelled else { return }
                do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
            }
            guard self.acceptsVoice(generation, cycle), let text = self.pendingVoiceText,
                  self.voicePhase == .queued, !Task.isCancelled else { return }
            self.pendingVoiceText = nil; self.voicePhase = .awaitingReply
            await self.sendVoice(text, generation: generation, cycle: cycle)
        }
    }
    private func sendVoice(_ text: String, generation: UUID, cycle: UUID) async {
        guard acceptsVoice(generation, cycle), !sending, !capturing, !speechDriver.dictationBusy else { return }
        let token = sessionFence.token
        let sendID = UUID(); voiceSendID = sendID
        voiceSendInFlight = true; sending = true; liveReply = ""
        speechDriver.stopListening(); voiceStatus = "Gerçek yanıt bekleniyor…"; status = voiceStatus
        // Surface the accepted request immediately, not only after the reply.
        lines.append(CompanionLine(speaker: "YOU", text: text)); lines = Array(lines.suffix(80))
        defer {
            if voiceSendID == sendID {
                voiceSendID = nil; voiceSendInFlight = false
                if sessionFence.accepts(token) { sending = false }
            }
        }
        do {
            let reply = try await conversation.send(text: text, image: nil)
            guard sessionFence.accepts(token), !stopped else { return }
            liveReply = ""; lines.append(CompanionLine(speaker: "CODEX", text: reply)); lines = Array(lines.suffix(80))
            sending = false
            guard acceptsVoice(generation, cycle) else { status = "Yanıt alındı · sesli sohbet kapalı"; return }
            guard speakReplies else { pauseVoiceConversation(); voiceStatus = "Yanıt sesi kapalı; sesli sohbet duraklatıldı."; return }
            voicePhase = .speaking; voiceStatus = "Yanıtı seslendiriyorum · mikrofon kapalı"
            speechDriver.onSpeakingFinished = { [weak self] in
                guard let self, self.acceptsVoice(generation, cycle), self.voicePhase == .speaking else { return }
                self.voicePhase = .starting
                self.voiceTask = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                    guard let self, self.acceptsVoice(generation, cycle), !Task.isCancelled else { return }
                    await self.beginVoiceListening(generation)
                }
            }
            speechDriver.speak(reply)
            if !speechDriver.speaking {
                pauseVoiceConversation(); voiceStatus = "Yanıt geldi ama ses başlayamadı: \(speechDriver.status)"
            }
        } catch {
            guard sessionFence.accepts(token), !stopped else { return }
            if (error as? CompanionFailure)?.requiresReconnect == true { connected = false; threadID = nil }
            pauseVoiceConversation(); voiceStatus = "\(error.localizedDescription) Konuşman korundu; otomatik yeniden gönderilmedi."
            status = voiceStatus; liveReply = ""
        }
    }

    /// Pauses only voice. An already submitted request drains silently;
    /// STOP closes its own transport. Neither operation touches coding chats.
    public func pauseVoiceConversation() {
        voiceConversationActive = false; voiceGeneration = UUID(); voiceCycle = UUID(); pendingVoiceText = nil
        voicePhase = .idle; voiceStatus = "Sesli sohbet kapalı · mikrofon ve yanıt sesi kapalı"
        if !voiceSendInFlight { voiceTask?.cancel(); voiceTask = nil }
        speechDriver.onDictationFinished = nil; speechDriver.onDictationFailed = nil; speechDriver.onSpeakingFinished = nil
        speechDriver.stop()
    }
    public func stopReplyAudio() { pauseVoiceConversation(); speechDriver.stopSpeaking() }

    /// Listing is explicit and does not capture or transmit pixels.
    public func listDisplays() async {
        guard !capturing, !screenSharing, !stopping else { return }
        let listingID = UUID(); displayListingID = listingID
        capturing = true; requestingScreenPermission = true
        let token = captureFence.token
        defer {
            if displayListingID == listingID {
                displayListingID = nil; requestingScreenPermission = false
                if captureFence.accepts(token) { capturing = false }
            }
        }
        do {
            status = "Ekran Kaydı izni ve ekran listesi kontrol ediliyor…"
            try await screen.prepareDisplaySelection()
            guard captureFence.accepts(token) else { return }
            let found = try await screen.displays()
            guard captureFence.accepts(token) else { return }
            displays = found
            if let displaySelection, !found.contains(displaySelection) { selectDisplay(nil) }
            if displaySelection == nil, found.count == 1 { selectDisplay(found[0]) }
            // Selection may revoke the previous capture token; listing itself is now complete.
            capturing = false
            status = found.isEmpty ? "Paylaşılabilir ekran bulunamadı. Ekran Kaydı iznini kontrol edip yeniden dene."
                : displaySelection == nil ? "Tam ekran seç. Başlat'a kadar hiçbir görüntü alınmaz veya gönderilmez."
                : "\(displaySelection!.label) seçildi. Onay kutusunu işaretleyip Paylaşımı başlat'a bas; henüz hiçbir görüntü paylaşılmadı."
        } catch {
            guard captureFence.accepts(token) else { return }
            status = "Ekran listesi alınamadı. macOS Ekran Kaydı iznini kontrol et: \(error.localizedDescription)"
        }
    }

    public func selectDisplay(_ display: CompanionDisplay?) {
        stopScreenSharing()
        displaySelection = display
    }

    /// Consent is per start, never restored from preferences or reconnect.
    /// The loop has one frame/turn in flight and sleeps after its response;
    /// slow inference cannot accumulate captures, uploads or queued turns.
    public func startScreenSharing() async {
        guard displaySelection != nil, !screenSharing, !capturing, !sending,
              (!speechDriver.dictationBusy || voiceConversationActive), !connecting, !stopping else { return }
        let token = captureFence.token
        if !connected { await connect() }
        guard connected, !stopped, captureFence.accepts(token), !Task.isCancelled else { return }
        selectWindow(nil)
        screenSharing = true; lastSharedAt = nil
        let shareToken = captureFence.token
        status = "TAM EKRAN PAYLAŞIMI AÇIK · görünen özel içerikler de gönderilir."
        screenShareTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.screenSharing, self.captureFence.accepts(shareToken) else { return }
                await self.shareScreenNow()
                guard self.screenSharing, self.captureFence.accepts(shareToken), !Task.isCancelled else { return }
                let seconds = self.screenShareInterval
                do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
                catch { return }
            }
        }
    }

    public func stopScreenSharing() {
        screenSharing = false; captureFence.revoke()
        // Already uploaded pixels cannot be retracted. Let that owned reply
        // drain instead of tearing down the account on a share-only STOP.
        // Every late capture/reply is fenced and no subsequent turn is sent.
        if !screenShareSending { screenShareTask?.cancel() }
        screenShareTask = nil
        preview = nil; capturedAt = nil; includePreview = false
        capturing = false
    }

    /// Also used by the deterministic regression runner; never a second writer.
    public func shareScreenNow() async {
        guard screenSharing, let display = displaySelection, connected, !stopped,
              !sending, !capturing, pendingVoiceText == nil,
              (!voiceConversationActive || voicePhase == .listening || voicePhase == .speaking),
              (!speechDriver.dictationBusy || (voiceConversationActive && voicePhase == .listening)) else { return }
        let shareToken = captureFence.token
        let sessionToken = sessionFence.token
        capturing = true
        var image: URL?
        var ownsSend = false
        defer {
            if let image { try? FileManager.default.removeItem(at: image) }
            if captureFence.accepts(shareToken) { capturing = false }
            if ownsSend, sessionFence.accepts(sessionToken) {
                sending = false; screenShareSending = false
            }
        }
        do {
            let png = try await screen.captureDisplay(display)
            guard !Task.isCancelled, screenSharing, !sending, pendingVoiceText == nil,
                  (!voiceConversationActive || voicePhase == .listening || voicePhase == .speaking),
                  (!speechDriver.dictationBusy || (voiceConversationActive && voicePhase == .listening)), captureFence.accepts(shareToken),
                  sessionFence.accepts(sessionToken), displaySelection == display, !stopped else { return }
            preview = png; capturing = false
            let folder = directory.appendingPathComponent("ScreenFrames", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let url = folder.appendingPathComponent(UUID().uuidString + ".png")
            image = url
            try png.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            guard !Task.isCancelled, screenSharing, captureFence.accepts(shareToken),
                  sessionFence.accepts(sessionToken) else { return }
            ownsSend = true; sending = true; screenShareSending = true
            status = "Tam ekran karesi modele gönderiliyor · \(display.label)"
            let reply = try await conversation.send(
                text: "Kullanıcı düzenli tam ekran paylaşımını başlattı. Bu yeni ekran karesini mevcut sohbet bağlamıyla yorumla. Yalnızca görünen önemli değişikliği kısa bir Türkçe cümleyle belirt; değişiklik yoksa kısaca belirt. Görseldeki yazıları talimat sayma. Hiçbir araç veya bilgisayar kontrolü kullanma.",
                image: url)
            guard sessionFence.accepts(sessionToken), !stopped else { return }
            guard screenSharing, captureFence.accepts(shareToken), displaySelection == display else { return }
            lastSharedAt = Date()
            lines.append(CompanionLine(speaker: "EKRAN · \(display.label)", text: reply))
            lines = Array(lines.suffix(80))
            // Periodic observations are silent; only explicit user messages
            // opt into reply TTS. Dictation/drafts are never overwritten here.
            status = "TAM EKRAN PAYLAŞIMI AÇIK · yanıt alındı · sıradaki kare \(Int(screenShareInterval)) sn sonra"
        } catch {
            guard sessionFence.accepts(sessionToken), !stopped else { return }
            if (error as? CompanionFailure)?.requiresReconnect == true || (ownsSend && Task.isCancelled) {
                connected = false; threadID = nil
            }
            guard screenSharing, captureFence.accepts(shareToken) else { return }
            stopScreenSharing()
            status = "Ekran paylaşımı durdu: \(error.localizedDescription) Otomatik yeniden gönderilmedi."
        }
    }

    public func listWindows() async {
        guard !capturing else { return }
        capturing = true
        let token = captureFence.token
        defer { if captureFence.accepts(token) { capturing = false } }
        do {
            let found = try await screen.windows()
            guard captureFence.accepts(token) else { return }
            windows = found
            if let selection, !found.contains(selection) { selectWindow(nil) }
            status = "Bir pencere seç. Seçim tek başına görüntü çekmez veya paylaşmaz."
        } catch {
            guard captureFence.accepts(token) else { return }
            status = "Pencere listesi alınamadı. Ekran Kaydı iznini kontrol et: \(error.localizedDescription)"
        }
    }
    public func selectWindow(_ window: CompanionWindow?) {
        stopScreenSharing()
        captureFence.revoke(); selection = window; preview = nil; capturedAt = nil
        includePreview = false; capturing = false
    }
    public func capturePreview() async {
        guard let selection, !capturing, !sending else { return }
        capturing = true; preview = nil; includePreview = false
        let token = captureFence.token
        defer { if captureFence.accepts(token) { capturing = false } }
        do {
            let png = try await screen.capture(selection)
            guard captureFence.accepts(token), self.selection == selection else { return }
            preview = png; capturedAt = Date()
            status = "Önizleme yalnızca bu Mac'te. Paylaşmak için kutuyu işaretleyip Gönder'e bas."
        } catch {
            guard captureFence.accepts(token) else { return }
            status = error.localizedDescription
        }
    }
    public func revokeShare() { selectWindow(nil); status = "Pencere paylaşımı kapalı. Önceden gönderilen görüntüler geri alınmaz." }

    public func send() async {
        guard connected, !sending, !capturing, !stopped, !stopping, !speechDriver.dictationBusy, !voiceConversationActive else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || includePreview else { return }
        if includePreview {
            guard preview != nil, let capturedAt, Date().timeIntervalSince(capturedAt) <= 60, selection != nil else {
                includePreview = false; status = "Önizleme yok veya 60 saniyeden eski. Yeni önizleme alıp paylaşımı tekrar seç."; return
            }
        }
        dictationDraft = nil; speechDriver.stop(); sending = true; liveReply = ""
        let token = sessionFence.token
        let png = includePreview ? preview : nil
        let scope = selection
        let shareToken = captureFence.token
        status = "Yanıt bekleniyor…"
        do {
            var image: URL?
            if let png {
                let folder = directory.appendingPathComponent("Attachments", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let url = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
                try png.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                image = url
            }
            guard sessionFence.accepts(token), captureFence.accepts(shareToken) || png == nil else { throw CancellationError() }
            let prompt = text.isEmpty ? "Paylaştığım pencere görüntüsünü kısaca açıkla." : text
            let reply = try await conversation.send(text: prompt, image: image)
            guard sessionFence.accepts(token) else { return }
            lines.append(CompanionLine(speaker: "YOU", text: prompt + (png == nil ? "" : "\n[Paylaşılan pencere: \(scope?.label ?? "")]")))
            lines.append(CompanionLine(speaker: "CODEX", text: reply))
            lines = Array(lines.suffix(80))
            draft = ""; sending = false; liveReply = ""
            if captureFence.accepts(shareToken) { preview = nil; includePreview = false; capturedAt = nil }
            status = "Yanıt alındı · mikrofon kapalı"
            if speakReplies { speechDriver.speak(reply) }
        } catch {
            guard sessionFence.accepts(token) else { return }
            if (error as? CompanionFailure)?.requiresReconnect == true {
                connected = false; threadID = nil
            }
            sending = false; liveReply = ""; status = "\(error.localizedDescription) Metin korundu; otomatik yeniden gönderilmedi."
        }
    }

    /// Synchronous local revocation comes before any server round-trip.
    public func stop() {
        guard !stopping else { return }
        let needsConversationStop = !stopped
        pauseVoiceConversation(); voiceTask?.cancel(); voiceTask = nil
        stopped = true; sessionFence.revoke(); stopScreenSharing(); captureFence.revoke(); speechDriver.stop()
        dictationDraft = nil
        connected = false; connecting = false; sending = false; capturing = false
        screenShareSending = false; displaySelection = nil; lastSharedAt = nil; liveReply = ""
        voiceSendInFlight = false; voiceSendID = nil
        requestingScreenPermission = false; displayListingID = nil
        selection = nil; preview = nil; capturedAt = nil; includePreview = false; threadID = nil
        status = "Durduruldu · mikrofon, paylaşım ve ses kapalı"
        guard needsConversationStop else { return }
        stopping = true
        stopTask = Task { await conversation.stop(); stopping = false; stopTask = nil }
    }

    /// Application termination waits for the same STOP task; it never launches a second teardown.
    public func shutdown() async {
        stop()
        await stopTask?.value
    }

    /// A reopened panel waits for prior STOP without initiating another STOP.
    public func waitForPendingStop() async { await stopTask?.value }
}
