import Foundation
@testable import M1K3Voice
import Testing

/// SpeechAnalyzer replaces SFSpeechRecognizer inside AppleSpeechTranscriber
/// (Kev, 2026-09-26). Its results are per time range and it finalises a range
/// at pauses as short as 0.3 s (measured, scratch/speechanalyzer-spike), so the
/// transcriber folds and endpoints them itself to keep each FinalityPolicy's
/// contract with the consumer exactly as SFSpeech kept it.
struct AnalyzerTranscriptFoldTests {
    @Test("dictation (endsListen): cumulative partials, never a final mid-listen")
    func endsListenIsCumulative() {
        var fold = AnalyzerTranscriptFold(finality: .endsListen)
        #expect(fold.ingest(text: " Marta, can", isFinal: false) == TranscriptSegment(text: "Marta, can", isFinal: false))
        #expect(fold.ingest(text: " Marta, can you review?", isFinal: true)
            == TranscriptSegment(text: "Marta, can you review?", isFinal: false))
        #expect(fold.ingest(text: " Ravi's fix", isFinal: false)
            == TranscriptSegment(text: "Marta, can you review? Ravi's fix", isFinal: false))
        #expect(fold.closingSegment() == TranscriptSegment(text: "Marta, can you review? Ravi's fix", isFinal: true))
    }

    @Test("voice-first (keepsListening): each finalised range is its own final segment")
    func keepsListeningSegments() {
        var fold = AnalyzerTranscriptFold(finality: .keepsListening)
        #expect(fold.ingest(text: " Yes, I'll", isFinal: false) == TranscriptSegment(text: "Yes, I'll", isFinal: false))
        #expect(fold.ingest(text: " Yes, I'll review it.", isFinal: true)
            == TranscriptSegment(text: "Yes, I'll review it.", isFinal: true))
        #expect(fold.ingest(text: " And legal", isFinal: false) == TranscriptSegment(text: "And legal", isFinal: false))
        #expect(fold.closingSegment() == nil, "the consumer owns the boundary; nothing extra is yielded")
    }

    @Test("blank results yield nothing and don't wipe progress")
    func blanks() {
        var fold = AnalyzerTranscriptFold(finality: .endsListen)
        _ = fold.ingest(text: "hello", isFinal: false)
        #expect(fold.ingest(text: "  ", isFinal: false) == nil)
        #expect(fold.closingSegment()?.text == "hello")
        #expect(AnalyzerTranscriptFold(finality: .endsListen).closingSegment() == nil)
    }
}

/// PR #412 review: `isAvailable` said yes whenever the DEVICE had SpeechAnalyzer,
/// even for a locale it can't serve or whose asset isn't on disk yet, so the
/// mic looked ready and the listen failed at once.
struct AppleSpeechAvailabilityTests {
    @Test("available when the analyzer can serve this locale, else only if SFSpeech can")
    func availability() {
        #expect(AppleSpeechAvailability.isAvailable(analyzerServesLocale: true, legacyAvailable: false))
        #expect(!AppleSpeechAvailability.isAvailable(analyzerServesLocale: false, legacyAvailable: false))
        #expect(AppleSpeechAvailability.isAvailable(analyzerServesLocale: false, legacyAvailable: true))
        // Not known yet (the async check hasn't landed): never claim on the analyzer's behalf.
        #expect(!AppleSpeechAvailability.isAvailable(analyzerServesLocale: nil, legacyAvailable: false))
        #expect(AppleSpeechAvailability.isAvailable(analyzerServesLocale: nil, legacyAvailable: true))
    }
}

struct AnalyzerEndpointTests {
    private let loud: Float = 0.05
    private let quiet: Float = 0.0005

    private func feed(_ endpoint: inout AnalyzerEndpoint, rms: Float, seconds: Double) {
        var left = seconds
        while left > 0 {
            endpoint.audio(rms: rms, seconds: 0.1)
            left -= 0.1
        }
    }

    @Test("dictation: a final after a real pause ends the listen")
    func finalAfterPauseEnds() {
        var endpoint = AnalyzerEndpoint(finality: .endsListen)
        feed(&endpoint, rms: loud, seconds: 2)
        endpoint.result(isFinal: true, hasText: true)
        #expect(!endpoint.shouldEnd)
        feed(&endpoint, rms: quiet, seconds: 1.3)
        #expect(endpoint.shouldEnd)
    }

    /// The measured hazard: SpeechAnalyzer finalised "Marta, can you review" at
    /// a 0.3 s pause, mid-sentence.
    @Test("dictation: a final at a short mid-sentence pause does not end the listen")
    func shortPauseKeepsListening() {
        var endpoint = AnalyzerEndpoint(finality: .endsListen)
        feed(&endpoint, rms: loud, seconds: 2)
        feed(&endpoint, rms: quiet, seconds: 0.3)
        endpoint.result(isFinal: true, hasText: true)
        feed(&endpoint, rms: loud, seconds: 1)
        endpoint.result(isFinal: false, hasText: true)
        feed(&endpoint, rms: quiet, seconds: 1.3)
        #expect(!endpoint.shouldEnd, "new words since the final: wait for the next one")
        endpoint.result(isFinal: true, hasText: true)
        #expect(endpoint.shouldEnd)
    }

    @Test("dictation: words then a long quiet end even if no final ever lands")
    func quietWithoutFinalBackstop() {
        var endpoint = AnalyzerEndpoint(finality: .endsListen)
        feed(&endpoint, rms: loud, seconds: 1)
        endpoint.result(isFinal: false, hasText: true)
        feed(&endpoint, rms: quiet, seconds: 2.5)
        #expect(!endpoint.shouldEnd)
        feed(&endpoint, rms: quiet, seconds: 0.6)
        #expect(endpoint.shouldEnd)
    }

    @Test("either mode: a listen with no words ends after the silent-listen limit, noise or not")
    func silentListenEnds() {
        for finality in [FinalityPolicy.endsListen, .keepsListening] {
            var endpoint = AnalyzerEndpoint(finality: finality)
            feed(&endpoint, rms: loud, seconds: AnalyzerEndpoint.silentListenLimit - 0.5)
            #expect(!endpoint.shouldEnd)
            feed(&endpoint, rms: loud, seconds: 0.6)
            #expect(endpoint.shouldEnd)
        }
    }

    @Test("voice-first: once there are words the consumer's endpointer owns the turn")
    func keepsListeningNeverEndsWithText() {
        var endpoint = AnalyzerEndpoint(finality: .keepsListening)
        feed(&endpoint, rms: loud, seconds: 1)
        endpoint.result(isFinal: true, hasText: true)
        feed(&endpoint, rms: quiet, seconds: 20)
        #expect(!endpoint.shouldEnd)
    }

    @Test("RMS of a buffer's samples")
    func rms() {
        #expect(AnalyzerEndpoint.rms([]) == 0)
        #expect(abs(AnalyzerEndpoint.rms([0.5, -0.5, 0.5, -0.5]) - 0.5) < 0.0001)
    }
}
