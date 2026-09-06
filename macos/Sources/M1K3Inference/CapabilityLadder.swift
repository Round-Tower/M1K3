//
//  CapabilityLadder.swift
//  M1K3Inference
//
//  The push toward what we built — Mini-first gets a stranger talking in
//  seconds, but the product mustn't strand them there. Three pure decisions
//  that turn the one-shot upgrade nudge into a ladder:
//
//    · UpgradeTarget — the next rung for THIS Mac. Mini offers the
//      recommended tier directly (one right download, not two), Lil offers
//      Big only where Big is comfortable, Big is the top.
//    · StrugglePolicy — the small brain visibly hitting its ceiling. Pressure
//      must track REALITY: a re-offer earned by a felt limitation reads as
//      care; a re-offer on a timer reads as growth-hacking. There is no
//      timer input here by design.
//    · DismissalParkPolicy — "Maybe later" parks the offer until enough
//      struggles accumulate; three dismissals is an answer, permanently.
//
//  The coordinator persists two integers (dismissals, struggles-since) and
//  feeds them here; BrainUpgradePolicy's machine is unchanged — the park
//  decision arrives through its existing `dismissed` recompute input.
//
//  Signed: Kev + claude-fable-5, 2026-07-03, Confidence 0.85 (thresholds are
//  product taste — tunable constants, pinned by tests; the shape is the
//  decision). Prior: none (new file).
//  Review: Kev + claude-fable-5.1, 2026-09-06 — the long-ask struggle covers pocket as well as Mini (same role, PR
//  #234 code-quality review). Confidence now 0.85.

import Foundation

/// The next brain rung worth offering on a machine with this much memory —
/// or nil when the current brain already IS the right ceiling.
public enum UpgradeTarget {
    public static func next(from current: BrainTier, physicalMemoryGB: Double) -> BrainTier? {
        let ceiling = BrainTier.recommended(forPhysicalMemoryGB: physicalMemoryGB)
        guard ceiling > current else { return nil }
        return ceiling
    }

    /// Convenience for the machine we're on.
    public static func nextForThisMac(from current: BrainTier) -> BrainTier? {
        next(from: current, physicalMemoryGB: Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824)
    }
}

/// What counts as the current brain visibly hitting its ceiling.
public enum StrugglePolicy {
    /// A question this long on the SMALLEST brain is a long-form ask — the
    /// class of turn the bigger brains exist for. Mini-only: Lil handles
    /// length fine; its struggles show up as failures/caps instead.
    public static let longAskCharacterThreshold = 600

    public static func isStruggle(
        brain: BrainTier,
        questionCharacters: Int,
        answerFailed: Bool,
        generationHitTokenCap: Bool
    ) -> Bool {
        // The top rung has no upsell — nothing above it to push toward.
        guard brain < .big else { return false }
        if answerFailed { return true }
        if generationHitTokenCap { return true }
        // Mini's ceiling is the point — and pocket wears the same role (a 1.2B).
        if brain == .mini || brain == .pocket, questionCharacters >= longAskCharacterThreshold { return true }
        return false
    }
}

/// Whether the offer is currently parked by a past "Maybe later".
public enum DismissalParkPolicy {
    /// Felt struggles required to earn a re-offer after a dismissal.
    public static let strugglesToUnpark = 3
    /// Dismissals after which the user has answered — terminal, full stop.
    public static let terminalDismissals = 3

    public static func isParked(dismissals: Int, strugglesSinceLastDismissal: Int) -> Bool {
        guard dismissals > 0 else { return false }
        if dismissals >= terminalDismissals { return true }
        return strugglesSinceLastDismissal < strugglesToUnpark
    }
}
