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

import Foundation

public enum ReviewPromptPolicy {
    /// Liked answers (the Mac's thumbs-up) before the user is presumed to
    /// have an opinion worth interrupting for.
    public static let minDelightCount = 2
    /// Completed turns that earn the ask on their own — the phone has no
    /// thumbs-up today, so sustained use carries the signal there.
    public static let minCompletedTurns = 20
    /// Whole days the app must have lived with the user first. Never ask in
    /// the install-session honeymoon; the opinion isn't formed yet.
    public static let minDaysSinceFirstUse = 3

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
