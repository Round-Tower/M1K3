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
//  ★ THE CONSTRAINT THIS TYPE EXISTS TO ENCODE
//
//  Fronting by default is only sound while a route to the deep brain actually
//  exists. If Mini answers at `.ready` too, the MLX brain answers nothing
//  interactively, and the ONLY remaining route to it is `delegate_deep` — a
//  tool that has never been invoked once across 8 days of logs. Switch this on
//  without a working depth trigger and the deep tier silently ceases to exist:
//  the exact outcome Kev rejected when he declined "Lil resident, no deep tier"
//  (2026-08-09), arriving through the other door.
//
//  So `depthReachable` is a REQUIRED parameter rather than a warning comment.
//  A caller cannot enable the posture without answering the question, and
//  answering it "no" refuses the preference rather than honouring it into a
//  Mini-only product. Failing to honour a preference is recoverable; quietly
//  deleting a product tier is not.
//
//  DEFAULT OFF. Whether Mini is good enough to front is an on-device question
//  (#102) that is still unanswered, and this file must not be read as an
//  assertion that it is. Same posture as the heartbeat's default-OFF pending
//  Kev's ruling: build the mechanism, let the measurement decide the default.
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
    ///   - preferMiniFront: the user's opt-in to the steady-state posture.
    ///     **Defaults OFF at every call site** — see this file's header.
    ///   - depthReachable: whether ANY route to the deep brain still exists.
    ///     Gates `preferMiniFront` only; the transient bridges ignore it,
    ///     because while the brain is downloading or already digging there is
    ///     no deep tier left to protect and Mini is the only thing that can
    ///     serve. Refusing to front there would re-gate the download
    ///     experience and queue the conversation behind a dive — breaking the
    ///     very promise `delegate_deep` makes.
    static func posture(
        gate: ChatGate,
        delegationInFlight: Bool,
        preferMiniFront: Bool,
        depthReachable: Bool
    ) -> FrontingPosture {
        // `.blocked` keeps its full gate and its recovery affordances (retry /
        // switch brain); fronting would paper over a state the user must act on.
        guard gate != .blocked else { return .selectedBrain }
        // The transient bridges — unconditional, exactly as shipped.
        if gate == .interim || delegationInFlight { return .miniFronts }
        // The steady state — opt-in AND a live route to depth.
        return preferMiniFront && depthReachable ? .miniFronts : .selectedBrain
    }
}
