//
//  FrontTierRealignmentTests.swift
//  M1K3InferenceTests
//
//  Pins the ONE-TIME realignment of a persisted brain pick that is heavier than
//  what the ladder now recommends.
//
//  It exists because #117 changed `BrainTier.recommended` (Lil fronts every Mac,
//  measured 3x faster than Big) and that fixed NOTHING for anyone already running
//  — a recommendation only applies to a pick nobody has made yet. Kev's own 64GB
//  Mac stayed resident on Big and he reported voice-first as slow the next day.
//
//  The dangerous version of this feature is the one that keeps re-applying, or
//  that lives in `BrainTier(persisted:)` where it would make Big permanently
//  unselectable. Both are pinned against below.
//
//  Signed: Kev + claude-opus-5, 2026-08-11, Confidence 0.9 (pure, red-first).
//  Prior: Unknown.
//

import M1K3Inference
import Testing

struct FrontTierRealignmentTests {
    @Test("a persisted Big realigns to the lighter recommended front, once")
    func bigRealignsToRecommended() {
        let outcome = FrontTierRealignment.plan(
            persisted: .big, alreadyRealigned: false, recommended: .lil
        )
        #expect(outcome?.tier == .lil)
        // The notice has to explain that Big is still reachable, or this reads as
        // a downgrade someone has to go hunting to undo.
        #expect(outcome?.notice.isEmpty == false)
    }

    @Test("it never fires twice — one nudge, then the pick is the user's again")
    func realignsOnlyOnce() {
        #expect(FrontTierRealignment.plan(
            persisted: .big, alreadyRealigned: true, recommended: .lil
        ) == nil)
    }

    @Test("a pick at or below the recommendation is left alone")
    func lighterPicksUntouched() {
        #expect(FrontTierRealignment.plan(
            persisted: .lil, alreadyRealigned: false, recommended: .lil
        ) == nil)
        // Mini is a deliberate choice on a small machine — never "upgrade" someone
        // into a multi-gigabyte download they didn't ask for.
        #expect(FrontTierRealignment.plan(
            persisted: .mini, alreadyRealigned: false, recommended: .lil
        ) == nil)
    }

    @Test("no stored pick means nothing to realign — `recommended` already covers it")
    func noPersistedPick() {
        #expect(FrontTierRealignment.plan(
            persisted: nil, alreadyRealigned: false, recommended: .lil
        ) == nil)
    }

    @Test("a machine where the heavy tier IS still recommended keeps it")
    func recommendationStillHeavy() {
        // Guards against the realignment being read as "Big is bad". It only ever
        // follows the ladder; if the ladder says Big here, Big stays.
        #expect(FrontTierRealignment.plan(
            persisted: .big, alreadyRealigned: false, recommended: .big
        ) == nil)
    }

    @Test("BrainTier(persisted:) still decodes big as big — the realignment is NOT a decode rule")
    func decodeIsUnchanged() {
        // If this ever fails, someone moved the migration into the decoder and
        // made the deep tier unselectable for everyone, forever.
        #expect(BrainTier(persisted: "big") == .big)
    }
}
