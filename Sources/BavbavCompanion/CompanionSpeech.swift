import AVFoundation
import Speech
import Combine

@MainActor public final class CompanionSpeech: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published public private(set) var listening = false
    @Published public private(set) var preparing = false
    @Published public private(set) var speaking = false
    @Published public private(set) var status = "Mikrofon kapalı"
    public var onTranscript: ((String) -> Void)?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "tr-TR"))
    private let synthesizer = AVSpeechSynthesizer()
    private var engine: AVAudioEngine?
    private var recognition: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var generation = UUID()
    private var currentUtterance: AVSpeechUtterance?
    private var timeout: Task<Void, Never>?
    private var audioObserver: NSObjectProtocol?
    public var supportsLocalTurkish: Bool { recognizer?.supportsOnDeviceRecognition == true }
    public var hasTurkishVoice: Bool { AVSpeechSynthesisVoice(language: "tr-TR") != nil }

    public override init() { super.init(); synthesizer.delegate = self }

    public func start(allowAppleService: Bool) async {
        guard !preparing else { return }
        stopListening(); stopSpeaking()
        let token = generation
        preparing = true
        defer { if generation == token { preparing = false } }
        status = "Mikrofon ve konuşma tanıma izinleri bekleniyor…"
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            ? true : await AVCaptureDevice.requestAccess(for: .audio)
        guard generation == token else { return }
        guard microphone else { status = "Sistem Ayarları → Gizlilik → Mikrofon → Bavbav izni gerekiyor."; return }
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard generation == token else { return }
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
                guard let self, self.generation == token else { return }
                if let result { self.onTranscript?(result.bestTranscription.formattedString) }
                if error != nil || result?.isFinal == true {
                    self.stopListening()
                    self.status = error == nil ? "Metni kontrol edip Gönder'e bas." : "Tanıma sona erdi; metni kontrol et. \(error!.localizedDescription)"
                }
            }
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        do {
            engine.prepare(); try engine.start()
            listening = true
            status = supportsLocalTurkish ? "Dinleniyor · cihaz içi Türkçe" : "Dinleniyor · Apple konuşma hizmeti"
            timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 55_000_000_000)
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.stopListening(); self.status = "55 saniye doldu; metni kontrol et. Devam etmek için tekrar Başlat."
            }
            audioObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.stopListening(); self.status = "Ses aygıtı değişti; mikrofon güvenli biçimde kapatıldı."
                }
            }
        } catch { stopListening(); status = "Mikrofon başlatılamadı: \(error.localizedDescription)" }
    }

    public func stopListening() {
        generation = UUID(); preparing = false; timeout?.cancel(); timeout = nil
        if let audioObserver { NotificationCenter.default.removeObserver(audioObserver) }
        audioObserver = nil
        engine?.stop(); engine?.inputNode.removeTap(onBus: 0)
        request?.endAudio(); recognition?.cancel()
        engine = nil; request = nil; recognition = nil; listening = false
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
