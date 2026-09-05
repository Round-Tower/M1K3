//
//  StarterPrompts.swift
//  M1K3Chat
//
//  The blank-canvas chips. Three fixed strings read as furniture after the
//  second launch; now the chips are drawn from a pool, shuffled per visit, with
//  up to two woven from the user's most recent memories so the canvas says
//  "I remember" before a word is typed (Kev, QA pass 2026-09-05, item 10). Pure:
//  the shell passes recent memory titles and a generator; the tests pass a
//  seeded one.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-05, Confidence 0.85 (pinned by
//  StarterPromptsTests; the pool copy is a taste call). Prior: none (new file).
//

import Foundation

public enum StarterPrompts {
    /// Chips must stay one line on a phone.
    public static let maxChipLength = 44

    /// At most this many chips come from memories; the rest from the pool.
    public static let maxMemoryChips = 2

    public static let pool: [String] = [
        "What can you help me with?",
        "Explain something simply",
        "What do you remember about me?",
        "Give me a two-minute plan for today",
        "Teach me one new word",
        "Help me think through a decision",
        "Summarise what's on my mind",
        "Tell me something surprising",
        "Draft a short message for me",
        "Quiz me on something I know",
    ]

    /// Three chips: up to two from `memoryTitles` (newest first, blanks skipped,
    /// long titles trimmed), the rest a shuffle of the pool. Never duplicates.
    /// `count` beyond the pool + memory chips returns what exists, no repeats.
    public static func pick(
        memoryTitles: [String],
        count: Int = 3,
        using rng: inout some RandomNumberGenerator
    ) -> [String] {
        // Dedupe AFTER trimming to chip form: two memories with the same title,
        // or two long titles that collide once truncated, must not print twice.
        var picks: [String] = []
        for title in memoryTitles where picks.count < min(maxMemoryChips, count) {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let chip = memoryChip(trimmed)
            if !picks.contains(chip) { picks.append(chip) }
        }
        for prompt in pool.shuffled(using: &rng) where picks.count < count {
            if !picks.contains(prompt) { picks.append(prompt) }
        }
        return picks.shuffled(using: &rng)
    }

    private static func memoryChip(_ title: String) -> String {
        let lead = "Remind me about "
        let room = maxChipLength - lead.count - 1
        guard title.count > room else { return lead + title }
        return lead + title.prefix(room).trimmingCharacters(in: .whitespaces) + "…"
    }
}
