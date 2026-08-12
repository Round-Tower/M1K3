//
//  ReasoningSplit.swift
//  M1K3Inference
//
//  Reasoning models emit their chain-of-thought before the answer, in one of two
//  formats we know about:
//    • Qwen3 and friends: `<think>…</think>`
//    • gemma-4 (Big): `<|channel>thought … <channel|>` (asymmetric markers — the
//      pipe flips sides; its chat_template's strip_thinking macro removes exactly
//      this). Without this the whole thought channel leaks into the bubble.
//  We separate the reasoning from the answer so the bubble shows a clean reply
//  while the thinking is surfaced one tap away — transparency without clutter.
//
//  Review: Kev + claude-opus-4-8, 2026-06-13, Confidence 0.9 — generalised from a
//  single `<think>` pair to a set of open/close tag pairs to also strip gemma-4's
//  channel-format reasoning (Big leaked its full thought trace into the UI).
//  Prior: Kev + claude-opus-4-8, 2026-06-10 (this file)

import Foundation

public enum ReasoningSplit {
    /// Open/close tag pairs we recognise as a reasoning block, longest-first so a
    /// channel open is matched before any accidental substring. Shared with the
    /// streaming splitter so live and post-stream views agree.
    public static let openTags = ["<|channel>thought", "<think>"]
    public static let closeTags = ["<channel|>", "</think>"]

    /// Separate chain-of-thought from the answer. Returns the joined reasoning
    /// (nil if none) and the answer with the think blocks removed. An unclosed
    /// open tag (a stream cut mid-thought) treats the rest as reasoning; a lone
    /// close with no opening tag (the chat template pre-opens the block in the
    /// prompt, so the model emits only the close) treats the prefix as reasoning.
    /// Both parts are whitespace-trimmed.
    public static func split(_ text: String) -> (reasoning: String?, answer: String) {
        var reasoningParts: [String] = []
        var answer = ""
        var remaining = Substring(text)

        // Lone closing tag first: the close appears before any open (or with no
        // open at all) → everything up to it is reasoning the template opened
        // for us. Later tags are then handled by the normal pair loop.
        if let close = earliestRange(of: closeTags, in: remaining) {
            let open = earliestRange(of: openTags, in: remaining)
            let closeComesFirst = open.map { close.lowerBound < $0.lowerBound } ?? true
            if closeComesFirst {
                reasoningParts.append(String(remaining[..<close.lowerBound]))
                remaining = remaining[close.upperBound...]
            }
        }

        while let open = earliestRange(of: openTags, in: remaining) {
            answer += remaining[..<open.lowerBound]
            let afterOpen = remaining[open.upperBound...]
            if let close = earliestRange(of: closeTags, in: afterOpen) {
                reasoningParts.append(String(afterOpen[..<close.lowerBound]))
                remaining = afterOpen[close.upperBound...]
            } else {
                // Unclosed: everything after the opening tag is reasoning.
                reasoningParts.append(String(afterOpen))
                remaining = ""
                break
            }
        }
        answer += remaining

        let reasoning = reasoningParts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return (
            reasoning.isEmpty ? nil : reasoning,
            answer.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// The earliest occurrence of ANY of `tags` in `text` — the tag whose match
    /// starts soonest wins (ties broken by tag order, longest-first).
    static func earliestRange(of tags: [String], in text: Substring) -> Range<String.Index>? {
        var earliest: Range<String.Index>?
        for tag in tags {
            guard let r = text.range(of: tag) else { continue }
            if earliest == nil || r.lowerBound < earliest!.lowerBound {
                earliest = r
            }
        }
        return earliest
    }
}
