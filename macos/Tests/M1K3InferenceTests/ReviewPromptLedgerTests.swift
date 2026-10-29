//
//  ReviewPromptLedgerTests.swift
//  M1K3InferenceTests
//
//  The ledger behind the rating ask: first-use stamp, the two engagement
//  counters, and the once-per-version mark. Storage is a protocol so the
//  tests run against a dictionary — `swift test` is unsandboxed and a
//  UserDefaults suite would leave a plist behind. The screengrab harness
//  (App Store plates) must never stamp, count, or prompt: a rating dialog
//  over a plate capture, or a demo run inflating the real user's counters,
//  are both disasters — the guard sits on EVERY write, not just the prompt.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-15, Confidence 0.9. Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-22 — the honeymoon is the first whole day now (the
//  policy asks from day 1, was day 3): engagement in hand 20 h after first use still stays quiet;
//  one liked answer is enough on day 1. Confidence 0.8.
//  Review: Kev + claude-opus-5.5, 2026-10-29 — the crash stamp (#750): the newest crash wins, a future date
//  is held at now, and a held ask never marks the version. Confidence 0.8.
//  Review: Kev + claude-opus-5.5, 2026-10-29 (pre-push review fold) — a stored stamp after now is no crash on
//  record and the next crash replaces it; the day names match their offsets. Confidence 0.8.

import Foundation
@testable import M1K3Inference
import Testing

@MainActor
struct ReviewPromptLedgerTests {
    /// Dictionary-backed storage — what UserDefaults is to the shells.
    private final class MemoryStorage: ReviewPromptStorage {
        var values: [String: Any] = [:]
        func object(forKey key: String) -> Any? {
            values[key]
        }

        func set(_ value: Any?, forKey key: String) {
            if let value { values[key] = value } else { values.removeValue(forKey: key) }
        }
    }

    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private func ledger(
        storage: MemoryStorage,
        version: String = "1.0.1",
        suppressed: Bool = false,
        now: Date? = nil
    ) -> ReviewPromptLedger {
        let at = now ?? epoch
        return ReviewPromptLedger(
            storage: storage, version: version,
            suppressed: { suppressed }, now: { at }
        )
    }

    @Test("first use is stamped once and never overwritten for a returning user")
    func firstUseStampedOnce() {
        let storage = MemoryStorage()
        _ = ledger(storage: storage)
        #expect(storage.object(forKey: ReviewPromptLedger.firstUseKey) as? Double == epoch.timeIntervalSince1970)
        let later = ledger(storage: storage, now: epoch.addingTimeInterval(86400 * 10))
        #expect(storage.object(forKey: ReviewPromptLedger.firstUseKey) as? Double == epoch.timeIntervalSince1970)
        #expect(later.daysSinceFirstUse == 10)
    }

    @Test("counters increment, persist, and reload")
    func countersPersist() {
        let storage = MemoryStorage()
        let first = ledger(storage: storage)
        first.recordDelight()
        first.recordCompletedTurn()
        first.recordCompletedTurn()
        #expect(first.delightCount == 1)
        #expect(first.completedTurns == 2)
        let reloaded = ledger(storage: storage)
        #expect(reloaded.delightCount == 1)
        #expect(reloaded.completedTurns == 2)
    }

    @Test("suppressed (screengrab harness): no stamp, no counts, no prompt")
    func suppressedTouchesNothing() {
        let storage = MemoryStorage()
        let led = ledger(storage: storage, suppressed: true, now: epoch.addingTimeInterval(86400 * 30))
        led.recordDelight()
        led.recordDelight()
        led.recordCompletedTurn()
        #expect(storage.values.isEmpty)
        #expect(led.delightCount == 0)
        #expect(led.completedTurns == 0)
        #expect(led.daysSinceFirstUse == 0)
        #expect(!led.consumePromptIfDue())
    }

    @Test("consume marks the version as asked — a second call is quiet, a new version may ask again")
    func consumeMarksTheVersion() {
        let storage = MemoryStorage()
        _ = ledger(storage: storage)
        let dayOne = ledger(storage: storage, now: epoch.addingTimeInterval(86400))
        dayOne.recordDelight()
        #expect(dayOne.consumePromptIfDue())
        #expect(storage.object(forKey: ReviewPromptLedger.promptedVersionKey) as? String == "1.0.1")
        #expect(!dayOne.consumePromptIfDue())
        let nextRelease = ledger(storage: storage, version: "1.1", now: epoch.addingTimeInterval(86400 * 40))
        #expect(nextRelease.consumePromptIfDue())
        #expect(storage.object(forKey: ReviewPromptLedger.promptedVersionKey) as? String == "1.1")
    }

    @Test("the honeymoon holds even with the engagement in hand")
    func honeymoonHolds() {
        let storage = MemoryStorage()
        let installSession = ledger(storage: storage, now: epoch)
        installSession.recordDelight()
        installSession.recordDelight()
        let later = ledger(storage: storage, now: epoch.addingTimeInterval(20 * 3600))
        #expect(later.daysSinceFirstUse == 0)
        #expect(!later.consumePromptIfDue())
        #expect(storage.object(forKey: ReviewPromptLedger.promptedVersionKey) == nil)
    }

    @Test("a first-use stamp in the future reads as negative days and never asks")
    func futureStampStaysQuiet() {
        let storage = MemoryStorage()
        storage.set(epoch.addingTimeInterval(86400 * 5).timeIntervalSince1970, forKey: ReviewPromptLedger.firstUseKey)
        let led = ledger(storage: storage, now: epoch)
        led.recordDelight()
        led.recordDelight()
        #expect(led.daysSinceFirstUse < 0)
        #expect(!led.consumePromptIfDue())
    }

    @Test("a crash holds the ask for three days and does not spend the version's chance")
    func crashHoldsTheAsk() {
        let storage = MemoryStorage()
        _ = ledger(storage: storage)
        let atDay5 = ledger(storage: storage, now: epoch.addingTimeInterval(86400 * 5))
        atDay5.recordDelight()
        atDay5.recordCrash(at: epoch.addingTimeInterval(86400 * 4))
        #expect(atDay5.daysSinceLastCrash == 1)
        #expect(!atDay5.consumePromptIfDue())
        #expect(storage.object(forKey: ReviewPromptLedger.promptedVersionKey) == nil)
        let atDay7 = ledger(storage: storage, now: epoch.addingTimeInterval(86400 * 7))
        #expect(atDay7.daysSinceLastCrash == 3)
        #expect(atDay7.consumePromptIfDue())
    }

    @Test("no crash on record reads as nil, not as day zero")
    func noCrashIsNil() {
        let storage = MemoryStorage()
        #expect(ledger(storage: storage).daysSinceLastCrash == nil)
    }

    @Test("an older crash delivered again never moves the stamp back")
    func olderCrashKeepsTheNewerStamp() {
        let storage = MemoryStorage()
        let led = ledger(storage: storage, now: epoch.addingTimeInterval(86400 * 10))
        led.recordCrash(at: epoch.addingTimeInterval(86400 * 9))
        led.recordCrash(at: epoch.addingTimeInterval(86400 * 2))
        #expect(led.daysSinceLastCrash == 1)
    }

    @Test("a crash dated in the future is held at now, so a bad clock cannot stretch the quiet")
    func futureCrashClampsToNow() {
        let storage = MemoryStorage()
        let led = ledger(storage: storage, now: epoch)
        led.recordCrash(at: epoch.addingTimeInterval(86400 * 30))
        #expect(led.daysSinceLastCrash == 0)
        let later = ledger(storage: storage, now: epoch.addingTimeInterval(86400 * 3))
        #expect(later.daysSinceLastCrash == 3)
    }

    @Test("a stored stamp after now (the clock was ahead, then fixed) is no crash on record, and the next one replaces it")
    func storedFutureStampIsDiscarded() {
        let storage = MemoryStorage()
        storage.set(epoch.addingTimeInterval(86400 * 365).timeIntervalSince1970, forKey: ReviewPromptLedger.lastCrashKey)
        let led = ledger(storage: storage, now: epoch)
        #expect(led.daysSinceLastCrash == nil, "a year of silence is not the price of a bad clock")
        led.recordCrash(at: epoch.addingTimeInterval(-86400))
        #expect(led.daysSinceLastCrash == 1)
    }

    @Test("suppressed (screengrab harness): a crash records nothing")
    func suppressedRecordsNoCrash() {
        let storage = MemoryStorage()
        let led = ledger(storage: storage, suppressed: true)
        led.recordCrash(at: epoch)
        #expect(storage.values.isEmpty)
        #expect(led.daysSinceLastCrash == nil)
    }

    @Test("the marketing version falls back to 0 when the bundle carries none")
    func marketingVersionFallback() throws {
        // A bare directory is a Bundle with no Info.plist — the fallback path.
        let bare = try #require(Bundle(path: NSTemporaryDirectory()))
        #expect(ReviewPromptLedger.marketingVersion(from: bare) == "0")
        #expect(ReviewPromptLedger.marketingVersion(from: .main).isEmpty == false)
    }
}
