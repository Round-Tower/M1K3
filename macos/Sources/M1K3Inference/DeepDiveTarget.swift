//
//  DeepDiveTarget.swift
//  M1K3Inference
//
//  Which brain a `delegate_deep` dive runs on — the decision that turns the
//  tool from "background lane" into "escalation".
//
//  Until now the dive ran on whatever was already resident:
//  `AppEnvironment+DeepDelegation` passes `provider: swappableMLX`. On a Lil
//  machine that means a "deep dive" runs on Lil, the same brain that would have
//  answered inline — so the tool's own description had to stop promising a
//  deeper brain, and plausibly why the model has never called it once in 8 days
//  of logs. There was nothing on the other side worth asking for.
//
//  The architecture this serves is Kev's, and it is what his original goal
//  actually said: "push the 4B/3B tier, and move to Big for deep reasoning —
//  not always on", refined 2026-08-10 to "mini or lil, ideally always the
//  fastest, with a tool to delegate". Measured the same day on one build and
//  the live path: Lil 10.0s median, Big 30.5s, Mini 37.3s. So Lil is the right
//  FRONT, and Big is worth its cost only when depth is actually wanted — which
//  is precisely the split a delegation tool exists to make.
//
//  Two refusals are load-bearing:
//
//  1. An absent Big NEVER triggers a download. The brain switcher already
//     refuses to start a multi-GB pull "from one toolbar tap"; here nobody
//     tapped anything — the MODEL decided — so committing the user to gigabytes
//     of traffic would be worse. The dive degrades to the resident brain and
//     says so.
//  2. A Mac under Big's 16GB selection floor keeps its resident brain. A
//     background dive is the worst possible place to discover swap-thrash.
//
//  Signed: Kev + claude-opus-5, 2026-08-11, Confidence 0.85 (pure and pinned;
//  the swap it authorises is app glue and stays verify-by-launch — nothing here
//  has yet run a real cross-brain dive). Prior: Unknown.
//

import Foundation

/// What a delegated dive should do about the MLX slot.
public struct DeepDivePlan: Equatable, Sendable {
    /// The brain the dive should run on.
    public let tier: BrainTier
    /// Whether the single MLX slot must be re-pointed before the dive.
    /// False whenever `tier` is already resident — re-pointing would repay a
    /// multi-GB load and a cold persona-KV prefix for nothing.
    public let requiresSwap: Bool
    /// True when the dive genuinely reaches something deeper than the front.
    /// False means "same brain, in the background" — still useful (the long
    /// task stops blocking the conversation) but NOT depth, and the model-facing
    /// copy should not claim otherwise.
    public let isEscalation: Bool
}

public enum DeepDiveTarget {
    /// Where a dive should run, given what is resident and what this Mac has.
    ///
    /// - Parameters:
    ///   - resident: the weight-backed brain currently in the MLX slot.
    ///   - bigWeightsPresent: Big's weights already on disk. When false the
    ///     dive stays put — see refusal 1 in this file's header.
    ///   - physicalMemoryGB: this Mac's RAM, against Big's selection floor.
    public static func plan(
        resident: BrainTier,
        bigWeightsPresent: Bool,
        physicalMemoryGB: Double
    ) -> DeepDivePlan {
        let canRunBig = bigWeightsPresent
            && BrainTier.big.isSelectable(forPhysicalMemoryGB: physicalMemoryGB)
        guard canRunBig, resident != .big else {
            // Stay on the resident brain: either Big isn't reachable without a
            // download / enough memory, or it is already the one loaded.
            return DeepDivePlan(
                tier: resident,
                requiresSwap: false,
                isEscalation: false
            )
        }
        return DeepDivePlan(tier: .big, requiresSwap: true, isEscalation: true)
    }
}
