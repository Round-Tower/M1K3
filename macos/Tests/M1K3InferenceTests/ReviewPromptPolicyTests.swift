//
//  ReviewPromptPolicyTests.swift
//  M1K3InferenceTests
//
//  The App Store rating ask. A listing with no ratings is invisible for
//  every generic search term however good the metadata is, so the ask
//  matters — and it must land at an EARNED moment, never at a hollow one:
//    · earned: one liked answer (the user volunteering "this was good"), or
//      ten completed turns (phone sessions are short)
//    · settled: never in the install session — one whole day first
//    · one ask per marketing version, ever — the system's own three-per-year
//      throttle is a backstop, not the policy
//    · broken state (a first-use date in the future) stays quiet
//
//  Signed: Kev + claude-fable-5.1, 2026-09-15, Confidence 0.9. Prior: none
//  (new file; the shape is Cartogram's ReviewPromptPolicy, ported).
//  Review: Kev + claude-opus-5.5, 2026-10-22 — the bars move to 1 like / 10 turns /
//  1 day (were 2 / 20 / 3): ~150 downloads, 0 ratings in every storefront, and phone
//  sessions rarely reach 20 turns or day 3. Pinned as literals so a drift is a red
//  test, not a silent constant. Challenger-reviewed. Confidence 0.7.

import Foundation
@testable import M1K3Inference
import Testing

struct ReviewPromptPolicyTests {
    private func shouldPrompt(
        delightCount: Int = 1,
        completedTurns: Int = 0,
        daysSinceFirstUse: Int = 5,
        lastPromptedVersion: String? = nil,
        currentVersion: String = "1.0.1"
    ) -> Bool {
        ReviewPromptPolicy.shouldPrompt(
            delightCount: delightCount,
            completedTurns: completedTurns,
            daysSinceFirstUse: daysSinceFirstUse,
            lastPromptedVersion: lastPromptedVersion,
            currentVersion: currentVersion
        )
    }

    @Test("engaged, settled, and not yet asked → prompt")
    func promptsWhenEarned() {
        #expect(shouldPrompt())
    }

    @Test("no liked answer and nine turns is not yet an opinion")
    func tooLittleEngagementStaysQuiet() {
        #expect(!shouldPrompt(delightCount: 0, completedTurns: 9))
        #expect(!shouldPrompt(delightCount: 0, completedTurns: 0))
    }

    @Test("one liked answer earns it; so do ten completed turns on their own")
    func eitherSignalEarnsIt() {
        #expect(shouldPrompt(delightCount: 1, completedTurns: 0))
        #expect(shouldPrompt(delightCount: 0, completedTurns: 10))
        #expect(ReviewPromptPolicy.minDelightCount == 1)
        #expect(ReviewPromptPolicy.minCompletedTurns == 10)
    }

    @Test("the install session is protected — never ask on day zero")
    func honeymoonIsProtected() {
        #expect(!shouldPrompt(daysSinceFirstUse: 0))
        #expect(shouldPrompt(daysSinceFirstUse: 1))
        #expect(ReviewPromptPolicy.minDaysSinceFirstUse == 1)
    }

    @Test("never twice for the same marketing version")
    func onceMorePerVersionOnly() {
        #expect(!shouldPrompt(lastPromptedVersion: "1.0.1", currentVersion: "1.0.1"))
        #expect(shouldPrompt(lastPromptedVersion: "1.0.0", currentVersion: "1.0.1"))
    }

    @Test("a first-use date in the future is broken state — stay quiet")
    func clockSkewStaysQuiet() {
        #expect(!shouldPrompt(daysSinceFirstUse: -1))
    }

    @Test("a failed or stopped answer is not a win; a clean one is")
    func onlyWinsCount() {
        #expect(ReviewPromptPolicy.isWin(answerFailed: false, interrupted: false))
        #expect(!ReviewPromptPolicy.isWin(answerFailed: true, interrupted: false))
        #expect(!ReviewPromptPolicy.isWin(answerFailed: false, interrupted: true))
    }

    // MARK: - The manual door: "Rate M1K3…"

    @Test("the write-review link opens the store app on the Mac and the listing on iOS")
    func writeReviewLinks() {
        #expect(
            ReviewPromptPolicy.writeReviewURL(storefront: .macAppStore).absoluteString
                == "macappstore://apps.apple.com/app/id6780230835?action=write-review"
        )
        #expect(
            ReviewPromptPolicy.writeReviewURL(storefront: .appStore).absoluteString
                == "https://apps.apple.com/app/id6780230835?action=write-review"
        )
    }
}
