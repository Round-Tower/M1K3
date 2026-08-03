//
//  GroundingBudget.swift
//  M1K3Knowledge
//
//  Caps injected grounding (KNOWLEDGE chunks + the WHAT-I-KNOW-ABOUT-YOU
//  memory block) to a token budget BEFORE AgentRAGResponder ever renders it
//  into a prompt. Both lanes are injected VERBATIM and UNTRUNCATED today
//  (AgentRAGResponder.groundingBody), so a wide retrieval hit, a dense memory
//  set, or simply more chunks than usual can silently blow the prompt's fixed
//  non-history reserve.
//
//  The concrete failure this closes (measured on-device, PR #65's prompt-size
//  instrument, 2026-07-19/20): on gemma-4-12B ("Big"), the grounded-Q worst
//  case prompt landed at 2998 of a 3000-token reserve — 2 tokens of headroom.
//  One more chunk, a denser memory hit, or plain tokenization variance tips
//  it past 3000, and gemma-4's `RotatingKVCache(8192)` silently rotates the
//  persona/grounding head out of the window mid-turn. There is no error —
//  M1K3 just answers off-persona.
//
//  `fit` is pure and deterministic: same inputs, same `countTokens` answers,
//  same output, every time. No logging here — the wiring site (a `.notice`
//  breadcrumb, once, only when something actually changed) is
//  AgentRAGResponder's job, not this policy's.
//
//  Signed: Kev + claude-fable-5, 2026-07-20, Confidence 0.85 (arithmetic
//  fully pinned by GroundingBudgetTests with a deterministic char-count
//  fake; the real on-device re-measure against a live MLX tokenizer — does
//  grounded-Q actually drop below 3000 now? — is owed, not run here).
//  Prior: Unknown
//  Review: Kev + claude-opus-5, 2026-08-03, Confidence 0.85 — the cap FAILED
//  OPEN. A nil `countTokens` skipped it entirely, on the belief that such a
//  provider self-manages its window; and three further `?? 0` sites scored an
//  unmeasured unit as FREE, so even the truncation binary-search never
//  truncated. Apple Foundation Models does not self-manage: it throws
//  `exceededContextWindowSize` at 4096 tokens — the smallest window of any
//  tier, and the only tier the cap exempted. Exactly inverted. Now every path
//  measures through `measure`, which falls back to a conservative
//  chars-per-token estimate. Unmeasurable must never mean unlimited.
//

import Foundation

public enum GroundingBudget {
    /// The token budget for the COMBINED grounding (KNOWLEDGE chunks +
    /// memory facts) — one slice of the app's fixed 3000-token non-history
    /// reserve (`AppEnvironment.historyReserveTokens`), whose own comment
    /// already earmarked ~1100 for "grounding chunks" as a design-time
    /// guess. PR #65 measured the REAL fixed parts on-device — persona+tools
    /// KV-seed ~1380 + rules ~338 + preamble ~71 + template ~14 ≈ 1800 —
    /// leaving ~1200 of the 3000 reserve actually free for grounding. 1100
    /// keeps a ~100-token margin below that for tokenization variance (a
    /// denser chunk, a longer citation label) rather than spending every
    /// last token the measurement implies is available.
    public static let defaultTokenBudget = 1100

    /// Chars per token for the estimate used when a provider has no tokenizer.
    ///
    /// PR #65's on-device prompt-size instrument measured real prose+markup at
    /// ~4.4–4.7 chars/token (2026-07-20). The LOW end is deliberate: a smaller
    /// divisor over-estimates the token count, which over-tightens the budget —
    /// the safe direction to be wrong in.
    ///
    /// Why this exists at all: the cap used to be a NO-OP whenever `countTokens`
    /// returned nil, on the belief (recorded in TokenCounting.swift) that such a
    /// provider "self-manages its own context window". Apple Foundation Models
    /// does not. Interviewing Mini over MCP on 2026-08-03 produced, verbatim:
    ///
    ///     exceededContextWindowSize: "Content contains 4486 tokens, which
    ///     exceeds the maximum allowed context size of 4096."
    ///
    /// Mini has the SMALLEST window of any tier (4096 against the MLX tiers'
    /// 8192) and was the ONLY tier exempt from the cap — the exemption was
    /// exactly inverted. Four of seven conversational probes in that interview
    /// never answered at all, timing out at 120s while the loop ground through
    /// an over-stuffed prompt. A budget that fails open is not a budget.
    public static let estimatedCharsPerToken = 4.4

    /// A conservative token estimate for text, used only where an exact count
    /// is unavailable.
    public static func estimatedTokens(_ text: String) -> Int {
        Int((Double(text.count) / estimatedCharsPerToken).rounded(.up))
    }

    /// The token cost of `text`: the provider's exact count when it has one,
    /// otherwise the estimate. Never nil, and never a silent zero — an
    /// unmeasured unit costing "free" was the second fail-open path here.
    static func measure(_ text: String, countTokens: (String) async -> Int?) async -> Int {
        await countTokens(text) ?? estimatedTokens(text)
    }

    /// Fit `chunks` and `memories` inside `tokenBudget`, sharing ONE budget —
    /// doc chunks (the larger, more variable lane, and the one actually
    /// cited) are filled first in rank order, then memories against whatever
    /// remains.
    ///
    /// - `countTokens` returning `nil` means the active provider has no
    ///   tokenizer. That is NOT a licence to skip the cap: the cap falls back
    ///   to a conservative character-based estimate (`estimatedTokens`), because
    ///   "unmeasurable" must never mean "unlimited". See `estimatedCharsPerToken`
    ///   for why the old no-op was wrong and what it cost.
    /// - Whole units are kept in rank order until the next would exceed the
    ///   remaining budget, then the rest are dropped — no mid-unit
    ///   truncation, except for the very first unit overall (below).
    /// - At least one unit always survives when anything was retrieved: if
    ///   the single highest-ranked unit alone exceeds the WHOLE budget, it
    ///   is kept but its content is truncated to fit, with a visible
    ///   " …[truncated]" tail marker. A chunk's citation label sits at the
    ///   HEAD of its rendered text (rendered separately downstream, from
    ///   fields this policy never touches), so tail-truncating `content`
    ///   never loses it.
    public static func fit(
        chunks: [ChunkHit],
        memories: [ChunkHit],
        tokenBudget: Int,
        countTokens: (String) async -> Int?
    ) async -> (chunks: [ChunkHit], memories: [ChunkHit]) {
        guard !chunks.isEmpty || !memories.isEmpty else {
            return (chunks, memories)
        }

        let units = chunks.enumerated().map { Unit.chunk($1, index: $0 + 1) }
            + memories.map { Unit.memory($0) }

        guard let gateText = units.first?.renderedText else {
            return (chunks, memories)
        }
        let gateCost = await measure(gateText, countTokens: countTokens)

        var remaining = tokenBudget
        var keptChunks: [ChunkHit] = []
        var keptMemories: [ChunkHit] = []

        for (offset, unit) in units.enumerated() {
            let cost = offset == 0
                ? gateCost
                : await measure(unit.renderedText, countTokens: countTokens)
            let isTopOverallUnit = keptChunks.isEmpty && keptMemories.isEmpty
            if cost > remaining {
                if isTopOverallUnit {
                    // Never return empty grounding when something was
                    // retrieved — truncate the single top unit's tail to fit.
                    switch unit {
                    case let .chunk(hit, index):
                        keptChunks.append(
                            await truncatedChunk(
                                hit, index: index, tokenBudget: remaining, countTokens: countTokens
                            )
                        )
                    case let .memory(hit):
                        keptMemories.append(
                            await truncatedMemory(hit, tokenBudget: remaining, countTokens: countTokens)
                        )
                    }
                }
                break
            }
            switch unit {
            case let .chunk(hit, _): keptChunks.append(hit)
            case let .memory(hit): keptMemories.append(hit)
            }
            remaining -= cost
        }
        return (keptChunks, keptMemories)
    }

    /// Sum of every unit's rendered-and-counted cost, using the SAME
    /// rendering `fit` walks — for the wiring site's before→after breadcrumb
    /// only. Not called by `fit` itself, which counts unit-by-unit and stops
    /// early on purpose; a `nil` per-unit count reads as 0 here (this total
    /// is diagnostic, not budget-critical).
    public static func totalTokens(
        chunks: [ChunkHit], memories: [ChunkHit], countTokens: (String) async -> Int?
    ) async -> Int {
        // Same `measure` the cap itself uses, so the breadcrumb reports the
        // numbers the decision was actually made on. With `?? 0` this read
        // "tokens 0→0" on Mini while the cap was really dropping units 9→7 —
        // an instrument that says nothing happened while something did is worse
        // than no instrument.
        var total = 0
        for (offset, chunk) in chunks.enumerated() {
            total += await measure(
                Unit.chunk(chunk, index: offset + 1).renderedText, countTokens: countTokens
            )
        }
        for memory in memories {
            total += await measure(Unit.memory(memory).renderedText, countTokens: countTokens)
        }
        return total
    }

    /// One candidate for the budget walk: a KNOWLEDGE chunk (numbered, with
    /// its citation label) or a memory fact (bulleted) — rendered EXACTLY the
    /// way `AgentRAGResponder.groundingBody` renders it, so the measured cost
    /// matches the real prompt almost byte-for-byte (minus the "\n\n" join
    /// separators between sections/units — a few tokens the 1100 budget's
    /// ~100-token margin already covers).
    private enum Unit {
        case chunk(ChunkHit, index: Int)
        case memory(ChunkHit)

        var renderedText: String {
            switch self {
            case let .chunk(hit, index):
                "\(index). \(ChatPromptBuilder.citationLabel(for: hit))\n\(hit.content)"
            case let .memory(hit):
                "- \(hit.content)"
            }
        }
    }

    /// Visible marker for a tail-truncated unit — appended, never hidden,
    /// so a truncated grounding item never silently masquerades as complete.
    private static let truncationMarker = " …[truncated]"

    /// Truncate `chunk`'s content tail to fit `tokenBudget`, keeping its
    /// numbered citation-label HEAD intact (rendered from `itemTitle`/
    /// `heading`, never touched here — only `content` is mutated).
    private static func truncatedChunk(
        _ chunk: ChunkHit, index: Int, tokenBudget: Int, countTokens: (String) async -> Int?
    ) async -> ChunkHit {
        let head = "\(index). \(ChatPromptBuilder.citationLabel(for: chunk))\n"
        let headCost = await measure(head, countTokens: countTokens)
        let markerCost = await measure(truncationMarker, countTokens: countTokens)
        let available = max(0, tokenBudget - headCost - markerCost)
        var truncated = chunk
        truncated.content = await truncatedContent(
            chunk.content, available: available, countTokens: countTokens
        ) + truncationMarker
        return truncated
    }

    /// Truncate `memory`'s content tail to fit `tokenBudget` — no head to
    /// preserve beyond the one-character "- " bullet, folded into the search.
    private static func truncatedMemory(
        _ memory: ChunkHit, tokenBudget: Int, countTokens: (String) async -> Int?
    ) async -> ChunkHit {
        let bulletCost = await measure("- ", countTokens: countTokens)
        let markerCost = await measure(truncationMarker, countTokens: countTokens)
        let available = max(0, tokenBudget - bulletCost - markerCost)
        var truncated = memory
        truncated.content = await truncatedContent(
            memory.content, available: available, countTokens: countTokens
        ) + truncationMarker
        return truncated
    }

    /// The largest character prefix of `text` whose token count fits
    /// `available`, found by binary search over character length —
    /// tokenization isn't linear in characters, so halving (not a fixed
    /// chars/token ratio) is the safe way to narrow in on the fit in
    /// O(log n) `countTokens` calls.
    private static func truncatedContent(
        _ text: String, available: Int, countTokens: (String) async -> Int?
    ) async -> String {
        guard available > 0, !text.isEmpty else { return "" }
        var lo = 0
        var hi = text.count
        var best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            let candidate = String(text.prefix(mid))
            let cost = await measure(candidate, countTokens: countTokens)
            if cost <= available {
                best = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return String(text.prefix(best))
    }
}
