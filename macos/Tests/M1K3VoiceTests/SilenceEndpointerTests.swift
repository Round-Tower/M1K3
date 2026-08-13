import Foundation
import M1K3Voice
import Testing

/// Pins the silence endpointer that closes the recognizer-finality gap: a
/// non-empty partial that stops changing for the threshold means the user is
/// done. Driven with synthetic instants — no real clock.
struct SilenceEndpointerTests {
    private let start = ContinuousClock.now

    @Test("no endpoint while the partial keeps growing")
    func growingPartialNeverEndpoints() {
        var endpointer = SilenceEndpointer(silence: .seconds(1.8))
        endpointer.ingest(partial: "hello", at: start)
        endpointer.ingest(partial: "hello there", at: start.advanced(by: .seconds(1.5)))
        endpointer.ingest(partial: "hello there pal", at: start.advanced(by: .seconds(3.0)))
        #expect(!endpointer.shouldEndpoint(at: start.advanced(by: .seconds(4.0))))
    }

    @Test("a stable non-empty partial endpoints after the threshold")
    func stablePartialEndpoints() {
        var endpointer = SilenceEndpointer(silence: .seconds(1.8))
        endpointer.ingest(partial: "hello there", at: start)
        #expect(!endpointer.shouldEndpoint(at: start.advanced(by: .seconds(1.0))))
        #expect(endpointer.shouldEndpoint(at: start.advanced(by: .seconds(1.8))))
        #expect(endpointer.shouldEndpoint(at: start.advanced(by: .seconds(5.0))))
    }

    @Test("re-ingesting the SAME text does not reset the silence clock")
    func unchangedTextKeepsClock() {
        var endpointer = SilenceEndpointer(silence: .seconds(1.8))
        endpointer.ingest(partial: "hello", at: start)
        // The recognizer re-emits identical cumulative text on its window hops.
        endpointer.ingest(partial: "hello", at: start.advanced(by: .seconds(1.0)))
        #expect(endpointer.shouldEndpoint(at: start.advanced(by: .seconds(1.9))))
    }

    @Test("empty text never endpoints, however long the silence")
    func emptyNeverEndpoints() {
        var endpointer = SilenceEndpointer(silence: .seconds(1.8))
        endpointer.ingest(partial: "", at: start)
        #expect(!endpointer.shouldEndpoint(at: start.advanced(by: .seconds(60))))
        // No ingest at all → also no endpoint.
        let untouched = SilenceEndpointer(silence: .seconds(1.8))
        #expect(!untouched.shouldEndpoint(at: start.advanced(by: .seconds(60))))
    }

    @Test("reset clears the clock for the next listen")
    func resetClears() {
        var endpointer = SilenceEndpointer(silence: .seconds(1.8))
        endpointer.ingest(partial: "hello", at: start)
        endpointer.reset()
        #expect(!endpointer.shouldEndpoint(at: start.advanced(by: .seconds(10))))
        endpointer.ingest(partial: "again", at: start.advanced(by: .seconds(10)))
        #expect(endpointer.shouldEndpoint(at: start.advanced(by: .seconds(11.9))))
    }

    // MARK: - Completeness-aware holding (anti-fragmentation)

    @Test("an incomplete partial waits the longer hold, not the normal silence")
    func incompletePartialHolds() {
        var endpointer = SilenceEndpointer(silence: .seconds(1.5), holdSilence: .seconds(3.0))
        // Trails off on "the" — a dangling article → keep listening past 1.5s.
        endpointer.ingest(partial: "tell me about the", at: start)
        #expect(!endpointer.shouldEndpoint(at: start.advanced(by: .seconds(1.5))))
        #expect(!endpointer.shouldEndpoint(at: start.advanced(by: .seconds(2.9))))
        #expect(endpointer.shouldEndpoint(at: start.advanced(by: .seconds(3.0))))
    }

    @Test("holdSilence == silence is the permitted boundary: incomplete partials get no extra hold")
    func equalThresholdsHoldNoLonger() {
        // The init precondition permits holdSilence >= silence; the equal boundary is
        // valid and collapses the two thresholds — an incomplete partial endpoints at
        // the same `silence` as a complete one (no inversion, just no extra hold).
        var endpointer = SilenceEndpointer(silence: .seconds(1.5), holdSilence: .seconds(1.5))
        // Fixture relies on the completeness classifier reading a trailing determiner
        // ("the") as incomplete — the whole point is that even an incomplete partial
        // gets no longer hold once the thresholds are equal.
        endpointer.ingest(partial: "tell me about the", at: start)
        #expect(!endpointer.shouldEndpoint(at: start.advanced(by: .seconds(1.4))))
        #expect(endpointer.shouldEndpoint(at: start.advanced(by: .seconds(1.5))))
    }

    @Test("a complete partial still endpoints at the normal silence threshold")
    func completePartialUsesNormalSilence() {
        var endpointer = SilenceEndpointer(silence: .seconds(1.5), holdSilence: .seconds(3.0))
        endpointer.ingest(partial: "what's the weather", at: start)
        #expect(endpointer.shouldEndpoint(at: start.advanced(by: .seconds(1.5))))
    }

    @Test("maxWait backstops a partial that never stabilises (anti-hang)")
    func maxWaitBackstop() {
        var endpointer = SilenceEndpointer(
            silence: .seconds(1.5), holdSilence: .seconds(3.0), maxWait: .seconds(20)
        )
        // A dangling partial that keeps changing every 2s never goes stable for
        // the 3s hold — without a cap it would never endpoint.
        var secs = 0.0
        var text = "so"
        while secs <= 18.0 {
            endpointer.ingest(partial: text, at: start.advanced(by: .seconds(secs)))
            text += " uh" // becomes incomplete once "uh" trails it; TEXT keeps changing each tick
            secs += 2.0
        }
        // Last change was at t=18; hold (3s) wouldn't fire until 21s, but maxWait
        // from first speech (t=0) caps it at 20s.
        #expect(!endpointer.shouldEndpoint(at: start.advanced(by: .seconds(19.0))))
        #expect(endpointer.shouldEndpoint(at: start.advanced(by: .seconds(20.0))))
    }

    @Test("maxWait overrides the longer hold on an incomplete partial")
    func maxWaitOverridesIncomplete() {
        var endpointer = SilenceEndpointer(
            silence: .seconds(1.0), holdSilence: .seconds(3.0), maxWait: .seconds(2.7)
        )
        endpointer.ingest(partial: "tell me about the", at: start) // incomplete → would hold 3.0s
        #expect(!endpointer.shouldEndpoint(at: start.advanced(by: .seconds(2.5))))
        // maxWait (2.7) fires before the 3.0 hold would.
        #expect(endpointer.shouldEndpoint(at: start.advanced(by: .seconds(2.7))))
    }

    @Test("maxWait does NOT cut a user still actively speaking past the cap")
    func maxWaitProtectsActiveSpeech() {
        var endpointer = SilenceEndpointer(
            silence: .seconds(1.5), holdSilence: .seconds(3.0), maxWait: .seconds(20)
        )
        // A long, genuine utterance whose partials keep advancing right up to the
        // cap — the recognizer is NOT stuck, so maxWait must not cut it mid-word.
        var secs = 0.0
        var text = "word0"
        var idx = 0
        while secs <= 19.9 {
            endpointer.ingest(partial: text, at: start.advanced(by: .seconds(secs)))
            idx += 1
            text += " word\(idx)" // changes each tick, stays a complete-looking clause
            secs += 0.5
        }
        // At t=20 the cap has elapsed but the last change was ~0.1s ago (idle <
        // silence) → still speaking → no endpoint.
        #expect(!endpointer.shouldEndpoint(at: start.advanced(by: .seconds(20.0))))
    }

    @Test("a partial that becomes complete mid-hold switches to the shorter threshold")
    func transitionToCompleteUsesShorterThreshold() {
        // cadenceCeiling .zero disables cadence adaptation, isolating the
        // completeness transition this test is about (with adaptation live, the
        // 2s pause below would itself raise the floor — pinned separately in
        // recoveredPauseRaisesTheFloor).
        var endpointer = SilenceEndpointer(
            silence: .seconds(1.5), holdSilence: .seconds(3.0), cadenceCeiling: .zero
        )
        endpointer.ingest(partial: "tell me about the", at: start) // incomplete → would hold 3.0s
        // User completes the thought 2s in:
        endpointer.ingest(partial: "tell me about the weather", at: start.advanced(by: .seconds(2.0)))
        #expect(!endpointer.shouldEndpoint(at: start.advanced(by: .seconds(3.4)))) // idle 1.4 < 1.5
        #expect(endpointer.shouldEndpoint(at: start.advanced(by: .seconds(3.5)))) // idle 1.5 ≥ silence
    }

    // MARK: - Cadence adaptation (learning how long THIS speaker pauses)

    @Test("a pause the speaker recovers from raises the floor for the rest of the session")
    func recoveredPauseRaisesTheFloor() {
        var endpointer = SilenceEndpointer(
            silence: .seconds(2.0), holdSilence: .seconds(4.5), cadenceMargin: .seconds(0.75)
        )
        // Kev's cadence: a dangling connective, a long pause, then he carries on.
        endpointer.ingest(partial: "I got some issues and", at: start)
        endpointer.ingest(partial: "I got some issues and the voice mode", at: start.advanced(by: .seconds(3.5)))
        // The tail now READS complete, so the bare threshold would turn over at
        // 2.0s — but this speaker has just demonstrated a 3.5s intra-thought
        // pause, so the floor is 3.5 + 0.75.
        #expect(!endpointer.shouldEndpoint(at: start.advanced(by: .seconds(3.5 + 2.0))))
        #expect(!endpointer.shouldEndpoint(at: start.advanced(by: .seconds(3.5 + 4.0))))
        #expect(endpointer.shouldEndpoint(at: start.advanced(by: .seconds(3.5 + 4.25))))
    }

    @Test("the learned cadence survives reset — it is the speaker's, not the utterance's")
    func cadenceSurvivesReset() {
        var endpointer = SilenceEndpointer(
            silence: .seconds(2.0), holdSilence: .seconds(4.5), cadenceMargin: .seconds(0.75)
        )
        endpointer.ingest(partial: "so the thing is and", at: start)
        endpointer.ingest(partial: "so the thing is and it broke", at: start.advanced(by: .seconds(3.0)))
        #expect(endpointer.observedPause == .seconds(3.0))
        endpointer.reset() // next listen in the same voice-mode session
        endpointer.ingest(partial: "what about Tuesday", at: start.advanced(by: .seconds(30)))
        // Learned 3.0 + 0.75 still governs, so the next turn isn't clipped either.
        #expect(!endpointer.shouldEndpoint(at: start.advanced(by: .seconds(32.0))))
        #expect(endpointer.shouldEndpoint(at: start.advanced(by: .seconds(33.75))))
    }

    @Test("the learned floor is capped, so one huge gap can't stall the loop")
    func cadenceIsCapped() {
        var endpointer = SilenceEndpointer(
            silence: .seconds(2.0), holdSilence: .seconds(4.5),
            maxWait: .seconds(120), cadenceMargin: .seconds(0.75), cadenceCeiling: .seconds(6.0)
        )
        endpointer.ingest(partial: "hold on and", at: start)
        endpointer.ingest(partial: "hold on and here it is", at: start.advanced(by: .seconds(45)))
        #expect(endpointer.observedPause == .seconds(6.0)) // clamped on the way in
        #expect(endpointer.shouldEndpoint(at: start.advanced(by: .seconds(45 + 6.0))))
    }

    @Test("mic-open latency before the first word is NOT a speaker pause")
    func silenceBeforeFirstSpeechIsNotLearned() {
        var endpointer = SilenceEndpointer(
            silence: .seconds(2.0), holdSilence: .seconds(4.5), cadenceMargin: .seconds(0.75)
        )
        // WhisperKit emits an empty/placeholder partial, then the first words
        // seconds later. That gap is the recognizer warming up, not Kev thinking.
        endpointer.ingest(partial: "", at: start)
        endpointer.ingest(partial: "what's the weather", at: start.advanced(by: .seconds(4.0)))
        #expect(endpointer.observedPause == .zero)
        #expect(endpointer.shouldEndpoint(at: start.advanced(by: .seconds(6.0)))) // idle 2.0 = silence
    }

    @Test("a gap shorter than the endpoint threshold teaches nothing")
    func shortGapsTeachNothing() {
        var endpointer = SilenceEndpointer(
            silence: .seconds(2.0), holdSilence: .seconds(4.5), cadenceMargin: .seconds(0.75)
        )
        // Ordinary word-by-word partial growth must not inflate the floor, or
        // every speaker would drift toward the ceiling.
        endpointer.ingest(partial: "what", at: start)
        endpointer.ingest(partial: "what's the", at: start.advanced(by: .seconds(0.6)))
        endpointer.ingest(partial: "what's the weather", at: start.advanced(by: .seconds(1.4)))
        #expect(endpointer.observedPause == .zero)
        #expect(endpointer.shouldEndpoint(at: start.advanced(by: .seconds(3.4)))) // idle 2.0
    }

    @Test("a fresh endpointer starts with no speaker model — the session boundary")
    func freshEndpointerForgetsTheSpeaker() {
        // The voice loop builds one endpointer per voice-mode entry, which is what
        // scopes the learning to a session. Pinned so that stays true by
        // construction rather than by comment.
        var learned = SilenceEndpointer(silence: .seconds(2.0), holdSilence: .seconds(4.5))
        learned.ingest(partial: "the thing and", at: start)
        learned.ingest(partial: "the thing and more", at: start.advanced(by: .seconds(3.0)))
        #expect(learned.observedPause == .seconds(3.0))

        var next = SilenceEndpointer(silence: .seconds(2.0), holdSilence: .seconds(4.5))
        #expect(next.observedPause == .zero)
        next.ingest(partial: "quick question", at: start)
        #expect(next.shouldEndpoint(at: start.advanced(by: .seconds(2.0))))
    }

    // MARK: - The polite fast-path ("please" is the spoken submit button)

    @Test("a trailing please endpoints on the short polite window, not the silence threshold")
    func trailingPleaseAcceleratesEndpoint() {
        var endpointer = SilenceEndpointer(
            silence: .seconds(2.5), holdSilence: .seconds(5.0), politeSilence: .seconds(1.0)
        )
        endpointer.ingest(partial: "tell me a story please", at: start)
        #expect(!endpointer.shouldEndpoint(at: start.advanced(by: .seconds(0.5))))
        #expect(endpointer.shouldEndpoint(at: start.advanced(by: .seconds(1.0))))
    }

    @Test("please bypasses the learned cadence floor — the word IS the submit")
    func pleaseBypassesLearnedFloor() {
        var endpointer = SilenceEndpointer(
            silence: .seconds(2.0), holdSilence: .seconds(4.5),
            cadenceMargin: .seconds(0.75), cadenceCeiling: .seconds(6.0),
            politeSilence: .seconds(1.0)
        )
        // Teach a 4s rhythm: without please, later waits would be ~4.75s.
        endpointer.ingest(partial: "the thing and", at: start)
        endpointer.ingest(partial: "the thing and also please", at: start.advanced(by: .seconds(4.0)))
        #expect(endpointer.observedPause == .seconds(4.0))
        #expect(endpointer.shouldEndpoint(at: start.advanced(by: .seconds(5.0)))) // idle 1.0
    }

    @Test("please overrides the incomplete-partial hold")
    func pleaseOverridesHold() {
        var endpointer = SilenceEndpointer(
            silence: .seconds(2.5), holdSilence: .seconds(5.0), politeSilence: .seconds(1.0)
        )
        // "can you please" trails on the submit word itself — the documented
        // contract: say please, M1K3 takes its turn.
        endpointer.ingest(partial: "can you please", at: start)
        #expect(endpointer.shouldEndpoint(at: start.advanced(by: .seconds(1.0))))
    }

    @Test("a mid-sentence please changes nothing")
    func midSentencePleaseKeepsNormalCadence() {
        var endpointer = SilenceEndpointer(
            silence: .seconds(2.5), holdSilence: .seconds(5.0), politeSilence: .seconds(1.0)
        )
        endpointer.ingest(partial: "please tell me about the", at: start)
        // Trails on "the" (dangling) → the HOLD applies, untouched by the fast-path.
        #expect(!endpointer.shouldEndpoint(at: start.advanced(by: .seconds(2.6))))
        #expect(endpointer.shouldEndpoint(at: start.advanced(by: .seconds(5.0))))
    }
}
