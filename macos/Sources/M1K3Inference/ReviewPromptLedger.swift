//
//  ReviewPromptLedger.swift
//  M1K3Inference
//
//  The facts behind the rating ask — first-use stamp, the two engagement
//  counters, the once-per-version mark — persisted through a two-method
//  storage seam that UserDefaults satisfies as-is and a dictionary satisfies
//  in tests. Both shells (Mac AppEnvironment, iOS AppCore) own one ledger;
//  the views observe its counters and, when a prompt is due, call SwiftUI's
//  `requestReview` themselves — the ask must only ever be CONSUMED where a
//  window can show it (a headless MCP turn or the menu-bar popover must not
//  spend the version's one chance on a dialog nobody sees).
//
//  `suppressed` is the screengrab harness (App Store plates): under it the
//  ledger stamps, counts and prompts NOTHING. The harness reroutes every
//  store to a sibling root but not UserDefaults.standard, so a demo run
//  would otherwise inflate the real user's counters — the guard is on every
//  write, not just the prompt.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-15, Confidence 0.9. Prior: none
//  (new file; Cartogram's ReviewPrompter, with the storage seam and the
//  suppression added).

import Foundation
import Observation

/// What the ledger needs from its store. `UserDefaults` conforms unchanged.
public protocol ReviewPromptStorage: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: ReviewPromptStorage {}

@MainActor
@Observable
public final class ReviewPromptLedger {
    public static let firstUseKey = "review.firstUse"
    public static let delightKey = "review.delightCount"
    public static let turnsKey = "review.completedTurns"
    public static let promptedVersionKey = "review.promptedVersion"

    /// Liked answers so far (mirrors storage; views observe this).
    public private(set) var delightCount: Int
    /// Successful answers so far (mirrors storage; views observe this).
    public private(set) var completedTurns: Int
    /// The marketing version this ledger asks for.
    public let currentVersion: String

    private let storage: ReviewPromptStorage
    private let suppressed: () -> Bool
    private let now: () -> Date
    private let calendar: Calendar

    /// Stamps first use on the first construction that is not suppressed;
    /// a returning user's stamp is never overwritten.
    public init(
        storage: ReviewPromptStorage,
        version: String,
        suppressed: @escaping () -> Bool = { false },
        now: @escaping () -> Date = { Date() },
        calendar: Calendar = .current
    ) {
        self.storage = storage
        currentVersion = version
        self.suppressed = suppressed
        self.now = now
        self.calendar = calendar
        delightCount = storage.object(forKey: Self.delightKey) as? Int ?? 0
        completedTurns = storage.object(forKey: Self.turnsKey) as? Int ?? 0
        if !suppressed(), storage.object(forKey: Self.firstUseKey) == nil {
            storage.set(now().timeIntervalSince1970, forKey: Self.firstUseKey)
        }
    }

    /// A liked answer — the strongest signal the user has an opinion.
    public func recordDelight() {
        guard !suppressed() else { return }
        delightCount += 1
        storage.set(delightCount, forKey: Self.delightKey)
    }

    /// A successful answer.
    public func recordCompletedTurn() {
        guard !suppressed() else { return }
        completedTurns += 1
        storage.set(completedTurns, forKey: Self.turnsKey)
    }

    /// Whole calendar days since the first recorded use; 0 when there is no
    /// stamp; negative when the stamp is in the future (broken state).
    /// Calendar days, not 72 hours, on purpose: "three days" means three
    /// dates on the user's calendar, DST and all — the honeymoon is a
    /// feeling, not a stopwatch.
    public var daysSinceFirstUse: Int {
        guard let stamp = storage.object(forKey: Self.firstUseKey) as? Double else { return 0 }
        let firstUse = Date(timeIntervalSince1970: stamp)
        return calendar.dateComponents([.day], from: firstUse, to: now()).day ?? 0
    }

    /// True when the policy says a prompt is due NOW. Marks this version as
    /// asked as a side effect, so the one call site can pass the result
    /// straight to `requestReview` — the system may still decline to show
    /// the dialog, and that quota-limited chance is spent either way.
    public func consumePromptIfDue() -> Bool {
        guard !suppressed() else { return false }
        let due = ReviewPromptPolicy.shouldPrompt(
            delightCount: delightCount,
            completedTurns: completedTurns,
            daysSinceFirstUse: daysSinceFirstUse,
            lastPromptedVersion: storage.object(forKey: Self.promptedVersionKey) as? String,
            currentVersion: currentVersion
        )
        if due { storage.set(currentVersion, forKey: Self.promptedVersionKey) }
        return due
    }

    /// The bundle's marketing version, "0" when the bundle carries none —
    /// the shells' four inline reads of this key predate the ledger; this is
    /// the one they can share.
    public nonisolated static func marketingVersion(from bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}
