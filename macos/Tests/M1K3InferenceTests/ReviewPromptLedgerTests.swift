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
        let dayThree = ledger(storage: storage, now: epoch.addingTimeInterval(86400 * 3))
        dayThree.recordDelight()
        dayThree.recordDelight()
        #expect(dayThree.consumePromptIfDue())
        #expect(storage.object(forKey: ReviewPromptLedger.promptedVersionKey) as? String == "1.0.1")
        #expect(!dayThree.consumePromptIfDue())
        let nextRelease = ledger(storage: storage, version: "1.1", now: epoch.addingTimeInterval(86400 * 40))
        #expect(nextRelease.consumePromptIfDue())
        #expect(storage.object(forKey: ReviewPromptLedger.promptedVersionKey) as? String == "1.1")
    }

    @Test("the honeymoon holds even with the engagement in hand")
    func honeymoonHolds() {
        let storage = MemoryStorage()
        let dayTwo = ledger(storage: storage, now: epoch)
        dayTwo.recordDelight()
        dayTwo.recordDelight()
        let later = ledger(storage: storage, now: epoch.addingTimeInterval(86400 * 2 + 3600))
        #expect(later.daysSinceFirstUse == 2)
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

    @Test("the marketing version falls back to 0 when the bundle carries none")
    func marketingVersionFallback() throws {
        // A bare directory is a Bundle with no Info.plist — the fallback path.
        let bare = try #require(Bundle(path: NSTemporaryDirectory()))
        #expect(ReviewPromptLedger.marketingVersion(from: bare) == "0")
        #expect(ReviewPromptLedger.marketingVersion(from: .main).isEmpty == false)
    }
}
