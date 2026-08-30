//
//  HeartbeatPrompt.swift
//  M1K3Heartbeat
//
//  Builds the narrative-render prompt for the resident MLX brain. The render
//  runs as a bare generate — no persona seed, no tools, no retrieval — so
//  the prompt carries the register itself. That's deliberate and safe here:
//  the #98 identity-leak class was a per-turn line FIGHTING a seeded
//  persona; a bare generate has no persona to fight. The digest is the only
//  source of truth; the add-nothing rule plus NarrativeGuard bound the rest.
//  House noun: the machine, never the Mac (platform-honesty ruling).
//
//  Signed: Kev + claude-fable-5, 2026-08-06, Confidence 0.85 (string
//  contract pinned by tests; prompt EFFECTIVENESS on Big/Lil is a named
//  verify-owed on-device run — gemma is prompt-fragile, A/B before trusting).
//  Prior: none (new file).
//  Review: Kev + claude-fable-5, 2026-08-30, Confidence 0.85 — the register
//  rules from six live days (HEARTBEAT_DESIGN addendum, fixes 2/4/7): lead
//  with the news, the brain is a tool never a companion, report what
//  happened without claiming work or editorialising numbers; plus the
//  anti-repetition openers section fed from the last pulses ACROSS the
//  midnight boundary (fix 5 — the day-scoped arc had nothing to continue,
//  every day). String contract pinned; effectiveness stays the named A/B.
//

import Foundation

public enum HeartbeatPrompt {
    /// The full prompt for one narrative render.
    ///
    /// `earlierToday` threads the day's arc (narratives, oldest first).
    /// `recentPulses` is anti-repetition material — the last few pulses
    /// regardless of day, quoted by OPENER only, with a plain don't-open-
    /// like-these rule. On a quiet day the arc is empty by construction
    /// (the store's day window resets at midnight), so the openers are the
    /// only thing standing between three days and one sentence.
    public static func render(
        digest: String,
        earlierToday: [String],
        recentPulses: [String] = []
    ) -> String {
        var sections: [String] = []
        sections.append(
            """
            You are M1K3, a private machine-resident companion, writing a short \
            heartbeat note about what's been happening on this machine. Warm, dry, \
            brief — two to four sentences of plain prose, first person.

            Retell ONLY the facts in the digest below. Do not add facts, numbers, \
            events, or guesses. Lead with the news; mention the ambient machine \
            state only if it changed or there is no news. The brain named in the \
            digest is what you think with — never a companion. Report what \
            happened; never claim you did work, and never dress a number up as \
            an observation. Do not use markdown, lists, or headings.
            """
        )
        if !earlierToday.isEmpty {
            let arc = earlierToday.map { "- \($0)" }.joined(separator: "\n")
            sections.append(
                """
                Earlier today you wrote (oldest first) — continue the day's thread, \
                don't repeat it:
                \(arc)
                """
            )
        }
        if !recentPulses.isEmpty {
            let openers = recentPulses.map { "- \"\(opener(of: $0))\"" }.joined(separator: "\n")
            sections.append(
                """
                Your recent notes opened with these lines. Do not open like them — \
                find a different first sentence:
                \(openers)
                """
            )
        }
        sections.append(
            """
            Digest:
            \(digest)

            Heartbeat note:
            """
        )
        return sections.joined(separator: "\n\n")
    }

    /// The opening excerpt of a pulse: up to the first clause boundary, capped
    /// at eight words. The openers section quotes only this — the tail of an
    /// old pulse is repetition fuel, not guidance.
    static func opener(of pulse: String, maxWords: Int = 8) -> String {
        let trimmed = pulse.trimmingCharacters(in: .whitespacesAndNewlines)
        let clause = trimmed.prefix { !".;!?\n…".contains($0) }
        let words = clause.split(separator: " ", omittingEmptySubsequences: true)
        return words.prefix(maxWords).joined(separator: " ")
    }
}
