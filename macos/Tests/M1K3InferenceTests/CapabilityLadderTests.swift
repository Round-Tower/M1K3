//
//  CapabilityLadderTests.swift
//  M1K3InferenceTests
//
//  The capability ladder — the push toward what we built, without becoming a
//  freemium funnel. Three pure decisions:
//    · UpgradeTarget — which tier the NEXT rung offers on this Mac (mini →
//      the recommended tier; lil → big when the Mac is comfortable; never a
//      rung the machine can't carry, never downhill)
//    · StrugglePolicy — what counts as the small brain visibly hitting its
//      ceiling (a failed turn, a long-form ask, a capped-out generation);
//      pressure must track REALITY, never a timer
//    · DismissalParkPolicy — "Maybe later" parks the offer until enough felt
//      struggles accumulate; three dismissals means the user has answered,
//      permanently. Respect beats conversion.
//
//  Signed: Kev + claude-fable-5, 2026-07-03, Confidence 0.9. Prior: none (new file).
//  Review: Kev + claude-fable-5.1, 2026-09-06 — pocket's long-ask struggle pinned. Confidence 0.9.

@testable import M1K3Inference
import Testing

struct CapabilityLadderTests {
    // MARK: - UpgradeTarget: the next rung for THIS Mac

    @Test("Mini on a 16GB Mac → Lil (the recommended tier)")
    func miniOffersLilOn16() {
        #expect(UpgradeTarget.next(from: .mini, physicalMemoryGB: 16) == .lil)
    }

    @Test("Mini on a 24GB+ Mac → Lil, the fast front (was Big until 2026-08-11)")
    func miniOffersLilOnBigMacs() {
        // The upgrade ladder follows `recommended`, which now tops out at Lil on
        // every Mac. Offering Big here would sell the user a 3x SLOWER resident
        // brain as an "upgrade" (measured: lil 10.0s median vs big 30.5s).
        // Big is reached for depth via delegate_deep, not by moving in.
        #expect(UpgradeTarget.next(from: .mini, physicalMemoryGB: 24) == .lil)
        #expect(UpgradeTarget.next(from: .mini, physicalMemoryGB: 64) == .lil)
    }

    @Test("Mini on an 8GB Mac → no rung: the recommendation IS Mini")
    func miniOn8HasNoRung() {
        #expect(UpgradeTarget.next(from: .mini, physicalMemoryGB: 8) == nil)
    }

    @Test("★ Lil is the top rung on every Mac — nothing to upsell")
    func lilIsTheCeilingEverywhere() {
        // A Lil user is already on the brain we want them on, so the upgrade
        // prompt stays quiet rather than nagging them onto a slower resident.
        // When a turn genuinely needs depth the answer is delegate_deep, which
        // borrows Big for one task — not a permanent move that taxes every
        // subsequent turn.
        #expect(UpgradeTarget.next(from: .lil, physicalMemoryGB: 24) == nil)
        #expect(UpgradeTarget.next(from: .lil, physicalMemoryGB: 64) == nil)
    }

    @Test("Lil on a 16GB Mac → no rung: Big would be hostile there")
    func lilOn16HasNoRung() {
        #expect(UpgradeTarget.next(from: .lil, physicalMemoryGB: 16) == nil)
    }

    @Test("Big → done, there is no rung above")
    func bigIsTheTop() {
        #expect(UpgradeTarget.next(from: .big, physicalMemoryGB: 64) == nil)
    }

    // MARK: - StrugglePolicy: pressure tracks reality

    @Test("a failed turn on a laddered brain is a struggle")
    func failedTurnStruggles() {
        #expect(StrugglePolicy.isStruggle(
            brain: .mini, questionCharacters: 40, answerFailed: true, generationHitTokenCap: false
        ))
    }

    @Test("a long-form ask on Mini is a struggle (its ceiling is the point)")
    func longAskOnMiniStruggles() {
        #expect(StrugglePolicy.isStruggle(
            brain: .mini,
            questionCharacters: StrugglePolicy.longAskCharacterThreshold,
            answerFailed: false,
            generationHitTokenCap: false
        ))
    }

    @Test("a long-form ask on pocket is a struggle too — the same role, a 1.2B")
    func longAskOnPocketStruggles() {
        #expect(StrugglePolicy.isStruggle(
            brain: .pocket,
            questionCharacters: StrugglePolicy.longAskCharacterThreshold,
            answerFailed: false,
            generationHitTokenCap: false
        ))
    }

    @Test("the same long ask on Big is NOT a struggle — the top rung has no upsell")
    func longAskOnBigIsFine() {
        #expect(!StrugglePolicy.isStruggle(
            brain: .big,
            questionCharacters: StrugglePolicy.longAskCharacterThreshold,
            answerFailed: false,
            generationHitTokenCap: false
        ))
    }

    @Test("a capped-out generation is a struggle; a short clean answer is not")
    func cappedGenerationStruggles() {
        #expect(StrugglePolicy.isStruggle(
            brain: .lil, questionCharacters: 40, answerFailed: false, generationHitTokenCap: true
        ))
        #expect(!StrugglePolicy.isStruggle(
            brain: .mini, questionCharacters: 40, answerFailed: false, generationHitTokenCap: false
        ))
    }

    // MARK: - DismissalParkPolicy: parked, not buried — until it is

    @Test("never dismissed → not parked")
    func freshIsUnparked() {
        #expect(!DismissalParkPolicy.isParked(dismissals: 0, strugglesSinceLastDismissal: 0))
    }

    @Test("one dismissal parks the offer until three felt struggles accumulate")
    func dismissalParksUntilStruggles() {
        #expect(DismissalParkPolicy.isParked(dismissals: 1, strugglesSinceLastDismissal: 0))
        #expect(DismissalParkPolicy.isParked(dismissals: 1, strugglesSinceLastDismissal: 2))
        #expect(!DismissalParkPolicy.isParked(dismissals: 1, strugglesSinceLastDismissal: 3))
    }

    @Test("three dismissals is an answer — terminal, whatever the struggles say")
    func threeDismissalsIsTerminal() {
        #expect(DismissalParkPolicy.isParked(dismissals: 3, strugglesSinceLastDismissal: 99))
        #expect(DismissalParkPolicy.isParked(dismissals: 4, strugglesSinceLastDismissal: 99))
    }

    @Test("second dismissal re-parks and needs a fresh run of struggles")
    func secondDismissalReParks() {
        #expect(DismissalParkPolicy.isParked(dismissals: 2, strugglesSinceLastDismissal: 0))
        #expect(!DismissalParkPolicy.isParked(dismissals: 2, strugglesSinceLastDismissal: 3))
    }
}
