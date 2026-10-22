//
//  ReviewPromptPolicy.swift
//  M1K3Inference
//
//  The App Store rating ask — the pure judgement. A listing with no ratings
//  is invisible for every generic search term however good its metadata, so
//  the ask matters; and it must land at an EARNED moment, the same doctrine
//  as IntroductionOfferPolicy next door: M1K3 proves himself first, then asks
//  once. `ReviewPromptLedger` supplies the facts; this type owns the rule so
//  the rule is unit-pinned. The system's own three-per-year throttle decides
//  whether a dialog actually appears — that is a backstop, not the policy.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-15, Confidence 0.9. Prior: none
//  (new file; the shape is Cartogram's ReviewPromptPolicy, ported — its
//  thresholds shipped in Cartogram Mac 1.1 and its tests came with it).
//  Review: Kev + claude-opus-5.5, 2026-10-22 — 1 like / 10 turns / 1 day (were 2 / 20 / 3).
//  Measured: ~150 downloads in 28 days, 0 ratings in every storefront, search impression →
//  page tap ~2% against rated competitors. Challenger-reviewed: the ask is still once per
//  version, only wins count. Watch: ratings ÷ installs on 1.2.1 weekly per storefront (<2%
//  after 3 weeks → the gate wasn't the bottleneck); early 1–2★ → days back to 2.
//  Confidence 0.7.

import Foundation

public enum ReviewPromptPolicy {
    /// Liked answers (the thumbs-up, Mac and phone) before the user is presumed
    /// to have an opinion worth interrupting for. One is enough: it is the user
    /// volunteering "this was good", the most earned moment there is.
    public static let minDelightCount = 1
    /// Completed turns that earn the ask on their own, for users who never tap
    /// a thumb. Phone sessions are short; twenty was rarely reached.
    public static let minCompletedTurns = 10
    /// Whole days the app must have lived with the user first. Never ask in
    /// the install session; day three filtered for retention, not opinion.
    public static let minDaysSinceFirstUse = 1

    /// The one universal App Store record (Mac + iOS + visionOS).
    public static let appStoreID = "6780230835"

    /// - `delightCount`: liked answers recorded so far.
    /// - `completedTurns`: successful answers recorded so far.
    /// - `daysSinceFirstUse`: whole days since the first recorded use. A
    ///   negative value (a stamp in the future — clock skew or corrupted
    ///   state) never prompts.
    /// - `lastPromptedVersion`: the marketing version at the last ask, if
    ///   any. One ask per version, ever.
    public static func shouldPrompt(
        delightCount: Int,
        completedTurns: Int,
        daysSinceFirstUse: Int,
        lastPromptedVersion: String?,
        currentVersion: String
    ) -> Bool {
        let engaged = delightCount >= minDelightCount || completedTurns >= minCompletedTurns
        guard engaged else { return false }
        guard daysSinceFirstUse >= minDaysSinceFirstUse else { return false }
        guard lastPromptedVersion != currentVersion else { return false }
        return true
    }

    /// What counts as a completed turn for the ask: an answer that neither
    /// failed nor was stopped part-way. A stopped answer is persisted as
    /// `.complete` with `interrupted` set, so status alone would count it —
    /// and the whole doctrine is "only wins count". Every shell and both
    /// voice paths ask this one question.
    public static func isWin(answerFailed: Bool, interrupted: Bool) -> Bool {
        !answerFailed && !interrupted
    }

    /// Where the manual door ("Rate M1K3…") leads. The Mac opens the App
    /// Store app straight onto the review sheet; iOS opens the listing with
    /// the same action, which the store app honours.
    public enum Storefront: Sendable {
        case macAppStore
        case appStore
    }

    public static func writeReviewURL(storefront: Storefront, appID: String = appStoreID) -> URL {
        let scheme = switch storefront {
        case .macAppStore: "macappstore"
        case .appStore: "https"
        }
        // Force-unwrap is safe: a fixed scheme, host and path with a numeric id.
        return URL(string: "\(scheme)://apps.apple.com/app/id\(appID)?action=write-review")!
    }
}
