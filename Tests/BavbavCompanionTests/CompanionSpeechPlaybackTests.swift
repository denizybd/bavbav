import Foundation
import BavbavCompanion

/// Pure policy/chunk/queue fixtures. No synthesizer, permission or model is used.
@MainActor enum CompanionSpeechPlaybackTests {
    static func run() {
        typealias Voice = CompanionNativeVoiceDescriptor
        let compact = Voice(id: "compact", name: "Yelda", language: "tr-TR", quality: .standard)
        let enhanced = Voice(id: "enhanced", name: "Yelda", language: "tr-TR", quality: .enhanced)
        let premium = Voice(id: "premium", name: "Yelda", language: "tr_TR", quality: .premium)
        let wrongLanguage = Voice(id: "english", name: "English", language: "en-US", quality: .premium)
        let personal = Voice(id: "personal", name: "Personal", language: "tr-TR", quality: .premium, personal: true)
        let novelty = Voice(id: "novelty", name: "Novelty", language: "tr-TR", quality: .premium, novelty: true)
        expectEqual(CompanionNativeVoiceSelection.preferred([compact]), compact)
        expectEqual(CompanionNativeVoiceSelection.preferred([compact, enhanced]), enhanced)
        expectEqual(CompanionNativeVoiceSelection.preferred([premium, compact, enhanced], defaultID: compact.id), premium)
        expectEqual(CompanionNativeVoiceSelection.preferred([wrongLanguage, personal, novelty, compact]), compact)
        expectNil(CompanionNativeVoiceSelection.preferred([wrongLanguage, personal, novelty]))
        let sibling = Voice(id: "enhanced2", name: "Alternate", language: "tr-TR", quality: .enhanced)
        expectEqual(CompanionNativeVoiceSelection.preferred([enhanced, sibling], defaultID: sibling.id), sibling)

        var chunks = CompanionSpeechTextChunks()
        expectTrue(chunks.append("Mer").isEmpty)
        expectEqual(chunks.append("haba."), ["Merhaba."])
        expectTrue(chunks.append(" İkinci cümle henüz bitmedi").isEmpty)
        expectEqual(chunks.finish(), ["İkinci cümle henüz bitmedi"])
        expectTrue(chunks.finish().isEmpty)
        expectTrue(chunks.append("Geç gelen metin.").isEmpty)

        var decimal = CompanionSpeechTextChunks()
        expectTrue(decimal.append("Pi yaklaşık 3.").isEmpty)
        expectTrue(decimal.append("14 değerindedir").isEmpty)
        expectEqual(decimal.append("."), ["Pi yaklaşık 3.14 değerindedir."])
        var abbreviation = CompanionSpeechTextChunks()
        expectTrue(abbreviation.append("Dr. Ahmet").isEmpty)
        expectEqual(abbreviation.append(" bugün geliyor."), ["Dr. Ahmet bugün geliyor."])
        var markdown = CompanionSpeechTextChunks()
        let spoken = markdown.append("## Başlık\n- **Türkçe** cümle burada tamamlandı. ") + markdown.finish()
        expectEqual(spoken.joined(separator: " "), "Başlık Türkçe cümle burada tamamlandı.")

        var bounded = CompanionSpeechTextChunks()
        let large = String(repeating: "a", count: 20_000)
        let boundedChunks = bounded.append(large) + bounded.finish()
        expectTrue(bounded.truncated)
        expectTrue(boundedChunks.count <= CompanionSpeechTextChunks.maximumChunks)
        expectTrue(boundedChunks.allSatisfy { $0.count <= CompanionSpeechTextChunks.chunkMaximum })
        expectEqual(boundedChunks.map(\.count).reduce(0, +), CompanionSpeechTextChunks.maximumCharacters)
        expectEqual(bounded.bufferedCharacters, 0)
        var punctuationSpam = CompanionSpeechTextChunks()
        let spamChunks = punctuationSpam.append(String(repeating: "a. ", count: 2000)) + punctuationSpam.finish()
        expectTrue(spamChunks.count <= CompanionSpeechTextChunks.maximumChunks)
        expectTrue(punctuationSpam.truncated)
        expectEqual(punctuationSpam.bufferedCharacters, 0)

        var queue = CompanionSpeechPlaybackQueue()
        queue.begin(); queue.append("İlk cümle.")
        let first = queue.next()!
        expectEqual(first.text, "İlk cümle.")
        expectNil(queue.next())
        expectFalse(queue.takeFinished())
        expectTrue(queue.finishChunk(first.id))
        expectFalse(queue.finishChunk(first.id))
        expectFalse(queue.takeFinished()) // open model stream is not overall audio completion
        queue.append(" İkinci cümle devam ediyor.")
        queue.finish()
        let second = queue.next()!
        expectFalse(queue.takeFinished())
        expectFalse(queue.finishChunk(first.id))
        expectTrue(queue.finishChunk(second.id))
        expectTrue(queue.takeFinished())
        expectFalse(queue.takeFinished())
        expectEqual(queue.pendingCount, 0)
        queue.append("Kapalı akışa geç metin.")
        expectNil(queue.next())

        queue.begin(); queue.append("STOP'tan önce.")
        let stopped = queue.next()!
        queue.cancel()
        expectFalse(queue.finishChunk(stopped.id))
        expectFalse(queue.takeFinished())
        expectNil(queue.next())
        queue.begin(); queue.append("Yeni akış."); queue.finish()
        let replacement = queue.next()!
        expectFalse(queue.finishChunk(stopped.id))
        expectTrue(queue.finishChunk(replacement.id))
        expectTrue(queue.takeFinished())
        queue.begin(); queue.finish()
        expectFalse(queue.hasSpeech)
        expectFalse(queue.inputOpen)
        expectFalse(queue.takeFinished()) // no synthetic success for empty text
        print("COMPANION SPEECH PLAYBACK CHECK PASSED: best installed Turkish voice policy, bounded sentence streaming, natural-completion queue and STOP epochs; no live audio")
    }
}
