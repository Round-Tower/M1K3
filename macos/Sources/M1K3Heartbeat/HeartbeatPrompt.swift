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
//

import Foundation

public enum HeartbeatPrompt {
    /// The full prompt for one narrative render.
    public static func render(digest: String, earlierToday: [String]) -> String {
        var sections: [String] = []
        sections.append(
            """
            You are M1K3, a private machine-resident companion, writing a short \
            heartbeat note about what's been happening on this machine. Warm, dry, \
            brief — two to four sentences of plain prose, first person.

            Retell ONLY the facts in the digest below. Do not add facts, numbers, \
            events, or guesses. Do not use markdown, lists, or headings.
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
        sections.append(
            """
            Digest:
            \(digest)

            Heartbeat note:
            """
        )
        return sections.joined(separator: "\n\n")
    }
}
