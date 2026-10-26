//
//  ExactPrefixReuseTests.swift
//  M1K3MLXTests
//
//  The pure decision behind the rolling checkpoint on a cache that can never be
//  trimmed (Qwen3.5's MambaCache layers). The live cache can't be rolled back
//  after a turn samples into it, so MLXToolTurnSession keeps EXACT prefixes —
//  caches prefilled without sampling, holding exactly their ids — and extends a
//  copy each send. Measured 2026-10-07: without this every Qwen3.5 tool step
//  re-prefilled ~2,585 tokens (6.8 s); the incumbent's trimmable cache prefilled ~52.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-07, Confidence 0.85, Prior: none (new file).
//  The arithmetic is pinned here; the copy/prefill/state plumbing is verify-by-launch.
//  Review: Kev + claude-fable-5.1, 2026-10-09 — pins `stepSnapshotLabel`, the per-step RAM snapshot's label.
//  Review: Kev + claude-opus-5-5, 2026-10-16 — a seed that wrapped gemma's sliding window takes checkpoint mode.
//  Review: Kev + claude-fable-5.1, 2026-10-25 — `tailCut` (the cross-turn tail's cut point, strictly inside this
//  send's prefill) and the three-candidate ledger order: rolling over tail over persona, a diverged tail falls back.
//  Review: Kev + claude-fable-5.1, 2026-10-26 — `tailCut(stable:)` and `stableTranscript`: the caller-marked stable
//  render cuts on the first render after a window shift; the longer valid cut wins; a bad marker is nil, never a crash.
//

import Foundation
import M1K3Inference
@testable import M1K3MLX
import Testing

struct ExactPrefixReuseTests {
    @Test("no candidates prefills fresh")
    func noCandidates() {
        #expect(ExactPrefixReuse.plan(candidates: [], full: [1, 2, 3]) == .fresh)
    }

    @Test("the persona seed extends: prefill up to the last token, checkpoint there, generate from it")
    func personaSeedExtends() {
        let plan = ExactPrefixReuse.plan(candidates: [[1, 2, 3]], full: [1, 2, 3, 4, 5, 6])
        #expect(plan == .extend(candidate: 0, from: 3, to: 5))
    }

    @Test("the longest candidate that is a strict prefix wins — the rolling checkpoint over the persona")
    func longestPrefixWins() {
        let persona = [1, 2, 3]
        let rolling = [1, 2, 3, 4, 5]
        let plan = ExactPrefixReuse.plan(candidates: [persona, rolling], full: [1, 2, 3, 4, 5, 6, 7])
        #expect(plan == .extend(candidate: 1, from: 5, to: 6))
    }

    @Test("a rolling checkpoint the next render diverged from falls back to the persona, never a partial match")
    func divergedCheckpointFallsBack() {
        // The render re-derived the assistant turn differently at index 4: the
        // checkpoint's KV past that point is the wrong history. No trimming is
        // possible, so a partial match is worthless — the persona still holds.
        let plan = ExactPrefixReuse.plan(candidates: [[1, 2, 3], [1, 2, 3, 9, 9]], full: [1, 2, 3, 4, 5, 6])
        #expect(plan == .extend(candidate: 0, from: 3, to: 5))
    }

    @Test("a candidate one short of the render extends with nothing to prefill — generate the last token")
    func nothingToPrefill() {
        let plan = ExactPrefixReuse.plan(candidates: [[1, 2, 3]], full: [1, 2, 3, 4])
        #expect(plan == .extend(candidate: 0, from: 3, to: 3))
    }

    @Test("a candidate as long as the render is not reusable: generation needs one token of input")
    func equalLengthIsNotReusable() {
        #expect(ExactPrefixReuse.plan(candidates: [[1, 2, 3]], full: [1, 2, 3]) == .fresh)
        #expect(ExactPrefixReuse.plan(candidates: [[1, 2, 3, 4]], full: [1, 2, 3]) == .fresh)
    }

    @Test("an empty candidate holds nothing worth copying")
    func emptyCandidateIgnored() {
        #expect(ExactPrefixReuse.plan(candidates: [[]], full: [1, 2]) == .fresh)
    }

    @Test("an image anywhere in the turn vetoes reuse: the pixels ride beside the token ids")
    func imagesVeto() {
        #expect(ExactPrefixReuse.plan(candidates: [[1, 2]], full: [1, 2, 3, 4], turnCarriesImages: true) == .fresh)
    }

    /// #509 follow-up (2026-10-09): the per-step memory snapshot in checkpoint mode. The
    /// rolling checkpoint is a full-precision copy of the whole transcript's cache, so RAM
    /// per step is the number that says whether "flat per step" holds; the label names the
    /// step and what was reused so the unified log reads as a curve, not a pile.
    @Test("the per-step snapshot label names the step and the reuse, so the log reads as a curve")
    func stepSnapshotLabel() {
        #expect(ExactPrefixReuse.stepSnapshotLabel(step: 1, reused: 2585, total: 2633)
            == "toolTurnSession checkpoint step 1 (reused 2585/2633)")
        #expect(ExactPrefixReuse.stepSnapshotLabel(step: 3, reused: 0, total: 2700)
            == "toolTurnSession checkpoint step 3 (reused 0/2700)")
    }

    @Test("checkpoint mode is for an exact seed whose cache can't be trimmed — and only that")
    func checkpointMode() {
        #expect(ExactPrefixReuse.usesCheckpoints(seedExact: true, seedLayersTrimmable: [true, false, true]))
        // Trimmable caches keep the live-cache path (trim back, roll forward).
        #expect(!ExactPrefixReuse.usesCheckpoints(seedExact: true, seedLayersTrimmable: [true, true]))
        // A seed nobody vouched exact holds a sampled position: never appended to.
        #expect(!ExactPrefixReuse.usesCheckpoints(seedExact: false, seedLayersTrimmable: [false]))
        #expect(!ExactPrefixReuse.usesCheckpoints(seedExact: true, seedLayersTrimmable: []))
    }

    /// 2026-10-16: an exact gemma seed past its sliding window is untrimmable too (a wrapped
    /// RotatingKVCache). Plain turns already extend a copy of it; tool turns now do the same
    /// through checkpoints (proved on Big by the tool arm of `wrappedSeedEquivalenceProbe`), so
    /// the rotating layer is just one more layer that can't be trimmed. `-wrappedPersonaSeed NO`
    /// declines the seed itself, which keeps tool turns on a full prefill.
    @Test("a seed that wrapped a sliding window takes checkpoint mode like any untrimmable seed")
    func wrappedSeedUsesCheckpoints() {
        // gemma-4: full-attention layers trim, the wrapped sliding layers don't.
        #expect(ExactPrefixReuse.usesCheckpoints(seedExact: true, seedLayersTrimmable: [true, false, false, true]))
        // A wrapped seed built the old way (sample, no trim) is still never appended to.
        #expect(!ExactPrefixReuse.usesCheckpoints(seedExact: false, seedLayersTrimmable: [true, false]))
    }

    // MARK: - The cross-turn tail cut (2026-10-25)

    /// Turn N's render ends `…{replay}\n(framing)…{grounding}…Goal: q_N` and turn N+1's continues
    /// `…{replay}\nUSER: q_N\nM1K3: a_N…`: they share exactly through the replay. The cut is that common
    /// prefix, taken on the first send of a turn, and it is worth taking only strictly inside what this
    /// send prefills: past the candidate it extends (`from`) and short of the render's last token (`to`).
    @Test("the tail cut is the common prefix with the previous render, strictly inside this send's prefill")
    func tailCutInsidePrefill() {
        let previous = [1, 2, 3, 4, 5, 6, 7, 8]
        let full = [1, 2, 3, 4, 5, 6, 9, 9, 9, 9]
        #expect(ExactPrefixReuse.tailCut(previous: previous, full: full, from: 3, to: 9) == 6)
    }

    @Test("no previous render, no cut: the first turn of a conversation only records its render")
    func tailCutNeedsPrevious() {
        #expect(ExactPrefixReuse.tailCut(previous: nil, full: [1, 2, 3, 4], from: 1, to: 3) == nil)
        #expect(ExactPrefixReuse.tailCut(previous: [], full: [1, 2, 3, 4], from: 1, to: 3) == nil)
    }

    @Test("a stable render cuts on the first render after a window shift; the longer valid cut wins")
    func tailCutPrefersTheStableRender() {
        let full = [1, 2, 3, 4, 5, 6, 7, 8, 9, 9]
        // The previous render shares only the persona (a window shift); the stable render shares the replay.
        #expect(ExactPrefixReuse.tailCut(
            previous: [1, 2, 3, 0], stable: [1, 2, 3, 4, 5, 6, 7, 0], full: full, from: 3, to: 9
        ) == 7)
        // Both valid: the longer wins, whichever it is.
        #expect(ExactPrefixReuse.tailCut(
            previous: [1, 2, 3, 4, 5, 0], stable: [1, 2, 3, 4, 5, 6, 7, 0], full: full, from: 3, to: 9
        ) == 7)
        #expect(ExactPrefixReuse.tailCut(
            previous: [1, 2, 3, 4, 5, 6, 7, 8, 0], stable: [1, 2, 3, 4, 5, 0], full: full, from: 3, to: 9
        ) == 8)
        // A stable render outside the prefill (at or before the candidate, or the whole render) falls back.
        #expect(ExactPrefixReuse.tailCut(previous: [1, 2, 3, 4, 5, 0], stable: [1, 2, 0], full: full, from: 3, to: 9) == 5)
        #expect(ExactPrefixReuse.tailCut(previous: nil, stable: full, full: full, from: 3, to: 9) == nil)
        #expect(ExactPrefixReuse.tailCut(previous: nil, stable: [], full: full, from: 3, to: 9) == nil)
    }

    @Test("the stable transcript is the marked message cut at the marker, nothing after it, no images")
    func stableTranscriptCut() {
        let messages: [ToolMessage] = [
            .system("persona"),
            .user("preamble Context: replay rest", images: []),
            .assistant(text: "x", toolCalls: []),
        ]
        let user = MLXToolTurnSession.stableTranscript(messages, prefix: .init(messageIndex: 1, characters: 22))
        let userCut: [ToolMessage] = [.system("persona"), .user("preamble Context: repl", images: [])]
        #expect(user == userCut)
        let system = MLXToolTurnSession.stableTranscript(messages, prefix: .init(messageIndex: 0, characters: 4))
        let systemCut: [ToolMessage] = [.system("pers")]
        #expect(system == systemCut)
        #expect(MLXToolTurnSession.stableTranscript(messages, prefix: .init(messageIndex: 1, characters: 99)) == nil)
        #expect(MLXToolTurnSession.stableTranscript(messages, prefix: .init(messageIndex: 2, characters: 1)) == nil)
        #expect(MLXToolTurnSession.stableTranscript(messages, prefix: .init(messageIndex: 5, characters: 1)) == nil)
        #expect(MLXToolTurnSession.stableTranscript(messages, prefix: .init(messageIndex: 1, characters: 0)) == nil)
    }

    @Test("a cut at or before the candidate buys nothing — a slid window or a switched conversation")
    func tailCutAtOrBeforeCandidateIsNoCut() {
        // Diverged inside the persona-length prefix (L = 2 ≤ from = 3): the persona already covers it.
        #expect(ExactPrefixReuse.tailCut(previous: [1, 2, 9, 9], full: [1, 2, 3, 4, 5, 6], from: 3, to: 5) == nil)
        // Diverged exactly at the candidate's end.
        #expect(ExactPrefixReuse.tailCut(previous: [1, 2, 3, 9], full: [1, 2, 3, 4, 5, 6], from: 3, to: 5) == nil)
    }

    @Test("a cut at or past the render's last token is the rolling checkpoint's job, not the tail's")
    func tailCutAtOrPastLastTokenIsNoCut() {
        // Identical renders: L = 6 = full.count; to = 5.
        #expect(ExactPrefixReuse.tailCut(previous: [1, 2, 3, 4, 5, 6], full: [1, 2, 3, 4, 5, 6], from: 3, to: 5) == nil)
        // Same but for the last token: L = 5 = to.
        #expect(ExactPrefixReuse.tailCut(previous: [1, 2, 3, 4, 5, 9], full: [1, 2, 3, 4, 5, 6], from: 3, to: 5) == nil)
    }

    /// The ledger is `plan` over three candidates in a fixed order — persona, tail, rolling — and the
    /// longest strict prefix wins: the tail beats the persona it begins with, the rolling checkpoint
    /// (this turn's own) beats the tail, and a tail the render diverged from loses to the persona.
    @Test("ledger order: rolling over tail over persona, and a diverged tail falls back to the persona")
    func ledgerOrder() {
        let persona = [1, 2, 3]
        let tail = [1, 2, 3, 4, 5]
        let rolling = [1, 2, 3, 4, 5, 6, 7]
        let full = [1, 2, 3, 4, 5, 6, 7, 8, 9]
        #expect(ExactPrefixReuse.plan(candidates: [persona, tail], full: full) == .extend(candidate: 1, from: 5, to: 8))
        #expect(ExactPrefixReuse.plan(candidates: [persona, tail, rolling], full: full)
            == .extend(candidate: 2, from: 7, to: 8))
        let divergedTail = [1, 2, 3, 9, 9]
        #expect(ExactPrefixReuse.plan(candidates: [persona, divergedTail], full: full)
            == .extend(candidate: 0, from: 3, to: 8))
    }
}
