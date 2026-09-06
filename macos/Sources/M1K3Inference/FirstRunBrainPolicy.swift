//
//  FirstRunBrainPolicy.swift
//  M1K3Inference
//
//  The one-screen onboarding's brain decision. Mini-first is the product call
//  (time-to-first-whoa: talking in seconds beats a download bar) — but Mini is
//  Apple Foundation Models, and its availability has three flavours that
//  deserve three different answers. Pure so the whole table is `swift test`-able;
//  HelloView supplies the live `AFMAvailability` and acts on the outcome.
//
//  Invariants:
//    · a re-run never silently switches a non-Mini brain (Settings promises
//      "your brain is kept")
//    · `.notReady` is a transient asset sync — wait for Mini, never answer it
//      with a 2.3GB download
//    · a blocked AFM falls back to the pocket download (LFM2.5-1.2B, ~630 MB —
//      was Lil's 2.3 GB before 2026-09-06); the user-fixable flavour (Apple
//      Intelligence switched off) also offers the
//      OS-settings fix alongside.
//
//  Signed: Kev + claude-fable-5, 2026-07-03, Confidence 0.9. Prior: none (new file).
//  Review: Kev + claude-fable-5.1, 2026-09-06 — `AFMAvailability.isBlocked`; the blocked-AFM fallback downloads
//  pocket (LFM2.5-1.2B, ~630 MB) instead of Lil's 2.3 GB. Confidence now 0.9.

import Foundation

/// Apple Foundation Models availability, in product terms. Mapped from
/// `SystemLanguageModel.default.availability` by `AppleFoundationModelsProvider`
/// (SDK reasons verified 2026-07-03: deviceNotEligible /
/// appleIntelligenceNotEnabled / modelNotReady); pure here so policy tests
/// never need the framework.
public enum AFMAvailability: Sendable, Equatable {
    /// Ready to serve right now.
    case available
    /// Present but warming (model assets still syncing) — transient.
    case notReady
    /// Not serving on this Mac. `userFixable` when flipping Apple Intelligence
    /// on in System Settings would cure it; false for ineligible hardware
    /// (and unknown future reasons, where a settings pointer could mislead).
    case blocked(userFixable: Bool)

    /// Whether a snapshot of this value is safe to CACHE (vs. re-probe every
    /// read). Only genuinely stable states qualify: `.available` and
    /// hardware-ineligible `.blocked(userFixable: false)`. The transient
    /// warmup (`.notReady`) and the user-fixable block (`.blocked(true)` — the
    /// user might enable Apple Intelligence any moment) MUST re-probe, or the
    /// interim-Mini bridge freezes on a first-read `.notReady`/`.blocked(true)`
    /// and never activates for the session (2026-07-25 review finding).
    /// Blocked for either reason — the state in which `.pocket` stands in for `.mini`.
    public var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }

    public var isStableForCaching: Bool {
        switch self {
        case .available: true
        case .notReady: false
        case let .blocked(userFixable): !userFixable
        }
    }
}

/// Decides which brain serves the first session when "Say hello" is tapped.
public enum FirstRunBrainPolicy {
    public enum Outcome: Sendable, Equatable {
        /// Re-run with a non-Mini brain already chosen — keep it untouched.
        case keepCurrent(BrainTier)
        /// AFM serves — complete instantly, no download.
        case useMini
        /// AFM is warming — stay on Mini and re-poll; don't download anything.
        case waitForMini
        /// AFM is blocked — fall back to a one-time download of the given tier,
        /// optionally offering the Apple Intelligence settings fix beside it.
        case downloadFallback(BrainTier, offerAppleIntelligenceFix: Bool)
    }

    public static func resolve(afm: AFMAvailability, currentBrain: BrainTier) -> Outcome {
        // A re-pick/re-run with a heavier brain already chosen is sovereign —
        // first-run policy never overrides an explicit earlier choice.
        guard currentBrain == .mini else { return .keepCurrent(currentBrain) }
        switch afm {
        case .available:
            return .useMini
        case .notReady:
            return .waitForMini
        case let .blocked(userFixable):
            // pocket (LFM2.5-1.2B, ~630 MB) since 2026-09-06 — was Lil's 2.3 GB.
            return .downloadFallback(.pocket, offerAppleIntelligenceFix: userFixable)
        }
    }
}
