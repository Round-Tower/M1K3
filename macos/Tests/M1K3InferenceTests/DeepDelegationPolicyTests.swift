//
//  DeepDelegationPolicyTests.swift
//  M1K3InferenceTests
//
//  Eligibility rules for delegate_deep — Kev's 07-25 ask ("Lil could delegate
//  a long-form task and notify when it's back, so everything stays quick").
//  The challenger-hardened shape: the delegated task runs on the ONE resident
//  MLX slot while Mini (AFM — a separate, non-MLX runtime) fronts the
//  conversation. Concurrent MLX×MLX generation is forbidden by design (the
//  process-global memory budget makes two decode loops stall each other), so
//  eligibility requires BOTH lanes: a ready MLX brain to dig, and an
//  available AFM to keep the conversation quick.
//
//  Signed: Kev + claude-fable-5, 2026-07-25, Confidence 0.9, Prior: Unknown
//

@testable import M1K3Inference
import Testing

struct DeepDelegationPolicyTests {
    @Test("MLX brain ready + AFM available = eligible")
    func happyPath() {
        #expect(DeepDelegationPolicy.eligibility(
            selectedRequiresWeights: true, load: .ready, afm: .available
        ) == .eligible)
    }

    @Test("Mini selected means there is no deep brain to hand work to")
    func miniSelectedHasNoDeepBrain() {
        #expect(DeepDelegationPolicy.eligibility(
            selectedRequiresWeights: false, load: .idle, afm: .available
        ) == .noDeepBrain)
    }

    @Test("a still-downloading deep brain is not ready to dig")
    func downloadingBlocks() {
        #expect(DeepDelegationPolicy.eligibility(
            selectedRequiresWeights: true, load: .downloading(fraction: 0.4), afm: .available
        ) == .deepBrainNotReady)
        #expect(DeepDelegationPolicy.eligibility(
            selectedRequiresWeights: true, load: .preparing, afm: .available
        ) == .deepBrainNotReady)
        #expect(DeepDelegationPolicy.eligibility(
            selectedRequiresWeights: true, load: .failed(message: "boom"), afm: .available
        ) == .deepBrainNotReady)
    }

    @Test("no AFM to front the conversation = ineligible, whatever the reason")
    func noFrontBrainBlocks() {
        // Without Mini, interactive turns would queue BEHIND the delegation on
        // the same model container — the exact 'everything stays quick' promise
        // broken. Refuse honestly instead.
        #expect(DeepDelegationPolicy.eligibility(
            selectedRequiresWeights: true, load: .ready, afm: .notReady
        ) == .noFrontBrain)
        #expect(DeepDelegationPolicy.eligibility(
            selectedRequiresWeights: true, load: .ready, afm: .blocked(userFixable: true)
        ) == .noFrontBrain)
    }

    @Test("each outcome carries model-facing copy; only eligible has none")
    func observationCopy() {
        #expect(DeepDelegationPolicy.Eligibility.eligible.refusalObservation == nil)
        for blocked: DeepDelegationPolicy.Eligibility in [.noDeepBrain, .deepBrainNotReady, .noFrontBrain] {
            let copy = blocked.refusalObservation
            #expect(copy != nil)
            #expect(copy?.hasPrefix("Error:") == true) // the tool-observation error contract
        }
    }
}
