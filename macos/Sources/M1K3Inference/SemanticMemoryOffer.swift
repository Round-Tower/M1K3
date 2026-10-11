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
//  Review: Kev + claude-opus-5.5, 2026-10-11 (pre-push review fold) — O2/O4: `toggleDetail(brainName:)` says when it
//  starts; `slot(...)` reserves the toggle's space before the first disk scan. Confidence 0.85.

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

    /// EmbeddingGemma 2's rough size, for the offer when the catalogue has no pinned figure.
    public static let approximateBytes: Int64 = 1_300_000_000

    /// The size the toggle shows: the catalogue's bytes, or (for an unpinned 0) the rough figure with a "~",
    /// never "Zero KB".
    public static func sizeText(catalogueBytes: Int64) -> String {
        let bytes = catalogueBytes > 0 ? catalogueBytes : approximateBytes
        return (catalogueBytes > 0 ? "" : "~") + bytes.formatted(.byteCount(style: .file))
    }

    /// "Also get semantic memory (1.3 GB)": `size` is the caller's formatted size.
    public static func toggleTitle(size: String) -> String {
        String(localized: "Also get semantic memory (\(size))")
    }

    public static var toggleDetail: String {
        String(localized: "Better recall of your notes.")
    }

    /// The detail line beside a brain download: the benefit, then when it starts (it waits for the brain).
    public static func toggleDetail(brainName: String) -> String {
        "\(toggleDetail) \(SemanticMemoryQueue.startsAfterLine(brainName: brainName))"
    }

    /// What the toggle's layout slot does. The slot is RESERVED before the first disk scan (invisible, not
    /// tappable) so the toggle popping in never shoves the button beneath it.
    public enum Slot: Equatable, Sendable {
        /// No offer is possible here: no slot, no gap.
        case none
        /// A Lil/Big download that may carry the offer, but the scan has not landed: space, no content.
        case reserved
        case shown
    }

    public static func slot(brainTarget: BrainTier?, scanned: Bool, usingMLXEmbeddings: Bool, installed: Bool) -> Slot {
        if !scanned {
            // Everything but the scan's facts decides whether the slot could ever fill.
            return shouldOffer(brainTarget: brainTarget, usingMLXEmbeddings: usingMLXEmbeddings, installed: false) ? .reserved : .none
        }
        return shouldOffer(brainTarget: brainTarget, usingMLXEmbeddings: usingMLXEmbeddings, installed: installed) ? .shown : .none
    }
}
