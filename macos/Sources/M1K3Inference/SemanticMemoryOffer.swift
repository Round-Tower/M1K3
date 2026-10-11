//
//  SemanticMemoryOffer.swift
//  M1K3Inference
//
//  When a brain download carries an "Also get semantic memory" offer. Kev, 2026-10-11:
//  EmbeddingGemma 2 (~1.3 GB) is OFFERED WITH Lil/Big, pre-ticked, size shown, one tap;
//  Mini-only users stay on Hashing. So: only for a Lil or Big target, and only while the Mac is
//  not already on MLX embeddings and does not already hold the embedder (then there is nothing
//  to fetch; Settings > Brains & downloads is the door). The surfaces (the onboarding kit card,
//  `BrainPickerView`, the brain-upgrade card) all ask this one function.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.85 (pure; each surface is
//  verify-by-launch). Prior: none (new file).

import Foundation

public enum SemanticMemoryOffer {
    /// The offer is pre-ticked: one tap on the brain's own button takes both.
    public static let preTicked = true

    /// Whether to show the offer next to a download of `brainTarget`.
    public static func shouldOffer(brainTarget: BrainTier?, usingMLXEmbeddings: Bool, installed: Bool) -> Bool {
        guard !usingMLXEmbeddings, !installed, let brainTarget else { return false }
        switch brainTarget {
        case .lil, .big: return true
        case .mini, .pocket: return false
        }
    }

    /// "Also get semantic memory (1.3 GB)": `size` is the caller's formatted size.
    public static func toggleTitle(size: String) -> String {
        String(localized: "Also get semantic memory (\(size))")
    }

    public static var toggleDetail: String {
        String(localized: "Better recall of your notes.")
    }
}
