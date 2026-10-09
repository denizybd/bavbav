import Foundation

/// A low-frequency endpoint decision, not a continuous audio recording. Text
/// changes establish actual recognized speech; microphone energy keeps a long
/// phrase alive even while a recognizer delays its next partial result.
public struct CompanionSpeechEndpoint: Sendable {
    public enum Decision: Equatable { case continueListening, finish, noSpeech }
    public static let quietDuration: TimeInterval = 1.35
    public static let initialSilenceLimit: TimeInterval = 15
    public static let minimumVoiceEnergy: Double = 0.006
    private let startedAt: TimeInterval
    private var lastActivity: TimeInterval
    private var lastTranscript = ""
    public private(set) var heardSpeech = false

    public init(startedAt: TimeInterval) {
        self.startedAt = startedAt; lastActivity = startedAt
    }
    public mutating func observeTranscript(_ text: String, at time: TimeInterval) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard time.isFinite, time >= startedAt, !text.isEmpty, text != lastTranscript else { return }
        lastTranscript = text; heardSpeech = true; lastActivity = max(lastActivity, time)
    }
    public mutating func observeAudio(energy: Double, at time: TimeInterval) {
        guard energy.isFinite, energy >= Self.minimumVoiceEnergy,
              time.isFinite, time >= startedAt else { return }
        lastActivity = max(lastActivity, time)
    }
    public func decision(at time: TimeInterval) -> Decision {
        guard time.isFinite, time >= startedAt else { return .continueListening }
        if !heardSpeech {
            // Background noise is not a recognized utterance and cannot keep
            // an unattended microphone open indefinitely.
            return time - startedAt >= Self.initialSilenceLimit ? .noSpeech : .continueListening
        }
        return time - lastActivity >= Self.quietDuration ? .finish : .continueListening
    }
}

/// Exactly-once recognition completion independent of permission/media APIs.
/// Cancellation revokes the token without manufacturing a successful result.
public struct CompanionSpeechRecognitionCompletion: Sendable {
    public enum Result: Equatable, Sendable { case transcript(String), failure(String) }
    private var token: UUID?
    private var transcript = ""
    public init() {}
    public mutating func begin(_ token: UUID) { self.token = token; transcript = "" }
    @discardableResult public mutating func record(_ text: String, token: UUID) -> Bool {
        guard self.token == token else { return false }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { transcript = text }
        return true
    }
    public mutating func finish(_ token: UUID, failure: String? = nil) -> Result? {
        guard self.token == token else { return nil }
        self.token = nil
        if let failure { return .failure(failure) }
        guard !transcript.isEmpty else { return .failure("Konuşma duyulmadı; mikrofon kapatıldı.") }
        return .transcript(transcript)
    }
    public mutating func cancel() { token = nil; transcript = "" }
}
