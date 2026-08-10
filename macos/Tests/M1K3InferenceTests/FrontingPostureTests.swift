//
//  FrontingPostureTests.swift
//  M1K3InferenceTests
//
//  Who answers an interactive turn. Mini fronts ONLY while the MLX slot can't
//  serve — mid-download or mid-dive.
//
//  ★ These tests used to cover a steady-state "Mini fronts by default" opt-in.
//  It was built, measured, and removed the same night. Same build, same 8
//  open-chat fixtures, same live path:
//
//      lil    median 10,022 ms   max  18,132 ms
//      big    median 30,500 ms   max 289,020 ms
//      mini   median 37,292 ms   max 183,853 ms
//
//  Mini is the SLOWEST tier by 3.7x, not the quick one — AFM re-sends the whole
//  persona on a fresh session every call while the MLX tiers reuse a cached KV
//  prefix. The opt-in could only ever have made M1K3 slower, so it is gone
//  rather than sitting disabled waiting for someone to find it.
//
//  Signed: Kev + claude-opus-5, 2026-08-10, Confidence 0.9 (the ordering is
//  measured on one build with n=8 per tier; the RATIO is same-binary and the
//  gap is far too large to be noise, though absolute figures are Debug-inflated).
//  Prior: Kev + claude-opus-5 (the retired steady-state version).
//

@testable import M1K3Inference
import Testing

struct FrontingPostureTests {
    @Test("the resident brain answers when it can")
    func residentAnswersWhenReady() {
        #expect(InterimBrainPolicy.posture(gate: .open, delegationInFlight: false) == .selectedBrain)
    }

    @Test("Mini fronts while the brain is still downloading")
    func miniFrontsDuringDownload() {
        // Nothing else can serve here, so Mini being the slowest tier is beside
        // the point — something beats nothing.
        #expect(InterimBrainPolicy.posture(gate: .interim, delegationInFlight: false) == .miniFronts)
    }

    @Test("Mini fronts while a dive holds the slot")
    func miniFrontsDuringDive() {
        // Refusing here would queue the conversation behind the dive, breaking
        // the exact promise delegate_deep makes.
        #expect(InterimBrainPolicy.posture(gate: .open, delegationInFlight: true) == .miniFronts)
    }

    @Test("a blocked gate never fronts — it has recovery affordances to show")
    func blockedNeverFronts() {
        #expect(InterimBrainPolicy.posture(gate: .blocked, delegationInFlight: false) == .selectedBrain)
        #expect(InterimBrainPolicy.posture(gate: .blocked, delegationInFlight: true) == .selectedBrain)
    }

    @Test("★ there is no steady-state Mini front, and that is deliberate")
    func noSteadyStateFronting() {
        // The regression guard for the falsified premise. If someone reintroduces
        // "Mini fronts when everything is ready", this fails and sends them to the
        // header's numbers first.
        #expect(InterimBrainPolicy.posture(gate: .open, delegationInFlight: false) != .miniFronts)
    }

    @Test("only the fronting posture asks the app to override the runtime")
    func overrideMapping() {
        #expect(FrontingPosture.miniFronts.frontsOnMini)
        #expect(!FrontingPosture.selectedBrain.frontsOnMini)
    }
}
