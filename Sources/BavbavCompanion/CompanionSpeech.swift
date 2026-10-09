import AVFoundation
import Speech
import Combine

@MainActor public final class CompanionSpeech: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published public private(set) var listening = false
    @Published public private(set) var preparing = false
    @Published public private(set) var finalizing = false
    @Published public private(set) var speaking = false
    @Published public private(set) var status = "Mikrofon kapalı"
    public var onTranscript: ((String) -> Void)?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "tr-TR"))
    private let synthesizer = AVSpeechSynthesizer()
    private var engine: AVAudioEngine?
    private var recognition: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var lifecycle = CompanionDictationLifecycle()
    private var currentUtterance: AVSpeechUtterance?
    private var timeout: Task<Void, Never>?
    private var finalizationTimeout: Task<Void, Never>?
    private var audioObserver: NSObjectProtocol?
    private var tapInstalled = false
    public var dictationBusy: Bool { lifecycle.busy }
    public var supportsLocalTurkish: Bool { recognizer?.supportsOnDeviceRecognition == true }
    public var hasTurkishVoice: Bool { AVSpeechSynthesisVoice(language: "tr-TR") != nil }

    public override init() { super.init(); synthesizer.delegate = self }

    public func start(allowAppleService: Bool) async {
        guard !lifecycle.busy else { return }
        stopListening(); stopSpeaking()
        guard let token = lifecycle.begin() else { return }
        publishLifecycle()
        defer {
            if lifecycle.accepts(token), lifecycle.phase == .preparing {
                lifecycle.complete(token); publishLifecycle()
            }
        }
        status = "Mikrofon ve konuşma tanıma izinleri bekleniyor…"
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            ? true : await AVCaptureDevice.requestAccess(for: .audio)
        guard lifecycle.accepts(token) else { return }
        guard microphone else { status = "Sistem Ayarları → Gizlilik → Mikrofon → Bavbav izni gerekiyor."; return }
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard lifecycle.accepts(token) else { return }
        guard authorization == .authorized else { status = "Sistem Ayarları → Gizlilik → Konuşma Tanıma → Bavbav izni gerekiyor."; return }
        guard let recognizer, recognizer.isAvailable else { status = "Türkçe konuşma tanıma şu anda kullanılamıyor."; return }
        guard supportsLocalTurkish || allowAppleService else {
            status = "Cihaz içi Türkçe yok. İstersen Apple konuşma hizmeti seçeneğini aç; aksi halde yazarak devam et."; return
        }
        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = supportsLocalTurkish
        request.taskHint = .dictation
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { status = "Kullanılabilir mikrofon bulunamadı."; return }
        self.engine = engine; self.request = request
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.lifecycle.acceptsTranscript(token) else { return }
                if let result { self.onTranscript?(result.bestTranscription.formattedString) }
                // The transcript receiver may mute/STOP after detecting a concurrent draft edit.
                guard self.lifecycle.acceptsTranscript(token) else { return }
                if error != nil || result?.isFinal == true {
                    self.completeRecognition(token, status: error == nil
                        ? "Metni kontrol edip Gönder'e bas."
                        : "Tanıma sona erdi; mevcut metin korundu. \(error!.localizedDescription)")
                }
            }
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        tapInstalled = true
        do {
            engine.prepare(); try engine.start()
            lifecycle.listen(token); publishLifecycle()
            status = supportsLocalTurkish ? "Dinleniyor · cihaz içi Türkçe" : "Dinleniyor · Apple konuşma hizmeti"
            timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 55_000_000_000)
                guard !Task.isCancelled, let self, self.lifecycle.acceptsTranscript(token) else { return }
                self.finishListening(); self.status = "55 saniye doldu; mikrofon kapalı, son kelimeler tamamlanıyor…"
            }
            audioObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.lifecycle.accepts(token) else { return }
                    self.stopListening(); self.status = "Ses aygıtı değişti; mikrofon güvenli biçimde kapatıldı."
                }
            }
        } catch { stopListening(); status = "Mikrofon başlatılamadı: \(error.localizedDescription)" }
    }

    private func publishLifecycle() {
        preparing = lifecycle.phase == .preparing
        listening = lifecycle.phase == .listening
        finalizing = lifecycle.phase == .finalizing
    }

    /// Removes the audio input immediately, but deliberately leaves recognition alive for endAudio.
    private func closeMicrophone() {
        timeout?.cancel(); timeout = nil
        if let audioObserver { NotificationCenter.default.removeObserver(audioObserver) }
        audioObserver = nil
        engine?.stop()
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0) }
        tapInstalled = false; engine = nil
    }

    private func disposeRecognition() {
        finalizationTimeout?.cancel(); finalizationTimeout = nil
        closeMicrophone()
        request?.endAudio(); recognition?.cancel()
        request = nil; recognition = nil
    }

    private func completeRecognition(_ token: UUID, status: String) {
        guard lifecycle.complete(token) else { return }
        // Revoke before cancel() so late completion callbacks cannot resurrect the old draft.
        disposeRecognition(); publishLifecycle(); self.status = status
    }

    /// End dictation: microphone closes now; the last recognition result has at most two seconds.
    public func finishListening() {
        let token = lifecycle.token
        guard lifecycle.finalize(token) else { return }
        closeMicrophone(); publishLifecycle()
        status = "Mikrofon kapalı · son kelimeler tamamlanıyor…"
        request?.endAudio()
        finalizationTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: CompanionDictationLifecycle.finalizationTimeoutNanoseconds)
            guard !Task.isCancelled, let self, self.lifecycle.phase == .finalizing else { return }
            self.completeRecognition(token, status: "Metin hazır; kontrol edip Gönder'e bas.")
        }
    }

    /// Mute/STOP: cancel recognition immediately, including permission preparation/finalization.
    public func stopListening() {
        lifecycle.cancel(); disposeRecognition(); publishLifecycle()
        status = "Mikrofon kapalı · metin otomatik gönderilmez"
    }

    public func speak(_ text: String) {
        stopListening(); stopSpeaking()
        guard let voice = AVSpeechSynthesisVoice(language: "tr-TR") else {
            status = "Türkçe ses yüklü değil. macOS Erişilebilirlik → Seslendirilen İçerik'ten Türkçe ses ekle."; return
        }
        // Long answers remain readable; avoid minutes of uninterruptible speech.
        let utterance = AVSpeechUtterance(string: String(text.prefix(6000)))
        utterance.voice = voice; utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        currentUtterance = utterance
        speaking = true; status = "Türkçe yanıt seslendiriliyor"
        synthesizer.speak(utterance)
    }
    public func stopSpeaking() { currentUtterance = nil; synthesizer.stopSpeaking(at: .immediate); speaking = false }
    public func stop() { stopListening(); stopSpeaking() }
    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard self?.currentUtterance === utterance else { return }
            self?.speaking = false; self?.currentUtterance = nil
        }
    }
    public var permissionSummary: String {
        "microphone=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) speech=\(SFSpeechRecognizer.authorizationStatus().rawValue) trAvailable=\(recognizer?.isAvailable == true) trOnDevice=\(supportsLocalTurkish) trVoice=\(hasTurkishVoice)"
    }
}
