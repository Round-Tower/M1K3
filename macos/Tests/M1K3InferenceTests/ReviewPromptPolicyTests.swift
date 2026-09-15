//
//  ReviewPromptPolicyTests.swift
//  M1K3InferenceTests
//
//  The App Store rating ask. A listing with no ratings is invisible for
//  every generic search term however good the metadata is, so the ask
//  matters — and it must land at an EARNED moment, never at a hollow one:
//    · earned: two liked answers, or twenty completed turns (the phone has
//      no thumbs-up, so turns carry it there)
//    · settled: the app has lived with the user three whole days first
//    · one ask per marketing version, ever — the system's own three-per-year
//      throttle is a backstop, not the policy
//    · broken state (a first-use date in the future) stays quiet
//
//  Signed: Kev + claude-fable-5.1, 2026-09-15, Confidence 0.9. Prior: none
//  (new file; the shape is Cartogram's ReviewPromptPolicy, ported).

import Foundation
@testable import M1K3Inference
import Testing

struct ReviewPromptPolicyTests {
    private func shouldPrompt(
        delightCount: Int = 2,
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

    @Test("one liked answer and nineteen turns is not yet an opinion")
    func tooLittleEngagementStaysQuiet() {
        #expect(!shouldPrompt(delightCount: 1, completedTurns: 19))
        #expect(!shouldPrompt(delightCount: 0, completedTurns: 0))
    }

    @Test("two liked answers earn it; so do twenty completed turns on their own")
    func eitherSignalEarnsIt() {
        #expect(shouldPrompt(delightCount: ReviewPromptPolicy.minDelightCount, completedTurns: 0))
        #expect(shouldPrompt(delightCount: 0, completedTurns: ReviewPromptPolicy.minCompletedTurns))
    }

    @Test("the first days are protected — never ask in the install honeymoon")
    func honeymoonIsProtected() {
        #expect(!shouldPrompt(daysSinceFirstUse: 0))
        #expect(!shouldPrompt(daysSinceFirstUse: 2))
        #expect(shouldPrompt(daysSinceFirstUse: ReviewPromptPolicy.minDaysSinceFirstUse))
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
