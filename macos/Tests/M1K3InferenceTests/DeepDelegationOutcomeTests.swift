//
//  DeepDelegationOutcomeTests.swift
//  M1K3InferenceTests
//
//  The escalation instrument. Before this type, `startDeepDelegation` logged a
//  `.notice` only when a dive STARTED — so eight days of unified log showing
//  zero `delegate_deep` entries could mean either "the model never called the
//  tool" or "the app refused every call", and those two demand opposite fixes
//  (a prompting problem vs a plumbing problem).
//
//  What's pinned here is the property that makes the log answer that question:
//  EVERY invocation yields exactly one line, all lines share the greppable
//  `delegate_deep ` prefix, and every decline names a distinct machine-readable
//  reason. Absence of a line can then only mean the tool was never invoked.
//
//  Signed: Kev + claude-opus-5, 2026-08-09, Confidence 0.9, Prior: Unknown
//

@testable import M1K3Inference
import Testing

struct DeepDelegationOutcomeTests {
    typealias Outcome = DeepDelegationOutcome
    typealias Reason = DeepDelegationOutcome.DeclineReason

    @Test("a started dive names the brain it went to")
    func startedLine() {
        #expect(Outcome.started(brain: "Big M1K3").logLine == "delegate_deep started on Big M1K3")
    }

    @Test("every decline reason renders a distinct, machine-readable line")
    func declineLines() {
        var seen = Set<String>()
        for reason in Reason.allCases {
            let line = Outcome.declined(reason: reason).logLine
            #expect(line == "delegate_deep declined: \(reason.rawValue)")
            #expect(seen.insert(line).inserted, "decline lines must be distinguishable: \(line)")
        }
    }

    @Test("every outcome shares the greppable prefix — absence means never invoked")
    func greppablePrefix() {
        // This is the whole point of the instrument: one `rg 'delegate_deep '`
        // over the unified log must catch EVERY invocation, so an empty result
        // is evidence of "never called" rather than "silently refused".
        var lines = Reason.allCases.map { Outcome.declined(reason: $0).logLine }
        lines.append(Outcome.started(brain: "Lil M1K3").logLine)
        for line in lines {
            #expect(line.hasPrefix("delegate_deep "))
        }
    }

    @Test("a started dive is never mistaken for a decline")
    func startedIsNotADecline() {
        #expect(!Outcome.started(brain: "Lil M1K3").logLine.contains("declined"))
    }

    // MARK: - The Eligibility bridge

    @Test("every ineligible verdict maps to a decline reason; eligible maps to none")
    func eligibilityBridgeIsTotal() {
        #expect(DeepDelegationPolicy.Eligibility.eligible.declineReason == nil)
        // Exhaustive over the refusal cases: a NEW Eligibility case added without
        // a slug leaves it unlogged, which is exactly the blind spot this closes.
        let refusals: [DeepDelegationPolicy.Eligibility] = [
            .noDeepBrain, .deepBrainNotReady, .noFrontBrain,
        ]
        for refusal in refusals {
            #expect(refusal.declineReason != nil, "\(refusal) would log nothing")
        }
        #expect(DeepDelegationPolicy.Eligibility.noDeepBrain.declineReason == .noDeepBrain)
        #expect(DeepDelegationPolicy.Eligibility.deepBrainNotReady.declineReason == .deepBrainNotReady)
        #expect(DeepDelegationPolicy.Eligibility.noFrontBrain.declineReason == .noFrontBrain)
    }

    @Test("an ineligible verdict carries BOTH model-facing copy and a log reason")
    func refusalsAreBothSpokenAndLogged() {
        // The two audiences must stay in lockstep: the model gets
        // `refusalObservation`, the log gets `declineReason`. A refusal that has
        // one but not the other is either invisible to us or mute to the model.
        let refusals: [DeepDelegationPolicy.Eligibility] = [
            .noDeepBrain, .deepBrainNotReady, .noFrontBrain,
        ]
        for refusal in refusals {
            #expect((refusal.refusalObservation == nil) == (refusal.declineReason == nil))
        }
        #expect(DeepDelegationPolicy.Eligibility.eligible.refusalObservation == nil)
        #expect(DeepDelegationPolicy.Eligibility.eligible.declineReason == nil)
    }
}
