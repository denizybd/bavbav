import Foundation

public struct CompanionNativeVoiceDescriptor: Equatable, Sendable {
    public enum Quality: Int, Sendable {
        case standard = 1, enhanced = 2, premium = 3
        public var label: String {
            switch self { case .standard: return "standart"; case .enhanced: return "geliştirilmiş"; case .premium: return "premium" }
        }
    }
    public let id: String
    public let name: String
    public let language: String
    public let quality: Quality
    public let personal: Bool
    public let novelty: Bool
    public init(id: String, name: String, language: String, quality: Quality,
                personal: Bool = false, novelty: Bool = false) {
        self.id = id; self.name = name; self.language = language; self.quality = quality
        self.personal = personal; self.novelty = novelty
    }
}

public enum CompanionNativeVoiceSelection {
    /// Only already available native Turkish voices. No language substitution,
    /// Personal Voice authorization, model download or voice cloning.
    public static func preferred(_ voices: [CompanionNativeVoiceDescriptor], defaultID: String? = nil) -> CompanionNativeVoiceDescriptor? {
        func language(_ voice: CompanionNativeVoiceDescriptor) -> String {
            voice.language.lowercased().replacingOccurrences(of: "_", with: "-")
        }
        return voices.filter { ["tr", "tr-tr"].contains(language($0)) && !$0.personal && !$0.novelty }.sorted {
            if $0.quality != $1.quality { return $0.quality.rawValue > $1.quality.rawValue }
            if ($0.id == defaultID) != ($1.id == defaultID) { return $0.id == defaultID }
            if (language($0) == "tr-tr") != (language($1) == "tr-tr") { return language($0) == "tr-tr" }
            return $0.id < $1.id
        }.first
    }
}

/// Final-answer deltas only. Starts on a complete first phrase or a bounded
/// phrase-length prefix, without waiting for the entire model response.
public struct CompanionSpeechTextChunks: Sendable {
    public static let maximumCharacters = 6000
    public static let maximumChunks = 64
    public static let firstChunkMaximum = 180
    public static let chunkMaximum = 320
    private var pending = ""
    private var emitted = 0
    private var accepted = 0
    private var sealed = false
    public private(set) var truncated = false
    public var bufferedCharacters: Int { pending.count }
    public init() {}

    public mutating func append(_ delta: String) -> [String] {
        guard !sealed, emitted < Self.maximumChunks else { return [] }
        let portion = String(delta.prefix(max(0, Self.maximumCharacters - accepted)))
        if portion.count < delta.count { truncated = true }
        accepted += portion.count; pending += portion
        return extract(flush: false)
    }
    public mutating func finish() -> [String] {
        guard !sealed else { return [] }
        sealed = true; return extract(flush: true)
    }
    private mutating func extract(flush: Bool) -> [String] {
        var chunks: [String] = []
        while !pending.isEmpty, emitted < Self.maximumChunks {
            let characters = Array(pending)
            let maximum = emitted == 0 ? Self.firstChunkMaximum : Self.chunkMaximum
            let limit = min(maximum, characters.count)
            var end: Int?
            for index in 0..<limit {
                let value = characters[index]
                guard [".", "!", "?", "\n"].contains(value) else { continue }
                let after = index + 1 < characters.count ? characters[index + 1] : nil
                if value == "." {
                    if index > 0, characters[index - 1].isNumber, after == nil || after?.isNumber == true { continue }
                    let prefix = String(characters[...index]).lowercased()
                    if ["dr.", "prof.", "doç.", "sn.", "örn.", "vb.", "vs."].contains(where: { prefix.hasSuffix($0) }) { continue }
                }
                guard after == nil || after?.isWhitespace == true else { continue }
                // Avoid a queue of single-word utterances after the first phrase.
                if emitted > 0, index + 1 < 24 { continue }
                end = index + 1; break
            }
            if end == nil, characters.count >= maximum {
                end = (0..<limit).last(where: { characters[$0].isWhitespace && $0 > limit / 2 }).map { $0 + 1 } ?? limit
            }
            if end == nil, flush { end = limit }
            guard let end else { break }
            let raw = String(characters.prefix(end))
            pending = String(characters.dropFirst(end))
            let text = Self.spokenText(raw)
            if !text.isEmpty { chunks.append(text); emitted += 1 }
        }
        if emitted >= Self.maximumChunks, !pending.isEmpty { pending = ""; truncated = true }
        return chunks
    }
    private static func spokenText(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?m)^\s{0,3}(#{1,6}\s+|>\s*|[-•]\s+)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\[([^\]]+)\]\([^\)]+\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// At most one AV utterance is active; the bounded pending queue is text only.
/// Closing input never announces completion before the final utterance finishes.
public struct CompanionSpeechPlaybackQueue: Sendable {
    public struct Chunk: Equatable, Sendable { public let id: UUID; public let text: String }
    private var planner = CompanionSpeechTextChunks()
    private var pending: [String] = []
    private var accepting = false
    private var completed = false
    private var hadChunk = false
    public private(set) var current: Chunk?
    public var pendingCount: Int { pending.count }
    public var inputOpen: Bool { accepting }
    public var hasSpeech: Bool { hadChunk || !pending.isEmpty }
    public var truncated: Bool { planner.truncated }
    public init() {}
    public mutating func begin() {
        planner = CompanionSpeechTextChunks(); pending = []; current = nil
        accepting = true; completed = false; hadChunk = false
    }
    public mutating func append(_ delta: String) {
        guard accepting else { return }
        pending += planner.append(delta)
    }
    public mutating func finish() {
        guard accepting else { return }
        accepting = false; pending += planner.finish()
    }
    public mutating func next() -> Chunk? {
        guard current == nil, !pending.isEmpty else { return nil }
        let chunk = Chunk(id: UUID(), text: pending.removeFirst())
        current = chunk; hadChunk = true; return chunk
    }
    @discardableResult public mutating func finishChunk(_ id: UUID) -> Bool {
        guard current?.id == id else { return false }
        current = nil; return true
    }
    public mutating func takeFinished() -> Bool {
        guard !accepting, !completed, hadChunk, current == nil, pending.isEmpty else { return false }
        completed = true; return true
    }
    public mutating func cancel() {
        planner = CompanionSpeechTextChunks(); pending = []; current = nil
        accepting = false; completed = true; hadChunk = false
    }
}
