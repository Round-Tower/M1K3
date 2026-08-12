//
//  TranscriptionTests.swift
//  M1K3VoiceTests
//
//  Contract tests for the live-dictation seam — the pure pieces (segment model,
//  router selection, partial→final accumulation). The actual recognisers
//  (AppleSpeech, WhisperKit) are OS/mic adapters verified by launching the app,
//  exactly like AVSpeechProvider; this pins everything that doesn't need a mic.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.9, Prior: Unknown

@testable import M1K3Voice
import Testing

struct TranscriptSegmentTests {
    @Test("confidence clamps into 0...1 (or stays nil)")
    func clampsConfidence() {
        #expect(TranscriptSegment(text: "hi", isFinal: false, confidence: 1.5).confidence == 1.0)
        #expect(TranscriptSegment(text: "hi", isFinal: false, confidence: -0.2).confidence == 0.0)
        #expect(TranscriptSegment(text: "hi", isFinal: false, confidence: 0.7).confidence == 0.7)
        #expect(TranscriptSegment(text: "hi", isFinal: true).confidence == nil)
    }
}

/// A fake recogniser: drives router selection without a microphone.
private struct FakeTranscriber: TranscriptionProvider {
    let name: String
    let isAvailable: Bool
    var attemptsEchoCancellation = false
    func startListening() -> AsyncStream<TranscriptSegment> {
        AsyncStream { $0.finish() }
    }

    func stopListening() {}
}

struct TranscriptionRouterTests {
    @Test("active provider is the first available, in declaration order")
    func picksFirstAvailable() {
        let router = TranscriptionRouter(providers: [
            FakeTranscriber(name: "whisper", isAvailable: false),
            FakeTranscriber(name: "apple", isAvailable: true),
        ])
        #expect(router.activeProvider?.name == "apple")
        #expect(router.activeProviderName == "apple")
    }

    @Test("prefers an earlier provider when both are available (WhisperKit over Apple)")
    func prefersPrimary() {
        let router = TranscriptionRouter(providers: [
            FakeTranscriber(name: "whisper", isAvailable: true),
            FakeTranscriber(name: "apple", isAvailable: true),
        ])
        #expect(router.activeProviderName == "whisper")
    }

    @Test("no available provider resolves to nil")
    func noneAvailable() {
        let router = TranscriptionRouter(providers: [
            FakeTranscriber(name: "whisper", isAvailable: false),
        ])
        #expect(router.activeProvider == nil)
        #expect(router.activeProviderName == nil)
    }

    // MARK: - Echo-cancellation preference (talking over music)

    @Test("asking for echo cancellation skips the sharper engine that can't do it")
    func prefersEchoCancellingProvider() {
        let router = TranscriptionRouter(providers: [
            FakeTranscriber(name: "whisper", isAvailable: true),
            FakeTranscriber(name: "apple", isAvailable: true, attemptsEchoCancellation: true),
        ])
        #expect(router.activeProvider(preferringEchoCancellation: true)?.name == "apple")
        // …and leaves the default path alone: accuracy still leads when the
        // caller hasn't asked for a clean duplex channel.
        #expect(router.activeProvider(preferringEchoCancellation: false)?.name == "whisper")
        #expect(router.activeProviderName == "whisper")
    }

    @Test("the preference is a preference — it never leaves you with no recogniser")
    func preferenceFallsBackRatherThanFailing() {
        // Nothing echo-cancelling is available: listening on the sharper engine
        // beats not listening at all. (An early cut of this returned nil and
        // would have made voice mode simply refuse to start.)
        let router = TranscriptionRouter(providers: [
            FakeTranscriber(name: "whisper", isAvailable: true),
        ])
        #expect(router.activeProvider(preferringEchoCancellation: true)?.name == "whisper")
    }

    @Test("an echo-cancelling provider that isn't available is not selected")
    func unavailableEchoProviderIsSkipped() {
        let router = TranscriptionRouter(providers: [
            FakeTranscriber(name: "whisper", isAvailable: true),
            FakeTranscriber(name: "apple", isAvailable: false, attemptsEchoCancellation: true),
        ])
        #expect(router.activeProvider(preferringEchoCancellation: true)?.name == "whisper")
    }
}

struct TranscriptAccumulatorTests {
    @Test("cumulative partials replace the working text")
    func cumulativePartials() {
        var acc = TranscriptAccumulator()
        acc.ingest(TranscriptSegment(text: "what", isFinal: false))
        acc.ingest(TranscriptSegment(text: "what is", isFinal: false))
        acc.ingest(TranscriptSegment(text: "what is in", isFinal: false))
        #expect(acc.text == "what is in")
        #expect(!acc.isFinal)
    }

    @Test("a final segment commits and flags done")
    func finalCommits() {
        var acc = TranscriptAccumulator()
        acc.ingest(TranscriptSegment(text: "what is in the doc", isFinal: true))
        #expect(acc.text == "what is in the doc")
        #expect(acc.isFinal)
    }

    @Test("empty segments never blank out captured text")
    func ignoresEmpty() {
        var acc = TranscriptAccumulator()
        acc.ingest(TranscriptSegment(text: "hello", isFinal: false))
        acc.ingest(TranscriptSegment(text: "", isFinal: false))
        #expect(acc.text == "hello")
    }

    @Test("a fresh accumulator has empty, non-final state")
    func startsEmpty() {
        let acc = TranscriptAccumulator()
        #expect(acc.text.isEmpty)
        #expect(!acc.isFinal)
        #expect(acc.confidence == nil)
    }

    @Test("confidence tracks the latest non-empty segment")
    func confidenceTracksLatest() {
        var acc = TranscriptAccumulator()
        acc.ingest(TranscriptSegment(text: "hello", isFinal: false, confidence: 0.4))
        #expect(acc.confidence == 0.4)
        acc.ingest(TranscriptSegment(text: "hello there", isFinal: false, confidence: 0.8))
        #expect(acc.confidence == 0.8)
    }

    @Test("an empty segment does not wipe captured confidence")
    func emptyKeepsConfidence() {
        var acc = TranscriptAccumulator()
        acc.ingest(TranscriptSegment(text: "hello", isFinal: false, confidence: 0.7))
        acc.ingest(TranscriptSegment(text: "", isFinal: false, confidence: nil))
        #expect(acc.text == "hello")
        #expect(acc.confidence == 0.7)
    }

    @Test("the final non-empty segment's confidence wins over an interim partial")
    func finalSegmentConfidenceWins() {
        // Latest non-empty wins — and the final segment is the latest — so the
        // sanitizer gates on the settled reading, not a meandering interim one.
        var acc = TranscriptAccumulator()
        acc.ingest(TranscriptSegment(text: "thank", isFinal: false, confidence: 0.9))
        acc.ingest(TranscriptSegment(text: "thank you", isFinal: true, confidence: 0.3))
        #expect(acc.confidence == 0.3)
    }
}
