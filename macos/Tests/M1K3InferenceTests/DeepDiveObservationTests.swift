//
//  DeepDiveObservationTests.swift
//  M1K3InferenceTests
//
//  Signed: Kev + claude-fable-5, 2026-08-15, Confidence 0.9 (pure string
//  contracts, pinned both shapes). Prior: Unknown.
//

import Foundation
import M1K3Inference
import Testing

/// Pins the model-facing observation for a started deep dive. The copy is the
/// model's ONLY window into what the delegation actually did — whether the dive
/// escalated to Big or stayed on the resident brain — and the 2026-08-03 lesson
/// (three identity bugs from per-turn prose) says strings the model reads get
/// pinned, not eyeballed.
struct DeepDiveObservationTests {
    @Test("an escalated dive names the deeper brain and says it escalated")
    func escalatedNamesTheDeeperBrain() {
        let plan = DeepDivePlan(tier: .big, requiresSwap: true, isEscalation: true)
        let observation = DeepDiveObservation.delegated(plan: plan)
        #expect(observation.contains(BrainTier.big.displayName))
        #expect(observation.lowercased().contains("escalat"))
        // The trade is still the trade: Mini fronts while the slot digs.
        #expect(observation.contains("Mini"))
    }

    @Test("a same-brain dive is honest: background lane, no escalation claim")
    func sameBrainDiveClaimsNoEscalation() {
        let plan = DeepDivePlan(tier: .lil, requiresSwap: false, isEscalation: false)
        let observation = DeepDiveObservation.delegated(plan: plan)
        #expect(observation.contains(BrainTier.lil.displayName))
        #expect(!observation.lowercased().contains("escalat"))
        #expect(observation.contains("Mini"))
    }

    @Test("both shapes promise the delivery contract — the result lands in this chat")
    func bothShapesPromiseDelivery() {
        for plan in [
            DeepDivePlan(tier: .big, requiresSwap: true, isEscalation: true),
            DeepDivePlan(tier: .lil, requiresSwap: false, isEscalation: false),
        ] {
            let observation = DeepDiveObservation.delegated(plan: plan)
            #expect(observation.lowercased().contains("background"))
            #expect(observation.lowercased().contains("this chat"))
        }
    }
}
