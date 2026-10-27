//
//  UserStyleBlock.swift
//  M1K3Inference
//
//  #699 Phase 1: the text of the persona's style line, rendered from the user's
//  `.style` memories newest first (the app reads them from the graph; this target has
//  no dependencies, so it takes plain strings). Pure, so the order and the cap are
//  pinned in UserStyleBlockTests.
//
//  Whole facts, newest first, joined as sentences, inside the cap. The block ends at
//  the first fact that would cross it: an older ask never leapfrogs a newer one that
//  did not fit, because the older is often exactly what the newer corrected (a
//  correction under the embedder's twin bar retires its ask only on an axis StyleAxis
//  can place; otherwise both rows stay live, and the order is what the model reads).
//  The newest fact is never lost: alone over the cap it is cut at a word boundary with
//  an ellipsis, the About block's own rule.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85, Prior: none (new file)
//  Review: Kev + claude-opus-5.5, 2026-10-27 (pre-push review fold) — a cut that lands exactly on a word end
//  keeps that word ("aaa bbb ccc" at 8 was "aaa…", now "aaa bbb…"); the boundaries are pinned exactly.
//  Confidence 0.9.
//  Review: Kev + claude-opus-5.5, 2026-10-27 — comment only: since the axis supersede (StyleAxis), a same-axis
//  correction retires its ask, so both rows stay live only off the axes the table places. Confidence 0.9.
//

import Foundation

public enum UserStyleBlock {
    /// The style line's text, or nil when there is nothing to say.
    public static func render(newestFirst facts: [String], cap: Int) -> String? {
        let sentences = facts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map(sentence)
        guard let newest = sentences.first, cap > 0 else { return nil }
        guard newest.count <= cap else { return cutAtAWord(newest, cap: cap) }
        var block = newest
        for next in sentences.dropFirst() {
            guard block.count + 1 + next.count <= cap else { break }
            block += " " + next
        }
        return block
    }

    /// A fact as a sentence: a full stop added when it has no closing punctuation.
    static func sentence(_ fact: String) -> String {
        guard let last = fact.last, !".!?…".contains(last) else { return fact }
        return fact + "."
    }

    /// `text` cut to fit `cap` with its ellipsis, at the last word boundary that fits. When the
    /// room ends exactly at a word end (the next character is a space) the whole room is kept.
    static func cutAtAWord(_ text: String, cap: Int) -> String {
        let room = String(text.prefix(max(cap - 1, 0)))
        let endsAWord = text.dropFirst(room.count).first?.isWhitespace ?? true
        let atWord = endsAWord ? room : room.lastIndex(of: " ").map { String(room[..<$0]) } ?? room
        return atWord.trimmingCharacters(in: .whitespaces) + "…"
    }
}
