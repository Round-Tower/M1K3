//
//  EndpointCadenceTests.swift
//  M1K3VoiceTests
//
//  Pins the ORDERING invariants of the shared endpointing preset, not taste. The
//  durations are Kev's ear and will move again; what must never move is their
//  relationship — SilenceEndpointer's own precondition trips on hold < silence,
//  and a ceiling below the hold would silently shorten a configured hold instead
//  of extending it.
//
//  Signed: Kev + claude-opus-5, 2026-08-11, Confidence 0.9 (pure). Prior: Unknown.
//

import Foundation
import M1K3Voice
import Testing

struct EndpointCadenceTests {
    private let cadence = EndpointCadence.conversational

    @Test("the hold is never shorter than the base silence")
    func holdExtendsSilence() {
        // SilenceEndpointer's init preconditions on this — a violation is a crash
        // on entering voice mode, on both shells at once.
        #expect(cadence.hold >= cadence.silence)
    }

    @Test("the cadence ceiling is at least the hold, so learning can only add patience")
    func ceilingNeverShortensTheHold() {
        // `needed = max(base, min(learned + margin, ceiling))` — a ceiling under
        // the hold can't shorten `base`, but it WOULD cap the learned floor below
        // a threshold we already committed to, making adaptation a no-op for
        // trailed-off speech. The invariant keeps the two knobs coherent.
        #expect(cadence.cadenceCeiling >= cadence.hold)
    }

    @Test("the anti-hang cap is well clear of the longest patient wait")
    func maxWaitOutlastsPatience() {
        // maxWait fires from FIRST speech while the others measure idle time; if
        // it sat near the ceiling it would pre-empt the patience it's meant to
        // backstop, clipping exactly the long deliberate turns this preset serves.
        #expect(cadence.maxWait > cadence.cadenceCeiling)
    }

    @Test("patience is bounded — every value here is felt latency after you stop talking")
    func patienceStaysWithinHumanTolerance() {
        // Not taste: an unbounded preset is how a voice loop starts feeling dead.
        #expect(cadence.cadenceCeiling <= .seconds(8))
        #expect(cadence.silence >= .seconds(1))
    }
}
