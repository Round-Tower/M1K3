//
//  PromptContextTests.swift
//  M1K3ChatTests
//
//  The per-turn "what's true right now" grounding line: the precise date (so the
//  model can state the weekday/day the cached month+year persona can't) and which
//  brain is answering (mini/lil/big share one persona).
//
//  Signed: Kev + claude-opus-4-8, 2026-06-21, Confidence 0.85. Prior: this file.
//  Review: Kev + claude-opus-5-5, 2026-09-27 — `identity(brainName:)`, the date-free line Mini's
//  plain turn takes (#428/#349). Confidence 0.85.
//  Review: Kev + claude-fable-5.1, 2026-10-09 — #488: the line carries the ISO date and the
//  "earlier dates are in the past" cue, placed before the brain clause. Confidence 0.8.

import Foundation
@testable import M1K3Chat
import Testing

struct PromptContextTests {
    /// Noon-local on a fixed day, so the formatted calendar date can't flip across
    /// a time-zone boundary the way a midnight instant would.
    private func noon(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    @Test("carries the precise date — weekday, day, month, year")
    func preciseDate() {
        let when = noon(2026, 6, 21)
        let line = PromptContext.line(now: when, brainName: "Lil M1K3")
        // Independent weekday with the same locale, so the test never hardcodes one.
        let weekdayFmt = DateFormatter()
        weekdayFmt.locale = Locale(identifier: "en_US_POSIX")
        weekdayFmt.dateFormat = "EEEE"
        #expect(line.contains(weekdayFmt.string(from: when)))
        #expect(line.contains("21 June 2026"))
    }

    @Test("names the active brain")
    func namesBrain() {
        let line = PromptContext.line(now: noon(2026, 6, 21), brainName: "Lil M1K3")
        #expect(line.contains("Lil M1K3"))
    }

    /// The brain name is what M1K3 THINKS WITH, never what it IS.
    ///
    /// The live value is `BrainTier.displayName` — bare "Mini" / "Lil" / "Big",
    /// not the friendlier "Lil M1K3" this suite's other fixture uses, which is
    /// why the phrasing was never caught here. In production the line read
    /// "you're Mini", and interviewing Mini over MCP on 2026-08-03 it duly
    /// introduced itself:
    ///
    ///     "I'm Mini, an AI living on this Mac, here to help with any
    ///      questions you might have."
    ///
    /// A tier name is internal vocabulary; the user has never heard of it. This
    /// is the same failure as the per-turn "private local assistant" line in
    /// #97 — a second identity stated closer to the question than the persona,
    /// so it wins.
    @Test(
        "the brain clause never renames M1K3",
        arguments: ["Mini", "Lil", "Big"]
    )
    func brainNameIsNotAnIdentity(brain: String) {
        let line = PromptContext.line(now: noon(2026, 6, 21), brainName: brain)
        // Still answers "which model are you?" honestly…
        #expect(line.contains(brain))
        // …but M1K3 is who it is, on every tier.
        #expect(line.contains("M1K3"))
        #expect(!line.contains("you're \(brain)"))
        #expect(!line.contains("You're \(brain)"))
    }

    @Test("empty brain name omits the brain clause but keeps the date")
    func emptyBrainKeepsDate() {
        let line = PromptContext.line(now: noon(2026, 6, 21), brainName: "")
        #expect(line.contains("21 June 2026"))
        #expect(!line.lowercased().contains("you're"))
    }

    @Test("whitespace-only brain name is treated as empty")
    func blankBrainIsEmpty() {
        let line = PromptContext.line(now: noon(2026, 6, 21), brainName: "   ")
        #expect(!line.lowercased().contains("you're"))
    }

    /// #428/#349 (2026-09-27): on Mini's plain turn the date line was the one concrete thing
    /// in the prompt, and small talk opened on it ("Sunday, 27 September 2026 — …") 11/16,
    /// or pinned it on the user ("You mentioned Sunday, 27 September 2026"). The plain turn
    /// takes the identity alone.
    @Test("the identity line names the brain and carries no date")
    func identityHasNoDate() {
        let line = PromptContext.identity(brainName: "Mini M1K3")
        #expect(line.contains("Mini M1K3"))
        #expect(line.hasPrefix("You're M1K3"))
        #expect(!line.contains("Right now"))
        #expect(PromptContext.line(now: noon(2026, 6, 21), brainName: "Mini M1K3").hasSuffix(line))
    }

    @Test("a blank brain gives no identity line")
    func blankIdentityIsEmpty() {
        #expect(PromptContext.identity(brainName: "  ").isEmpty)
    }

    @Test("English month names regardless of host locale")
    func stableEnglishMonth() {
        let line = PromptContext.line(now: noon(2026, 1, 1), brainName: "Mini M1K3")
        #expect(line.contains("January"))
    }

    /// #488 (2026-10-05): Big (gemma-4-12B) read "it's Monday, 5 October 2026" beside a
    /// memory's "On 2026-10-02 …" and called 2 October the future ("that date hasn't
    /// happened yet — today is only October 5th"). Two different shapes of the same
    /// kind of thing, ordered by eye. The line now carries the ISO date as well (the
    /// shape memories and tool outputs use) and says the ordering rule outright.
    @Test("carries the ISO date and the past-dates cue (#488)")
    func isoDateAndPastCue() {
        let line = PromptContext.line(now: noon(2026, 10, 5), brainName: "Big")
        #expect(line.contains("5 October 2026 (2026-10-05)"))
        #expect(line.contains("earlier dates are in the past"))
    }

    @Test("the ISO date is zero-padded")
    func isoDateZeroPadded() {
        let line = PromptContext.line(now: noon(2026, 1, 1), brainName: "")
        #expect(line.contains("(2026-01-01)"))
    }

    /// Mini's DISPATCHED turn (a tool result in hand, `brainName: ""`) carries the line too —
    /// decided 2026-10-09, not gated to the MLX tiers: the observation is where the ISO dates
    /// live (recent_activity, calendar, memories), so that turn is where the cue earns its
    /// keep. The cost is bounded here so it stays a rounding error of Mini's 4,096 window.
    @Test("the dispatched-turn line (no brain) carries both date shapes and the cue, under budget")
    func dispatchedTurnLineCarriesTheCueUnderBudget() {
        let line = PromptContext.line(now: noon(2026, 10, 5), brainName: "")
        #expect(line.contains("Monday, 5 October 2026 (2026-10-05)"))
        #expect(line.hasSuffix("earlier dates are in the past."))
        let words = line.split(whereSeparator: \.isWhitespace).count
        #expect(words <= 20, "the date clause is ~14 tokens on every dated turn; got \(words) words")
    }

    /// The cue is part of the DATE clause: it precedes the brain clause (which stays the
    /// line's suffix, `identityHasNoDate`) and closes the line when there is no brain.
    @Test("the cue sits between the date and the brain clause")
    func cuePrecedesIdentity() throws {
        let line = PromptContext.line(now: noon(2026, 10, 5), brainName: "Big")
        let cue = try #require(line.range(of: "earlier dates are in the past."))
        let identity = try #require(line.range(of: "You're M1K3"))
        #expect(cue.upperBound <= identity.lowerBound)
        #expect(PromptContext.line(now: noon(2026, 10, 5), brainName: "").hasSuffix("earlier dates are in the past."))
    }
}
