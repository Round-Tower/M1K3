//
//  StreamingReasoningSplitter.swift
//  M1K3Chat
//
//  The live counterpart to ReasoningSplit: routes streamed chunks to reasoning
//  vs answer AS THEY ARRIVE, so a reasoning model's chain-of-thought renders in
//  the disclosure in real time — the user sees the model working within a
//  second instead of staring at a silent bubble for the whole think phase.
//
//  Handles both provider stream contracts (cumulative snapshots à la Apple
//  Foundation Models, plain deltas from MLX) with the same normalise-to-delta
//  rule as ChatSession.fold, tags split across chunk boundaries (a small
//  holdback window, same trick as ConclusionStreamSplitter), and Qwen3.5's
//  lone `</think>` (the template pre-opens the tag) via a retro-move of the
//  accumulated text into reasoning. The post-stream ReasoningSplit over `raw`
//  remains the final authority; this struct only drives the live rendering.
//
//  Signed: Kev + claude-fable-5, 2026-06-10, Confidence 0.85, Prior: Unknown
//  Review: Kev + claude-fable-5, 2026-07-02 — snapshot-vs-delta normalisation
//  delegated to M1K3Inference.StreamFold (was one of three inlined copies).
//  Review: Kev + claude-fable-5.1, 2026-09-30 — drops gemma's stray media tokens
//  live (ReasoningSplit.strayTokens, one list): voice folds sentences out of
//  `answer` before the post-stream pass, so "a<image|>sweat" would have been
//  spoken. Held back while incomplete, like the tags; a token at the buffer's
//  end settles its word gap on the next chunk. Known, accepted: two spaces
//  before a token, or a reasoning tag between word and token, can leave the
//  live text one space off the final (the final pass owns the bubble; the
//  difference is inaudible). Confidence 0.85.
//

import Foundation
import M1K3Inference

struct StreamingReasoningSplitter {
    /// Chain-of-thought routed out so far (live view of the disclosure).
    private(set) var reasoning = ""
    /// Answer text routed out so far (live view of the bubble).
    private(set) var answer = ""
    /// The unsplit accumulated stream — feed this to the post-stream
    /// ReasoningSplit/CitationValidator pass as the single source of truth.
    private(set) var raw = ""

    private enum Mode {
        /// Start state: could still open with `<think>`.
        case scanning
        /// Inside a think block, watching for the close tag.
        case reasoning
        /// Plain text so far, but a lone `</think>` may still arrive (Qwen3.5).
        case answerWatching
        /// At least one think block closed — answer text, but a NEW `<think>`
        /// (the next agent iteration's reasoning) routes back to the disclosure.
        case answer
    }

    private var mode: Mode = .scanning
    private var buffer = ""
    /// Set when a new think block begins after one already closed, so blocks
    /// join with a blank line (matches ReasoningSplit's joined output).
    private var pendingReasoningSeparator = false
    /// A stray token was dropped from between a word and the end of the buffer:
    /// if the next chunk opens with a letter, the token stood where a space was.
    private var owesWordGap = false

    // Both reasoning formats we recognise, shared with ReasoningSplit so the
    // live and post-stream authorities can't drift: Qwen `<think>…</think>` and
    // gemma-4 `<|channel>thought … <channel|>`.
    private static let openTags = ReasoningSplit.openTags
    private static let closeTags = ReasoningSplit.closeTags
    /// gemma's stray media tokens: dropped live, because voice speaks sentences
    /// from `answer` before the post-stream pass; held back while incomplete.
    private static let strayTokens = ReasoningSplit.strayTokens

    /// Feed one raw stream chunk (delta or cumulative snapshot).
    mutating func feed(_ chunk: String) {
        // Normalise cumulative snapshots to deltas (StreamFold's shared rule).
        let delta = StreamFold.delta(current: raw, chunk: chunk)
        raw += delta
        if owesWordGap, let first = delta.first {
            if ReasoningSplit.isWordCharacter(first) { buffer += " " }
            owesWordGap = false
        }
        buffer += delta
        process()
    }

    /// Release any held-back tail once the stream is over.
    mutating func finish() {
        process()
        switch mode {
        case .reasoning:
            appendReasoning(buffer)
        case .scanning, .answerWatching, .answer:
            appendAnswer(buffer)
        }
        buffer = ""
    }

    private mutating func process() {
        var advanced = true
        while advanced {
            advanced = false
            dropStrayTokens()
            switch mode {
            case .scanning:
                buffer = String(buffer.drop(while: \.isWhitespace))
                if let matched = Self.openTags.first(where: { buffer.hasPrefix($0) }) {
                    buffer.removeFirst(matched.count)
                    mode = .reasoning
                    advanced = true
                } else if !buffer.isEmpty, !Self.openTags.contains(where: { $0.hasPrefix(buffer) }) {
                    mode = .answerWatching
                    advanced = true
                }

            case .reasoning:
                if let close = Self.earliest(of: Self.closeTags, in: buffer) {
                    appendReasoning(String(buffer[..<close.lowerBound]))
                    // The block closed: trim trailing whitespace so the live view
                    // matches the post-stream authority (gemma-4 emits "\n" right
                    // before <channel|>; a later block re-adds its own separator).
                    reasoning = trimTrailingWhitespace(reasoning)
                    buffer = String(buffer[close.upperBound...])
                    mode = .answer
                    advanced = true
                } else {
                    appendReasoning(takeAllButHoldback(guarding: Self.closeTags + Self.strayTokens))
                }

            case .answerWatching:
                let close = Self.earliest(of: Self.closeTags, in: buffer)
                let open = Self.earliest(of: Self.openTags, in: buffer)
                if let close, Self.comesFirst(close, before: open) {
                    // Lone close with no open: the template opened the block
                    // for us — everything emitted so far was reasoning.
                    let before = String(buffer[..<close.lowerBound])
                    reasoning = trimTrailingWhitespace(answer + before)
                    answer = ""
                    buffer = String(buffer[close.upperBound...])
                    mode = .answer
                    advanced = true
                } else if let open {
                    appendAnswer(String(buffer[..<open.lowerBound]))
                    buffer = String(buffer[open.upperBound...])
                    beginReasoningBlock()
                    mode = .reasoning
                    advanced = true
                } else {
                    appendAnswer(takeAllButHoldback(guarding: Self.closeTags + Self.openTags + Self.strayTokens))
                }

            case .answer:
                if let open = Self.earliest(of: Self.openTags, in: buffer) {
                    appendAnswer(String(buffer[..<open.lowerBound]))
                    buffer = String(buffer[open.upperBound...])
                    beginReasoningBlock()
                    mode = .reasoning
                    advanced = true
                } else {
                    appendAnswer(takeAllButHoldback(guarding: Self.openTags + Self.strayTokens))
                }
            }
        }
    }

    /// Strip complete stray tokens from the buffer, with the same word-spacing rule
    /// as the post-stream pass (the character emitted before the buffer supplies
    /// the left context). A token at the buffer's end can't yet know whether a
    /// word follows; it goes now and the space it may owe is settled by `feed`.
    private mutating func dropStrayTokens() {
        guard Self.earliest(of: Self.strayTokens, in: buffer) != nil else { return }
        let previous = mode == .reasoning ? reasoning.last : answer.last
        let tail = String(buffer.reversed().drop { $0 == " " }.reversed())
        let endsWithToken = Self.strayTokens.contains { tail.hasSuffix($0) }
        buffer = ReasoningSplit.removingStrayTokens(from: buffer, precededBy: previous)
        if endsWithToken {
            // Judged AFTER the strip, so a run of adjacent tokens and the spaces the
            // strip collapses are both gone: "a <image|><audio|>" + "sweat" → "a sweat".
            let beforeTokens = buffer.last { $0 != " " } ?? previous
            owesWordGap = beforeTokens.map(ReasoningSplit.isWordCharacter) == true
        }
    }

    /// True when `close` precedes `open` (or there is no open at all) — the
    /// lone-close rule, without a force-unwrap at the call site.
    private static func comesFirst(
        _ close: Range<String.Index>, before open: Range<String.Index>?
    ) -> Bool {
        guard let open else { return true }
        return close.lowerBound < open.lowerBound
    }

    /// The earliest occurrence of ANY of `tags` in `text` (soonest start wins).
    /// Mirrors ReasoningSplit.earliestRange so live and post-stream agree.
    private static func earliest(of tags: [String], in text: String) -> Range<String.Index>? {
        var best: Range<String.Index>?
        for tag in tags {
            guard let r = text.range(of: tag) else { continue }
            if best == nil || r.lowerBound < best!.lowerBound {
                best = r
            }
        }
        return best
    }

    /// Drain the buffer except the longest tail that could still be the start
    /// of one of the watched tags — keeps a dangling half-tag out of the output.
    private mutating func takeAllButHoldback(guarding tags: [String]) -> String {
        var keep = 0
        for tag in tags {
            let maxKeep = min(buffer.count, tag.count - 1)
            guard maxKeep > 0 else { continue }
            for length in stride(from: maxKeep, through: 1, by: -1) {
                if length > keep, buffer.hasSuffix(tag.prefix(length)) {
                    keep = length
                    break
                }
            }
        }
        let emitted = String(buffer.dropLast(keep))
        buffer = String(buffer.suffix(keep))
        return emitted
    }

    /// A think block is opening after one already closed (the next agent
    /// iteration): join blocks with a blank line, like ReasoningSplit does.
    private mutating func beginReasoningBlock() {
        if !reasoning.isEmpty { pendingReasoningSeparator = true }
    }

    private mutating func appendReasoning(_ text: String) {
        var piece = text
        if reasoning.isEmpty || pendingReasoningSeparator {
            piece = String(piece.drop(while: \.isWhitespace))
        }
        guard !piece.isEmpty else { return }
        if pendingReasoningSeparator {
            reasoning += "\n\n"
            pendingReasoningSeparator = false
        }
        reasoning += piece
    }

    private mutating func appendAnswer(_ text: String) {
        var piece = text
        if answer.isEmpty { piece = String(piece.drop(while: \.isWhitespace)) }
        answer += piece
    }

    private func trimTrailingWhitespace(_ text: String) -> String {
        var trimmed = text
        while let last = trimmed.last, last.isWhitespace {
            trimmed.removeLast()
        }
        return trimmed
    }
}
