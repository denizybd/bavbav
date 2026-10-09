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
    public let speech: CompanionSpeech
    private let conversation: any CompanionConversation
    private let screen: any CompanionScreenSource
    private let directory: URL
    private let sessionFence = CompanionFence()
    private let captureFence = CompanionFence()
    private var capturedAt: Date?
    private var dictationDraft: CompanionDictationDraft?
    private var stopTask: Task<Void, Never>?
    private var stopped = true

    public init(conversation: any CompanionConversation, screen: any CompanionScreenSource,
                directory: URL, speech: CompanionSpeech? = nil) {
        self.conversation = conversation; self.screen = screen; self.directory = directory; self.speech = speech ?? CompanionSpeech()
        self.speech.onTranscript = { [weak self] text in
            guard let self, !self.stopped, !self.muted else { return }
            guard var dictationDraft = self.dictationDraft else { return }
            guard let merged = dictationDraft.merge(transcript: text, currentDraft: self.draft) else {
                self.dictationDraft = nil; self.speech.stopListening()
                self.status = "Metin değiştirildi; düzenlemen korundu ve dikte durduruldu."
                return
            }
            self.dictationDraft = dictationDraft; self.draft = merged
        }
    }

    public func connect() async {
        guard !connecting, !connected, !stopping else { return }
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
        guard !sending, !speech.dictationBusy, !connecting, !stopping else { return }
        let token = sessionFence.token
        if !connected { await connect() }
        guard connected, sessionFence.accepts(token), !stopped else { return }
        muted = false; dictationDraft = CompanionDictationDraft(original: draft)
        await speech.start(allowAppleService: allowAppleService)
    }
    public func mute() { muted = true; dictationDraft = nil; speech.stopListening() }
    public func finishDictation() { speech.finishListening() }

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
        guard connected, !sending, !stopped, !speech.dictationBusy else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || includePreview else { return }
        if includePreview {
            guard preview != nil, let capturedAt, Date().timeIntervalSince(capturedAt) <= 60, selection != nil else {
                includePreview = false; status = "Önizleme yok veya 60 saniyeden eski. Yeni önizleme alıp paylaşımı tekrar seç."; return
            }
        }
        dictationDraft = nil; speech.stop(); sending = true
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
            draft = ""; sending = false
            if captureFence.accepts(shareToken) { preview = nil; includePreview = false; capturedAt = nil }
            status = "Yanıt alındı · mikrofon kapalı"
            if speakReplies { speech.speak(reply) }
        } catch {
            guard sessionFence.accepts(token) else { return }
            if (error as? CompanionFailure)?.requiresReconnect == true {
                connected = false; threadID = nil
            }
            sending = false; status = "\(error.localizedDescription) Metin korundu; otomatik yeniden gönderilmedi."
        }
    }

    /// Synchronous local revocation comes before any server round-trip.
    public func stop() {
        guard !stopping else { return }
        let needsConversationStop = !stopped
        stopped = true; sessionFence.revoke(); captureFence.revoke(); speech.stop()
        dictationDraft = nil
        connected = false; connecting = false; sending = false; capturing = false
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
}
