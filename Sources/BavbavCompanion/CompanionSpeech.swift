import AVFoundation
import Speech
import Combine

@MainActor public protocol CompanionSpeechDriving: AnyObject {
    var onTranscript: ((String) -> Void)? { get set }
    var onDictationFinished: ((String) -> Void)? { get set }
    var onDictationFailed: ((String) -> Void)? { get set }
    var onSpeakingFinished: (() -> Void)? { get set }
    var dictationBusy: Bool { get }
    var speaking: Bool { get }
    var status: String { get }
    func start(allowAppleService: Bool, endOnSilence: Bool) async
    func finishListening()
    func stopListening()
    func speak(_ text: String)
    func stopSpeaking()
    func stop()
}

/// The input callback only accumulates a scalar energy/time pair. Main-actor
/// silence decisions run five times per second, without queueing every buffer
/// or retaining PCM audio. try-lock avoids blocking the realtime input thread.
private final class CompanionAudioEnergy: @unchecked Sendable {
    private let lock = NSLock()
    private var energy: Double = 0
    private var time: TimeInterval = 0
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let frames = Int(buffer.frameLength)
        let channelCount = min(2, Int(buffer.format.channelCount))
        let sampleStride = max(1, buffer.stride)
        guard channelCount > 0 else { return }
        var squares = 0.0, samples = 0
        for channel in 0..<channelCount {
            for index in stride(from: 0, to: frames, by: 4) {
                let sample = Double(channels[channel][index * sampleStride])
                squares += sample * sample; samples += 1
            }
        }
        let value = sqrt(squares / Double(max(1, samples)))
        guard value.isFinite, lock.try() else { return }
        energy = max(energy, value)
        if value >= CompanionSpeechEndpoint.minimumVoiceEnergy { time = ProcessInfo.processInfo.systemUptime }
        lock.unlock()
    }
    func drain() -> (energy: Double, time: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        let result = (energy, time); energy = 0; time = 0
        return result
    }
}

@MainActor public final class CompanionSpeech: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, CompanionSpeechDriving {
    @Published public private(set) var listening = false
    @Published public private(set) var preparing = false
    @Published public private(set) var finalizing = false
    @Published public private(set) var speaking = false
    @Published public private(set) var status = "Mikrofon kapalı"
    public var onTranscript: ((String) -> Void)?
    public var onDictationFinished: ((String) -> Void)?
    public var onDictationFailed: ((String) -> Void)?
    public var onSpeakingFinished: (() -> Void)?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "tr-TR"))
    private let synthesizer = AVSpeechSynthesizer()
    private var engine: AVAudioEngine?
    private var recognition: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var lifecycle = CompanionDictationLifecycle()
    private var completion = CompanionSpeechRecognitionCompletion()
    private var endpoint: CompanionSpeechEndpoint?
    private var currentUtterance: AVSpeechUtterance?
    private var timeout: Task<Void, Never>?
    private var finalizationTimeout: Task<Void, Never>?
    private var silenceTimeout: Task<Void, Never>?
    private var audioObserver: NSObjectProtocol?
    private var tapInstalled = false
    public var dictationBusy: Bool { lifecycle.busy }
    public var supportsLocalTurkish: Bool { recognizer?.supportsOnDeviceRecognition == true }
    public var hasTurkishVoice: Bool { AVSpeechSynthesisVoice(language: "tr-TR") != nil }

    public override init() { super.init(); synthesizer.delegate = self }

    public func start(allowAppleService: Bool, endOnSilence: Bool = false) async {
        guard !lifecycle.busy else { return }
        stopListening(); stopSpeaking()
        guard let token = lifecycle.begin() else { return }
        completion.begin(token)
        publishLifecycle()
        defer {
            if lifecycle.accepts(token), lifecycle.phase == .preparing {
                completeRecognition(token, failure: "Mikrofon başlatılamadı.")
            }
        }
        status = "Mikrofon ve konuşma tanıma izinleri bekleniyor…"
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            ? true : await AVCaptureDevice.requestAccess(for: .audio)
        guard lifecycle.accepts(token) else { return }
        guard !Task.isCancelled else { stopListening(); return }
        guard microphone else {
            completeRecognition(token, failure: "Sistem Ayarları → Gizlilik → Mikrofon → Bavbav izni gerekiyor."); return
        }
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard lifecycle.accepts(token) else { return }
        guard !Task.isCancelled else { stopListening(); return }
        guard authorization == .authorized else {
            completeRecognition(token, failure: "Sistem Ayarları → Gizlilik → Konuşma Tanıma → Bavbav izni gerekiyor."); return
        }
        guard let recognizer, recognizer.isAvailable else {
            completeRecognition(token, failure: "Türkçe konuşma tanıma şu anda kullanılamıyor."); return
        }
        guard supportsLocalTurkish || allowAppleService else {
            completeRecognition(token, failure: "Cihaz içi Türkçe yok. İstersen Apple konuşma hizmeti seçeneğini aç; aksi halde yazarak devam et."); return
        }
        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = supportsLocalTurkish
        request.taskHint = .dictation
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            completeRecognition(token, failure: "Kullanılabilir mikrofon bulunamadı."); return
        }
        self.engine = engine; self.request = request
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.lifecycle.acceptsTranscript(token) else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.completion.record(text, token: token)
                    self.endpoint?.observeTranscript(text, at: ProcessInfo.processInfo.systemUptime)
                    self.onTranscript?(text)
                }
                // The transcript receiver may mute/STOP after detecting a concurrent draft edit.
                guard self.lifecycle.acceptsTranscript(token) else { return }
                if let error {
                    self.completeRecognition(token, failure: "Tanıma sona erdi; mevcut metin korundu. \(error.localizedDescription)")
                } else if result?.isFinal == true { self.completeRecognition(token) }
            }
        }
        let meter = endOnSilence ? CompanionAudioEnergy() : nil
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer); meter?.append(buffer)
        }
        tapInstalled = true
        do {
            engine.prepare(); try engine.start()
            lifecycle.listen(token); publishLifecycle()
            if let meter {
                endpoint = CompanionSpeechEndpoint(startedAt: ProcessInfo.processInfo.systemUptime)
                silenceTimeout = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
                        guard !Task.isCancelled, let self, self.lifecycle.accepts(token), self.lifecycle.phase == .listening else { return }
                        let sample = meter.drain()
                        self.endpoint?.observeAudio(energy: sample.energy, at: sample.time)
                        switch self.endpoint?.decision(at: ProcessInfo.processInfo.systemUptime) {
                        case .finish: self.finishListening(); return
                        case .noSpeech: self.completeRecognition(token, failure: "Konuşma duyulmadı; sesli görüşme duraklatıldı."); return
                        default: break
                        }
                    }
                }
            }
            status = supportsLocalTurkish ? "Dinleniyor · cihaz içi Türkçe" : "Dinleniyor · Apple konuşma hizmeti"
            timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 55_000_000_000)
                guard !Task.isCancelled, let self, self.lifecycle.acceptsTranscript(token) else { return }
                self.finishListening(); self.status = "55 saniye doldu; mikrofon kapalı, son kelimeler tamamlanıyor…"
            }
            audioObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.lifecycle.accepts(token) else { return }
                    self.completeRecognition(token, failure: "Ses aygıtı değişti; mikrofon güvenli biçimde kapatıldı.")
                }
            }
        } catch { completeRecognition(token, failure: "Mikrofon başlatılamadı: \(error.localizedDescription)") }
    }

    private func publishLifecycle() {
        preparing = lifecycle.phase == .preparing
        listening = lifecycle.phase == .listening
        finalizing = lifecycle.phase == .finalizing
    }

    /// Removes the audio input immediately, but deliberately leaves recognition alive for endAudio.
    private func closeMicrophone() {
        timeout?.cancel(); timeout = nil
        silenceTimeout?.cancel(); silenceTimeout = nil; endpoint = nil
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

    private func completeRecognition(_ token: UUID, failure: String? = nil) {
        guard lifecycle.complete(token) else { return }
        let result = completion.finish(token, failure: failure)
        // Revoke before cancel() so late completion callbacks cannot resurrect the old draft.
        disposeRecognition(); publishLifecycle()
        switch result {
        case .transcript(let transcript):
            status = "Türkçe konuşma tamamlandı."
            onDictationFinished?(transcript)
        case .failure(let message):
            status = message; onDictationFailed?(message)
        case nil: break
        }
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
            self.completeRecognition(token)
        }
    }

    /// Mute/STOP: cancel recognition immediately, including permission preparation/finalization.
    public func stopListening() {
        lifecycle.cancel(); completion.cancel(); disposeRecognition(); publishLifecycle()
        status = "Mikrofon kapalı · metin otomatik gönderilmez"
    }

    public func speak(_ text: String) {
        stopListening(); stopSpeaking()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
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
            guard let self, self.currentUtterance === utterance else { return }
            self.speaking = false; self.currentUtterance = nil
            self.status = "Yanıt seslendirildi."
            self.onSpeakingFinished?()
        }
    }
    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.currentUtterance === utterance else { return }
            self.speaking = false; self.currentUtterance = nil
            self.status = "Sesli yanıt beklenmeden kesildi; görüşme duraklatıldı."
            // Expected stopSpeaking() clears identity before invoking AV's
            // cancellation. Only an unexpected current native cancellation
            // reaches this failure callback; it never restarts listening.
            self.onDictationFailed?(self.status)
        }
    }
    public var permissionSummary: String {
        "microphone=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) speech=\(SFSpeechRecognizer.authorizationStatus().rawValue) trAvailable=\(recognizer?.isAvailable == true) trOnDevice=\(supportsLocalTurkish) trVoice=\(hasTurkishVoice)"
    }
}
