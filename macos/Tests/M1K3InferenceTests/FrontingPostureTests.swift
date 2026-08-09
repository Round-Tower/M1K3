//
//  FrontingPostureTests.swift
//  M1K3InferenceTests
//
//  "Quick by default, deep when complex" — Kev's standing vision — as a policy
//  rather than an aspiration. Mini (Apple Foundation Models) fronts the
//  conversation; the one MLX slot is reserved for depth.
//
//  Today Mini only fronts in TRANSIENT states: while a weight-backed brain
//  downloads (`ChatGate.interim`) or while a `delegate_deep` dive holds the
//  slot. This adds the STEADY-STATE posture — and, more importantly, encodes
//  the constraint that makes it safe.
//
//  ★ The constraint: fronting by default is only sound while a route to the
//  deep brain actually exists. Mini fronting at `.ready` means the MLX brain
//  answers nothing interactively, so the ONLY remaining route is
//  `delegate_deep` — which has never been invoked once in 8 days of logs. Turn
//  this on without a working depth trigger and the deep tier quietly ceases to
//  exist, which is precisely the arm Kev rejected ("deletes the deep tier"),
//  arriving through the other arm's door. So `depthReachable` is a REQUIRED
//  input, not a comment: the type system makes you answer the question.
//
//  Signed: Kev + claude-opus-5, 2026-08-09, Confidence 0.85 (the policy is pure
//  and pinned; whether Mini is GOOD ENOUGH to front is an on-device question
//  that is still unanswered — which is why the opt-in defaults OFF).
//  Prior: Unknown.
//

@testable import M1K3Inference
import Testing

struct FrontingPostureTests {
    /// Today's behaviour: the transient bridges, with the opt-in off.
    private func today(gate: ChatGate, delegating: Bool = false) -> FrontingPosture {
        InterimBrainPolicy.posture(
            gate: gate, delegationInFlight: delegating,
            preferMiniFront: false, depthReachable: true
        )
    }

    @Test("with the opt-in OFF, behaviour is exactly what shipped before")
    func optInOffIsUnchanged() {
        #expect(today(gate: .open) == .selectedBrain)
        #expect(today(gate: .interim) == .miniFronts)
        #expect(today(gate: .blocked) == .selectedBrain)
        #expect(today(gate: .open, delegating: true) == .miniFronts)
    }

    @Test("★ the opt-in is REFUSED when no route to the deep brain exists")
    func frontingRequiresAReachableDepthPath() {
        // The whole safety property. Mini fronting at `.ready` means the MLX
        // brain answers nothing interactively; if delegate_deep can't or won't
        // fire, the deep tier is gone. Silently becoming a Mini-only product is
        // a worse outcome than not honouring the preference.
        #expect(InterimBrainPolicy.posture(
            gate: .open, delegationInFlight: false,
            preferMiniFront: true, depthReachable: false
        ) == .selectedBrain)
    }

    @Test("with the opt-in ON and depth reachable, Mini fronts the steady state")
    func steadyStateFronting() {
        #expect(InterimBrainPolicy.posture(
            gate: .open, delegationInFlight: false,
            preferMiniFront: true, depthReachable: true
        ) == .miniFronts)
    }

    @Test("the transient bridges never depend on the opt-in or on depth")
    func transientBridgesAreUnconditional() {
        // While the brain is downloading there IS no deep tier to protect — the
        // whole point of the interim bridge is that nothing else can serve. The
        // depth guard must not accidentally re-gate the download experience.
        for reachable in [true, false] {
            #expect(InterimBrainPolicy.posture(
                gate: .interim, delegationInFlight: false,
                preferMiniFront: false, depthReachable: reachable
            ) == .miniFronts)
            // Likewise mid-dive: the slot is already busy, Mini is the only
            // thing that can answer, and refusing to front would queue the
            // conversation behind the dive — the exact promise delegate_deep makes.
            #expect(InterimBrainPolicy.posture(
                gate: .open, delegationInFlight: true,
                preferMiniFront: false, depthReachable: reachable
            ) == .miniFronts)
        }
    }

    @Test("a blocked gate never fronts — it has recovery affordances to show")
    func blockedNeverFronts() {
        // `.blocked` carries retry / switch-brain surfaces that a slim banner
        // would bury (InterimBrainPolicy's own doctrine). Fronting there would
        // paper over a state the user must act on.
        #expect(InterimBrainPolicy.posture(
            gate: .blocked, delegationInFlight: false,
            preferMiniFront: true, depthReachable: true
        ) == .selectedBrain)
    }

    @Test("only the fronting posture asks the app to override the runtime")
    func overrideMapping() {
        #expect(FrontingPosture.miniFronts.frontsOnMini)
        #expect(!FrontingPosture.selectedBrain.frontsOnMini)
    }
}
