//
//  DeepDelegationPolicy.swift
//  M1K3Inference
//
//  Eligibility for delegate_deep (Kev, 2026-07-25): hand a long-form task to
//  the resident MLX brain in the background and keep the conversation quick on
//  Mini meanwhile. The challenger-hardened constraint this encodes: the app
//  runs ONE MLX decode loop, ever — the process-global memory budget
//  (MLXMemoryBudget) is back-pressure, so two concurrent MLX generations stall
//  each other into minutes-long turns. Mini (Apple Foundation Models) is a
//  separate Apple runtime that never touches the MLX budget, which makes
//  "Mini fronts while the MLX slot digs" the one concurrency story the GPU
//  actually allows. Hence BOTH lanes are required.
//
//  Signed: Kev + claude-fable-5, 2026-07-25, Confidence 0.9, Prior: Unknown
//

import Foundation

public enum DeepDelegationPolicy {
    public enum Eligibility: Equatable, Sendable {
        /// Deep brain ready + Mini available to front — delegate away.
        case eligible
        /// Mini is the selected brain: there is no heavier resident to hand to.
        case noDeepBrain
        /// The MLX brain exists but isn't warm (downloading/preparing/failed).
        case deepBrainNotReady
        /// No AFM to keep the conversation responsive while the slot digs —
        /// interactive turns would queue behind the delegation, breaking the
        /// entire "stays quick" promise.
        case noFrontBrain

        /// Model-facing refusal for the tool observation (the "Error: …"
        /// contract — returned, never thrown, so the model can adapt).
        public var refusalObservation: String? {
            switch self {
            case .eligible:
                nil
            case .noDeepBrain:
                "Error: no deeper brain is set up — Mini is the only brain on duty. "
                    + "Suggest picking Lil or Big in Settings for background deep dives."
            case .deepBrainNotReady:
                "Error: the deep brain isn't ready yet (still downloading or warming). "
                    + "Answer directly, or suggest trying the deep dive again shortly."
            case .noFrontBrain:
                "Error: can't keep the conversation running while digging — Apple "
                    + "Intelligence isn't available on this Mac to cover the chat. "
                    + "Answer directly instead."
            }
        }
    }

    public static func eligibility(
        selectedRequiresWeights: Bool,
        load: ModelLoadState,
        afm: AFMAvailability
    ) -> Eligibility {
        guard selectedRequiresWeights else { return .noDeepBrain }
        guard case .ready = load else { return .deepBrainNotReady }
        guard afm == .available else { return .noFrontBrain }
        return .eligible
    }
}
