//
//  HistoryWindow.swift
//  M1K3Chat
//
//  Chat memory: until M1K3 had this, every turn was independent — the model never
//  saw prior turns, so follow-ups fell flat. This renders a budgeted replay of
//  recent turns into the grounding prompt: answer text only (never reasoning,
//  never sources).
//
//  The window is governed by a TOTAL character budget filled NEWEST-FIRST, with
//  a generous per-turn cap and a turn-count ceiling on top. The total budget is
//  the real prefill governor; the per-turn cap is deliberately large so M1K3's
//  OWN prior answer survives intact — the old 400-char cap chopped it, so a
//  follow-up like "expand on your third point" had already lost the third point.
//  The headroom is cheap: the models run ~32K context and 8-bit quantized KV, and
//  the persona prefix is cached — only this replay re-prefills each turn.
//
//  Signed: Kev + claude-fable-5, 2026-06-10, Confidence 0.8, Prior: Unknown
//  Review: Kev + claude-opus-4-8, 2026-06-30, Confidence 0.85 — widened from
//  6×400 to a newest-first 8000-char budget / 1500-per-turn / 16-turn ceiling.
//  The 6×400 window was far more conservative than the model or Mac needs and
//  mangled M1K3's own answers; budget-governed windowing gives real multi-turn
//  headroom while keeping prefill bounded. Tune from the TTFT logs at ⌘R.
//  Review: Kev + claude-opus-5-5, 2026-10-17, Confidence 0.7 — the earlier-user trace (#626). With Big's spoken
//  cap the window evicts a fact the user said once (turn 2's "my sister is coming"), and the follow-up six
//  exchanges on got a confabulated answer. A budget with `earlierUserChars` now opens the replay with the
//  evicted USER turns in their own words (answers dropped: they are long and re-derivable), newest-first
//  within that allowance, overhead counted. Zero, the default, renders today's block byte for byte.
//  Probe (voice rig, Big, cap on): the once-said fact recalled 4/4 readable runs on the dispatch route, and no run
//  re-answered a traced question; +20–50 prompt tokens. Open: a horizon past ~8 user lines (#629).
//  Review: Kev + claude-fable-5.1, 2026-10-26, Confidence 0.75 — block eviction (`evictionBlockTurns`, design doc
//  §2a). With the cross-turn tail checkpoint (#687) the window's one-turn slide became the dominant prefill miss: from
//  message 10 the common prefix of consecutive renders collapsed to the persona every turn. The start now snaps up to
//  a multiple of the block, so the prefix holds for block/2 messages and shifts once; the cost is up to block − 1
//  fewer turns right after a boundary (the trace, where a caller has one, carries their user lines). One is today's
//  window byte for byte; the MLX tiers get `HistoryBudgetPolicy.defaultEvictionBlockTurns`. Open: the recall probe
//  for a turn referenced just past a boundary, and whether the block should be exchanges rather than turns.
//

import Foundation

/// One prior exchange turn, flattened for replay.
public struct ChatTurn: Sendable, Equatable {
    public enum Role: Sendable, Equatable {
        case user
        case assistant
    }

    public let role: Role
    public let text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

public enum HistoryWindow {
    /// Default hard ceiling on turns kept, newest-first (≈8 exchanges).
    static let maxTurns = 16
    /// Default per-turn character cap — generous so M1K3's own prior answer
    /// survives intact (the 400-char cap mangled it). Most answers fit whole.
    static let maxCharsPerTurn = 1500
    /// Default total budget across the whole replay (~2K tokens at ≈4 chars/token).
    static let maxTotalChars = 8000

    /// The replay budget — injected so it can be made BRAIN-AWARE (see
    /// `HistoryBudgetPolicy`): a wide window on the big-context Qwen tiers, a hard
    /// clamp on gemma-4 (`big`), whose RotatingKVCache silently rotates the
    /// persona/grounding HEAD out past 8192 tokens. The defaults reproduce the
    /// conservative shipped window so an unwired caller is byte-identical.
    public struct Budget: Sendable, Equatable {
        /// Total chars across the whole replay block (the real prefill governor).
        public var totalChars: Int
        /// Per-turn fidelity cap (so one long answer can't swallow the budget).
        public var perTurnChars: Int
        /// Hard ceiling on turn count (caps a long run of tiny turns).
        public var maxTurns: Int
        /// Evict the oldest turns in BLOCKS of this many (design doc §2a, 2026-10-26): the window's
        /// start index snaps UP to a multiple of it, so consecutive renders share their opening for
        /// `block/2` messages and the KV cache can keep the conversation's prefix across turns
        /// (`ConversationTailCache`). One (the default) is the sliding window, byte for byte. The
        /// snap only ever keeps FEWER turns than the budget allows (up to `block − 1` fewer, right
        /// after a boundary), so every bound above still holds; the newest turn always survives.
        public var evictionBlockTurns: Int
        /// The fewest turns the window keeps once it is full: the ceiling less what a block snap can
        /// drop (block − 1, plus one for an orphaned opener). The rolling-distillation trigger reads
        /// THIS, not `maxTurns` (#629's gap: a turn neither replayed nor distilled), so a snapped-away
        /// turn is distilled before it is forgotten. One block: the ceiling itself.
        public var minimumKeptTurns: Int {
            evictionBlockTurns > 1 ? max(1, maxTurns - evictionBlockTurns) : maxTurns
        }

        /// Chars for the earlier-user trace: the user's own words from the turns the window
        /// evicted, above the kept turns. Zero (the default) renders no trace. Charged on TOP of
        /// `totalChars`, so a caller with a hard bound budgets the sum.
        public var earlierUserChars: Int

        public init(
            totalChars: Int, perTurnChars: Int, maxTurns: Int, evictionBlockTurns: Int = 1, earlierUserChars: Int = 0
        ) {
            self.totalChars = totalChars
            self.perTurnChars = perTurnChars
            self.maxTurns = maxTurns
            // Clamped to the ceiling: a block wider than the window would snap to the newest turn alone,
            // and an absurd argv value would overflow the snap's arithmetic (review fold, 2026-10-26).
            self.evictionBlockTurns = min(max(1, evictionBlockTurns), max(1, maxTurns))
            self.earlierUserChars = earlierUserChars
        }

        /// Today's conservative shipped window — the no-opt-in default.
        public static let `default` = Budget(
            totalChars: HistoryWindow.maxTotalChars,
            perTurnChars: HistoryWindow.maxCharsPerTurn,
            maxTurns: HistoryWindow.maxTurns
        )

        /// The same window minus a per-image reserve: an attached image's
        /// vision soft tokens share the context with the replay, and the one
        /// tier that sees images (Big) overflows its rotating window
        /// SILENTLY — so the replay yields, never the persona/grounding
        /// head. Zero images is the identity; perTurnChars is re-clamped so
        /// the rotating-KV invariant (perTurn ≤ total) survives the shrink.
        public func reservingImages(_ count: Int) -> Budget {
            guard count > 0 else { return self }
            let total = max(0, totalChars - count * HistoryBudgetPolicy.imageReserveCharsPerImage)
            return Budget(
                totalChars: total,
                perTurnChars: min(perTurnChars, total),
                maxTurns: maxTurns,
                evictionBlockTurns: evictionBlockTurns,
                earlierUserChars: earlierUserChars
            )
        }
    }

    /// Render the replay block for the grounding prompt, or nil when there is
    /// no usable history. Turns are walked newest→oldest, each truncated to the
    /// per-turn cap, accumulated until the next would exceed the total budget;
    /// the result is re-ordered chronologically. The most recent turn is always
    /// kept. NOTE the accounting counts the header and per-line separators, so
    /// the rendered block exceeds `totalChars` ONLY via the unconditional newest
    /// turn (header + one per-turn-capped line, when that alone overflows). A
    /// caller that needs a hard upper bound (a rotating-KV tier) must keep
    /// `perTurnChars ≤ totalChars − header − 7` — the 7 is the newest line's
    /// own overhead (6-char "USER: "/"M1K3: " label + the truncation ellipsis).
    /// `HistoryBudgetPolicy`'s budgets clear the ~59-char total by thousands,
    /// making the block provably ≤ `totalChars` at every wired call site.
    ///
    /// With `earlierUserChars` > 0 the block opens with the earlier-user trace: see `earlierTrace`.
    static func render(_ turns: [ChatTurn], budget: Budget = .default) -> String? {
        let all = turns
            .map { ChatTurn(role: $0.role, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.text.isEmpty }
        let usable = all.suffix(budget.maxTurns)
        guard !usable.isEmpty else { return nil }

        var kept: [String] = []
        // Seed with the header so `total` tracks the REAL rendered size — the
        // stated invariant used to omit header + separators (~67 chars of
        // silent overrun the old tests hid behind slack; 112 review nit).
        var total = header.count
        for turn in usable.reversed() {
            let label = turn.role == .user ? "USER" : "M1K3"
            let line = "\(label): \(truncate(turn.text, max: budget.perTurnChars))"
            let cost = line.count + (kept.isEmpty ? 0 : 1) // +1 = the "\n" joiner
            // Keep at least the newest turn even if it alone would exceed the
            // budget (its per-turn cap still bounds it); stop once full.
            if !kept.isEmpty, total + cost > budget.totalChars { break }
            kept.append(line)
            total += cost
        }
        guard !kept.isEmpty else { return nil }

        // Block eviction: snap the window's start up to a multiple of the block (keeping fewer,
        // never more), clamped so the newest turn stays. Pure in the turn list — no stored anchor.
        if budget.evictionBlockTurns > 1 {
            let block = budget.evictionBlockTurns
            let start = all.count - kept.count
            var snapped = min((start + block - 1) / block * block, all.count - 1)
            // An orphaned opener (the oldest kept line is M1K3's answer, its question snapped away —
            // an unanswered turn earlier flipped the parity) drops too: still pure, still fewer.
            if snapped < all.count - 1, all[snapped].role == .assistant { snapped += 1 }
            // A char-limited window (long answers, an image reserve) can be short enough that the
            // snap would halve it; then today's slide is the lesser evil and the snap is skipped.
            if all.count - snapped >= (kept.count + 1) / 2 {
                kept = Array(kept.prefix(all.count - snapped)) // newest-first: the prefix is the newest
            }
        }

        // Everything older than the kept turns, whether the char budget, the turn ceiling or the block cut it.
        let trace = earlierTrace(all.dropLast(kept.count), chars: budget.earlierUserChars)
        return header + (trace.map { $0 + "\n" } ?? "") + kept.reversed().joined(separator: "\n")
    }

    static let header = "CONVERSATION SO FAR (context for the new question):\n"
    /// Marks a traced line: the user's words from a turn the window no longer replays in full.
    static let earlierLabel = "USER (earlier): "
    /// Closes the trace, so the model knows the replies are missing on purpose.
    static let earlierElision = "[M1K3's replies to those earlier lines are left out.]"
    /// Per-line cap in the trace: long enough for a spoken ramble, short enough that one can't eat it.
    static let earlierPerLineChars = 240

    /// The user's own words from the evicted turns, newest-first until `chars` is spent, rendered
    /// oldest-first and closed by `earlierElision`. Every char of it (labels, joiners, the elision
    /// and the newline before the kept turns) is charged to `chars`, so the whole block stays within
    /// `totalChars + earlierUserChars`. Nil when nothing was evicted or nothing fits.
    ///
    /// User turns only: they are short and they carry what the user told M1K3 ("my sister is
    /// coming"). M1K3's answers are ~600 chars each when spoken and can be said again.
    private static func earlierTrace(_ evicted: some Collection<ChatTurn>, chars: Int) -> String? {
        let overhead = earlierElision.count + 2 // its own joiner + the newline before the kept turns
        guard chars > overhead else { return nil }
        var lines: [String] = []
        var spent = overhead
        for turn in evicted.reversed() where turn.role == .user {
            let line = earlierLabel + truncate(turn.text, max: earlierPerLineChars)
            guard spent + line.count + 1 <= chars else { break }
            lines.append(line)
            spent += line.count + 1
        }
        guard !lines.isEmpty else { return nil }
        return lines.reversed().joined(separator: "\n") + "\n" + earlierElision
    }

    private static func truncate(_ text: String, max: Int) -> String {
        guard text.count > max else { return text }
        return text.prefix(max).trimmingCharacters(in: .whitespaces) + "…"
    }
}
