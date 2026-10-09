import Foundation
import BavbavCompanion

/// Deterministic text/energy/epoch checks only. No permissions, microphone,
/// speech recognizer or synthesizer is started by these fixtures.
@MainActor enum CompanionSpeechEndpointTests {
    static func run() {
        var quiet = CompanionSpeechEndpoint(startedAt: 100)
        expectFalse(quiet.heardSpeech)
        expectEqual(quiet.decision(at: 114.99), .continueListening)
        expectEqual(quiet.decision(at: 115), .noSpeech)
        quiet.observeAudio(energy: 0.5, at: 114.9)
        quiet.observeTranscript(" \n ", at: 114.9)
        expectFalse(quiet.heardSpeech)
        expectEqual(quiet.decision(at: 115), .noSpeech)

        var phrase = CompanionSpeechEndpoint(startedAt: 100)
        phrase.observeTranscript("Merhaba", at: 100.25)
        expectTrue(phrase.heardSpeech)
        expectEqual(phrase.decision(at: 101.59), .continueListening)
        expectEqual(phrase.decision(at: 101.61), .finish)
        phrase.observeTranscript("Merhaba", at: 100.9)
        expectEqual(phrase.decision(at: 101.61), .finish) // identical partial does not postpone silence
        phrase.observeTranscript("Merhaba Bavbav", at: 100.9)
        expectEqual(phrase.decision(at: 102.24), .continueListening)
        expectEqual(phrase.decision(at: 102.26), .finish)

        var longPhrase = CompanionSpeechEndpoint(startedAt: 0)
        longPhrase.observeTranscript("Uzun bir Türkçe cümle", at: 0.1)
        // Recognition partials can lag while the person keeps speaking. Real
        // audio energy must prevent premature endpointing during that gap.
        for time in stride(from: 0.25, through: 20, by: 0.25) {
            longPhrase.observeAudio(energy: 0.02, at: time)
            expectEqual(longPhrase.decision(at: time + 1.34), .continueListening)
        }
        expectEqual(longPhrase.decision(at: 21.36), .finish)

        var lowEnergy = CompanionSpeechEndpoint(startedAt: 0)
        lowEnergy.observeTranscript("Düşük arka plan sesi", at: 0.1)
        lowEnergy.observeAudio(energy: 0.001, at: 1.4)
        expectEqual(lowEnergy.decision(at: 1.46), .finish)
        lowEnergy.observeAudio(energy: .nan, at: 1.4)
        lowEnergy.observeAudio(energy: .infinity, at: 1.4)
        lowEnergy.observeAudio(energy: 0.03, at: .infinity)
        lowEnergy.observeTranscript("Eski olay", at: -1)
        expectEqual(lowEnergy.decision(at: 1.46), .finish)
        expectEqual(lowEnergy.decision(at: .nan), .continueListening)

        var invalidTime = CompanionSpeechEndpoint(startedAt: 100)
        invalidTime.observeTranscript("Geç kalan eski oturum", at: 99)
        invalidTime.observeAudio(energy: 1, at: 99)
        expectFalse(invalidTime.heardSpeech)
        expectEqual(invalidTime.decision(at: 115), .noSpeech)

        var completion = CompanionSpeechRecognitionCompletion()
        let first = UUID(), second = UUID(), stale = UUID()
        completion.begin(first)
        expectFalse(completion.record("Eski metin", token: stale))
        expectTrue(completion.record("  Türkçe son kelimeler  ", token: first))
        expectTrue(completion.record("\n", token: first))
        expectNil(completion.finish(stale))
        expectEqual(completion.finish(first), .some(.transcript("Türkçe son kelimeler")))
        expectNil(completion.finish(first))
        expectFalse(completion.record("Geç gelen son sonuç", token: first))

        completion.begin(first)
        expectTrue(completion.record("STOP bunu göndermemeli", token: first))
        completion.cancel()
        expectNil(completion.finish(first))
        expectFalse(completion.record("İptalden sonra", token: first))
        completion.begin(second)
        expectNil(completion.finish(first))
        expectTrue(completion.record("Yeni oturum", token: second))
        expectEqual(completion.finish(second), .some(.transcript("Yeni oturum")))
        expectNil(completion.finish(second, failure: "Geç gelen hata"))

        completion.begin(first)
        expectTrue(completion.record("Taslak korunacak", token: first))
        expectEqual(completion.finish(first, failure: "Ses aygıtı değişti"), .some(.failure("Ses aygıtı değişti")))
        expectNil(completion.finish(first))
        completion.begin(second)
        expectEqual(completion.finish(second), .some(.failure("Konuşma duyulmadı; mikrofon kapatıldı.")))
        expectNil(completion.finish(second))

        // Explicit finish / the two-second finalization timeout share one
        // completion slot; a late final recognizer callback cannot deliver twice.
        var lifecycle = CompanionDictationLifecycle()
        let token = lifecycle.begin()!
        completion.begin(token)
        expectTrue(lifecycle.listen(token))
        expectTrue(completion.record("İlk kısmı", token: token))
        expectTrue(lifecycle.finalize(token))
        expectTrue(lifecycle.acceptsTranscript(token))
        expectTrue(completion.record("İlk kısmı ve son kelime", token: token))
        expectTrue(lifecycle.complete(token))
        expectEqual(completion.finish(token), .some(.transcript("İlk kısmı ve son kelime")))
        expectFalse(lifecycle.acceptsTranscript(token))
        expectNil(completion.finish(token))
        print("COMPANION SPEECH ENDPOINT CHECK PASSED: quiet after speech, audio-aware long phrases, bounded initial silence, exactly-once completion and STOP epochs; no live audio")
    }
}
