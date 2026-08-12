import AVFoundation
import Foundation
@testable import M1K3Voice
import Testing

/// Integration smoke for the streaming playback path — the real
/// AVSpeechSynthesizer offline render through the real AVAudioEngine, word
/// clock and all. This is the closest `swift test` gets to ⌘R for the speech
/// machinery, and it pins the lifecycle regression class from PR #10: exactly
/// one started/ended pair per utterance.
///
/// **Opt-in** (`M1K3_AUDIO_INTEGRATION=1`), joining the heavy MLX/WhisperKit
/// tests behind an env gate, for two reasons found on 2026-08-12:
///
/// - It SPEAKS, out of the speakers of whoever runs it, on every `swift test`.
///   Kev heard these for weeks and reasonably read the audio as M1K3's own voice
///   misbehaving. It is the system voice: M1K3's real one is Kokoro, which is
///   MLX/Metal and cannot run here at all (the metallib wall).
/// - The word clock is a REAL-TIME delegate correlation. Sharing a machine with
///   ~2,500 other tests, the offline render delivered 0-4 of ≥8 word onsets and
///   the suite went red with nothing wrong in the code under test. Serializing
///   the suite raised the floor but did not fix it — the contention is the rest
///   of the run, not the sibling test.
///
/// Run it deliberately when touching speech:
/// `M1K3_AUDIO_INTEGRATION=1 swift test --filter EffectfulStreamingIntegrationTests`
///
/// The lifecycle and stop-ordering invariants that DON'T need a speaker live in
/// `SpeechEntryGateTests` and run every time.
///
/// `.serialized` even so: both tests drive a real AVSpeechSynthesizer and the one
/// audio output, and run together they talk OVER each other — two voices at once,
/// which is how the stop bug came to be misattributed by ear in the first place.
@MainActor
@Suite(.serialized)
struct EffectfulStreamingIntegrationTests {
    /// Opt-in: audible, real-time, and machine-load sensitive (see the suite doc).
    /// CI never sets it, which also keeps the old "runners may have no output
    /// device" guarantee without depending on the CI variable.
    private var audioEnabled: Bool {
        ProcessInfo.processInfo.environment["M1K3_AUDIO_INTEGRATION"] == "1"
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _starts = 0
        private var _ends = 0
        private var _timelines: [SpokenWordTimeline] = []
        private var _words: [Range<Int>] = []

        var starts: Int {
            lock.withLock { _starts }
        }

        var ends: Int {
            lock.withLock { _ends }
        }

        var timelines: [SpokenWordTimeline] {
            lock.withLock { _timelines }
        }

        var words: [Range<Int>] {
            lock.withLock { _words }
        }

        func wire(_ provider: EffectfulSpeechProvider) {
            provider.onSpeakingStarted = { [self] in lock.withLock { _starts += 1 } }
            provider.onSpeakingEnded = { [self] in lock.withLock { _ends += 1 } }
            provider.onTimelineReady = { [self] timeline in lock.withLock { _timelines.append(timeline) } }
            provider.onWordSpoken = { [self] range in lock.withLock { _words.append(range) } }
        }
    }

    @Test("a spoken utterance fires one lifecycle pair, a timeline, and advancing words")
    func appleStreamingPath() async throws {
        guard audioEnabled else { return }
        let provider = EffectfulSpeechProvider()
        let recorder = Recorder()
        recorder.wire(provider)

        let text = "The rain in Spain falls mainly on the plain."
        await provider.speak(SpeechUtterance(text: text))

        #expect(recorder.starts == 1)
        #expect(recorder.ends == 1)
        // The offline render correlates delegate onsets — a full timeline exists.
        let timeline = try #require(recorder.timelines.last)
        #expect(timeline.text == text)
        #expect(timeline.words.count >= 8)
        #expect(timeline.totalDuration > 1)
        // The word clock fired across the utterance with advancing ranges.
        #expect(recorder.words.count >= 4)
        #expect(recorder.words == recorder.words.sorted { $0.lowerBound < $1.lowerBound })
        let isSpeaking = await provider.isSpeaking()
        #expect(!isSpeaking) // a drained player must not read as still speaking

        // A SECOND utterance must get a fresh clock (regression: the stale
        // player position once anchored utterance 2's words seconds late) and
        // must not fire a spurious ended event on entry.
        let wordsBefore = recorder.words.count
        await provider.speak(SpeechUtterance(text: "Second time around."))
        #expect(recorder.starts == 2)
        #expect(recorder.ends == 2)
        #expect(recorder.words.count > wordsBefore)
        if recorder.words.count > wordsBefore {
            #expect(recorder.words[wordsBefore].lowerBound == 0) // fresh utterance, first word
        }
    }

    @Test("stop() mid-utterance ends exactly once and returns promptly")
    func stopMidUtterance() async throws {
        guard audioEnabled else { return }
        let provider = EffectfulSpeechProvider()
        let recorder = Recorder()
        recorder.wire(provider)

        let speakTask = Task {
            await provider.speak(SpeechUtterance(
                text: "This is a deliberately long sentence that will be interrupted before it can possibly finish speaking."
            ))
        }
        // Let synthesis + playback begin, then cut it off.
        try await Task.sleep(for: .milliseconds(900))
        let cutOff = ContinuousClock.now
        await provider.stop()
        await speakTask.value
        let unwind = ContinuousClock.now - cutOff

        #expect(recorder.ends == 1) // never zero (hang) and never two (PR #10 regression)
        let isSpeaking = await provider.isSpeaking()
        #expect(!isSpeaking)
        // "Returns promptly" was in this test's NAME and in none of its assertions
        // (Kev, 2026-08-12: "the test that stops midway seems to fail because it
        // goes right to the end"). The sentence takes ~6s to speak; a stop that let
        // playback run to completion satisfied every check above, because they only
        // ever asked about bookkeeping. Now the audible claim is the assertion.
        #expect(unwind < .seconds(1), "stop() unwound in \(unwind) — the audio kept playing")
    }
}
