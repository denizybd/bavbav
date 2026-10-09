import Foundation

/// Pure recognition state: closing the microphone does not invalidate a pending final transcript.
/// STOP/mute do invalidate it. Kept independent of Speech/AVFoundation for deterministic checks.
public struct CompanionDictationLifecycle {
    public enum Phase: Equatable { case idle, preparing, listening, finalizing }
    public static let finalizationTimeoutNanoseconds: UInt64 = 2_000_000_000
    public private(set) var phase: Phase = .idle
    public private(set) var token = UUID()
    public var busy: Bool { phase != .idle }

    public init() {}
    public mutating func begin() -> UUID? {
        guard !busy else { return nil }
        token = UUID(); phase = .preparing
        return token
    }
    public func accepts(_ candidate: UUID) -> Bool { token == candidate && busy }
    public func acceptsTranscript(_ candidate: UUID) -> Bool {
        token == candidate && (phase == .listening || phase == .finalizing)
    }
    @discardableResult public mutating func listen(_ candidate: UUID) -> Bool {
        guard accepts(candidate), phase == .preparing else { return false }
        phase = .listening; return true
    }
    @discardableResult public mutating func finalize(_ candidate: UUID) -> Bool {
        guard accepts(candidate), phase == .listening else { return false }
        phase = .finalizing; return true
    }
    @discardableResult public mutating func complete(_ candidate: UUID) -> Bool {
        guard accepts(candidate) else { return false }
        cancel(); return true
    }
    public mutating func cancel() { token = UUID(); phase = .idle }
}

/// Never replace an edit made while authorization or a final recognition result was pending.
public struct CompanionDictationDraft {
    private let original: String
    private var expected: String
    public init(original: String) { self.original = original; expected = original }
    public mutating func merge(transcript: String, currentDraft: String) -> String? {
        guard currentDraft == expected else { return nil }
        expected = original + (original.isEmpty ? "" : "\n") + transcript
        return expected
    }
}
