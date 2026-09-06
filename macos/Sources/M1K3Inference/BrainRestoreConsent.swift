//
//  BrainRestoreConsent.swift
//  M1K3Inference
//
//  The launch restore's download-consent rule, shared by both shells (#237).
//
//  `BrainTier.easedToOfferedMini` can move a persisted Mini to pocket (LFM2.5-1.2B,
//  ~630 MB) on a device where Apple Intelligence is blocked. Before this, the warm
//  that followed started the download with no tap — the one thing every other
//  download in M1K3 waits for (VoiceTierRestore: chosen-but-missing must never kick
//  a silent re-download; the brain cards: the tap IS the consent). Kev's ruling,
//  2026-09-06: prompt once.
//
//  The rule: warm what the user chose themselves, or anything already on disk; an
//  EASED pick that would have to download waits for a tap, and the app sits on the
//  persisted tier (Mini — unready on a blocked device, which is exactly the state
//  the readiness gate already explains) until the offer is accepted.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-06, Confidence 0.9 (pure; six cases
//  pinned in BrainRestoreConsentTests). Prior: none (new file).
//

public enum BrainRestoreConsent {
    public enum Outcome: Sendable, Equatable {
        /// Select and warm this tier — the user picked it, or it's on disk already.
        case warm(BrainTier)
        /// Offer this tier's one-time download and, until it's accepted, stay on `keep`.
        case askFirst(BrainTier, keep: BrainTier)
    }

    /// - Parameters:
    ///   - persisted: the tier the user last chose (nil on a fresh install).
    ///   - eased: where the restore ladder (`easedToOfferedMini` → `selectableOrEased`) landed.
    ///   - staged: whether a tier's weights are already on disk.
    public static func resolve(
        persisted: BrainTier?,
        eased: BrainTier,
        staged: (BrainTier) -> Bool
    ) -> Outcome {
        guard eased != persisted, eased.requiresDownload, !staged(eased) else { return .warm(eased) }
        return .askFirst(eased, keep: persisted ?? .mini)
    }
}
