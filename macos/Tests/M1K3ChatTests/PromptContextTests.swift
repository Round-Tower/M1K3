//
//  PromptContextTests.swift
//  M1K3ChatTests
//
//  The per-turn "what's true right now" grounding line: the precise date (so the
//  model can state the weekday/day the cached month+year persona can't) and which
//  brain is answering (mini/lil/big share one persona).
//
//  Signed: Kev + claude-opus-4-8, 2026-06-21, Confidence 0.85. Prior: this file.

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

    @Test("English month names regardless of host locale")
    func stableEnglishMonth() {
        let line = PromptContext.line(now: noon(2026, 1, 1), brainName: "Mini M1K3")
        #expect(line.contains("January"))
    }
}
