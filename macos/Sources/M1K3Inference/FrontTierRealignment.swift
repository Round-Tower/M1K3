//
//  FrontTierRealignment.swift
//  M1K3Inference
//
//  A one-time nudge for a persisted brain pick that is heavier than the ladder now
//  recommends.
//
//  Why this has to exist: on 2026-08-11 `BrainTier.recommended` changed so Lil
//  fronts every Mac — Big is 3x slower on the same fixtures (10.0s vs 30.5s
//  median) with a tail that blew a 120s deadline on an ordinary question. That
//  change fixed the experience for NOBODY who was already running, because a
//  recommendation only decides a pick that hasn't been made. Kev's own 64GB Mac
//  stayed resident on Big and he reported voice-first as slow the next day. A
//  default that only reaches new installs isn't a default, it's a rumour.
//
//  Deliberately NOT in `BrainTier(persisted:)` (where "huge" → `.big` lives):
//  that decoder runs on every read, so a rule there wouldn't be a migration, it
//  would make the deep tier permanently unselectable. This is a decision made
//  ONCE, recorded with its own marker, and reversible in Settings — Big is not
//  retired, it's the tier you reach for depth (and `delegate_deep` reaches it for
//  you).
//
//  Signed: Kev + claude-opus-5, 2026-08-11, Confidence 0.9 (pure and red-first;
//  the "once" marker and the notice wording are the load-bearing parts, and the
//  fact that it follows the LADDER rather than naming Big is what keeps it correct
//  if the ladder moves again). Prior: Unknown.
//
//  Reviewed: Kev + claude-opus-5, 2026-08-12 — a PR review caught that the marker
//  had the wrong MEANING at the call site ("it fired" rather than "the window has
//  passed"), which made the nudge able to override a Big picked deliberately AFTER
//  this shipped. The rule now lives in `plan`'s doc as an explicit contract,
//  because the bug was never in this function — it was in what the caller stored.
//

import Foundation

/// Aligns a stored brain choice with the current recommendation, exactly once.
public enum FrontTierRealignment {
    /// What to do about a stored pick: which tier to store, and what to tell the
    /// user (silently swapping the brain someone chose would be worse than slow).
    public struct Plan: Equatable, Sendable {
        public let tier: BrainTier
        public let notice: String

        public init(tier: BrainTier, notice: String) {
            self.tier = tier
            self.notice = notice
        }
    }

    /// `nil` means leave the stored pick exactly as it is.
    ///
    /// ⚠️ Call-site contract: **evaluating this SPENDS the nudge**, whether or not
    /// it fired. The marker is not "it has fired before", it is "the one-time
    /// window has passed" — record it on every evaluation, unconditionally.
    /// Setting it only on the firing branch looks equivalent and is not: a Mac
    /// running Lil evaluates to `nil`, leaves the marker `false` forever, and then
    /// the FIRST time its owner deliberately picks Big in Settings, the next
    /// launch quietly takes it back off them. That is a manual pick being
    /// overridden — the exact thing `BrainTier.selectableOrEased` promises never
    /// happens (#81's never-touch-an-explicit-pick rule). A pick made today was
    /// made against today's ladder; there is nothing left to realign.
    ///
    /// - Parameters:
    ///   - persisted: the decoded stored pick (a machine with no pick yet is
    ///     already governed by `recommended`, so it decodes to that default and
    ///     nothing here applies).
    ///   - nudgeSpent: whether the one-time window has passed — see above.
    ///   - recommended: what the ladder recommends for THIS machine now.
    public static func plan(
        persisted: BrainTier,
        nudgeSpent: Bool,
        recommended: BrainTier
    ) -> Plan? {
        guard !nudgeSpent else { return nil }
        // Only ever downhill, and only when the ladder has actually moved beneath
        // this pick. Never "upgrade" someone into a download they didn't ask for.
        guard persisted > recommended else { return nil }
        return Plan(
            tier: recommended,
            notice: "I've moved to my \(recommended.displayName) brain for everyday chat — "
                + "it answers about three times quicker. \(persisted.displayName) is still "
                + "here for deep thinking, and you can switch back any time in Settings."
        )
    }
}
