//
//  FrontingPosture.swift
//  M1K3Inference
//
//  Who answers an interactive turn: the selected brain, or Mini fronting for it.
//
//  Kev's standing vision is "quick by default, deep when complex" — Mini
//  (Apple Foundation Models, a SEPARATE Apple runtime that never touches the
//  MLX memory budget) holds the conversation, and the one MLX slot is kept for
//  work that needs it. The machinery for that already existed; what it lacked
//  was a steady state. Mini fronted only while a weight-backed brain downloaded
//  (`ChatGate.interim`) or while a `delegate_deep` dive held the slot.
//
//  A steady-state "Mini fronts by default" arm was added here on 2026-08-09 and
//  removed on 2026-08-10. Two independent reasons killed it, and both are worth
//  keeping because both are non-obvious:
//
//  1. NO DEPTH TRIGGER. With Mini answering at `.ready`, the MLX brain serves no
//     interactive turn, so `delegate_deep` becomes the only route to it — and
//     that tool has never been invoked once across 8 days of logs. The deep tier
//     would have ceased to exist silently: the outcome Kev rejected when he
//     declined "Lil resident, no deep tier", arriving through the other door.
//  2. IT WAS SLOWER, WHICH NOBODY EXPECTED. See the measurement below.
//
//  ★ RETIRED 2026-08-10 — MEASURED AND FALSIFIED. The steady-state opt-in this
//  file used to carry ("preferMiniFront") is gone, because the premise under it
//  is false. Same build, same 8 open-chat fixtures, same live path:
//
//      lil    median 10,022 ms   max  18,132 ms   7/8
//      big    median 30,500 ms   max 289,020 ms   (6 fixtures)
//      mini   median 37,292 ms   max 183,853 ms   6/8
//
//  Mini is the SLOWEST tier, by 3.7x against Lil — not the quick one. AFM opens
//  a fresh LanguageModelSession and re-sends the whole persona on every call,
//  while the MLX tiers reuse a cached KV prefix, so the "instant" tier is
//  structurally the most expensive per turn. Fronting on Mini would have made
//  M1K3 roughly four times slower than simply letting the resident brain answer.
//
//  A default-OFF switch whose only reachable effect is a 3.7x slowdown is a trap
//  for whoever finds it next, so it is removed rather than left disabled. The
//  TRANSIENT bridges below stay exactly as they always were: while the slot is
//  downloading or held by a dive, Mini is the only thing that can serve, and
//  something beats nothing.
//
//  Signed: Kev + claude-opus-5, 2026-08-09, Confidence 0.85 (pure and pinned,
//  and byte-identical to shipped behaviour with the opt-in off; the unanswered
//  half is whether the front is GOOD, which no unit test can settle).
//  Prior: Unknown.
//  Context: macos/docs/NEXT_SESSION.md work-order item 5.
//

import Foundation

/// Which brain serves interactive turns right now.
public enum FrontingPosture: Sendable, Equatable {
    /// The selected brain answers — today's normal behaviour.
    case selectedBrain
    /// Mini answers; the MLX slot is left free for depth.
    case miniFronts

    /// Whether the app should override the runtime to Apple Foundation Models.
    ///
    /// A Bool rather than a runtime enum on purpose: the app's `RuntimeOption`
    /// is app-local, and this package must not reach up into the shell to name
    /// it. The composition root maps this one flag.
    public var frontsOnMini: Bool {
        self == .miniFronts
    }
}

public extension InterimBrainPolicy {
    /// Who should answer the next interactive turn.
    ///
    /// - Parameters:
    ///   - gate: the resolved readiness gate for the selected brain.
    ///   - delegationInFlight: a `delegate_deep` dive currently holds the slot.
    ///
    /// Mini fronts ONLY while the MLX slot cannot serve — mid-download or
    /// mid-dive. There is deliberately no steady-state arm: see the header for
    /// the measurement that removed it.
    static func posture(
        gate: ChatGate,
        delegationInFlight: Bool
    ) -> FrontingPosture {
        // `.blocked` keeps its full gate and its recovery affordances (retry /
        // switch brain); fronting would paper over a state the user must act on.
        guard gate != .blocked else { return .selectedBrain }
        // The transient bridges. Unconditional: while the brain is downloading
        // or already digging there is nothing else that can answer, and Mini
        // being slower than the resident brain is irrelevant when the resident
        // brain is unavailable.
        return (gate == .interim || delegationInFlight) ? .miniFronts : .selectedBrain
    }
}
