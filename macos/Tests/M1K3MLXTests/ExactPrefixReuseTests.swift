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
//

import Foundation
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

    @Test("checkpoint mode is for an exact seed whose cache can't be trimmed — and only that")
    func checkpointMode() {
        #expect(ExactPrefixReuse.usesCheckpoints(seedExact: true, seedLayersTrimmable: [true, false, true]))
        // Trimmable caches keep the live-cache path (trim back, roll forward).
        #expect(!ExactPrefixReuse.usesCheckpoints(seedExact: true, seedLayersTrimmable: [true, true]))
        // A seed nobody vouched exact holds a sampled position: never appended to.
        #expect(!ExactPrefixReuse.usesCheckpoints(seedExact: false, seedLayersTrimmable: [false]))
        #expect(!ExactPrefixReuse.usesCheckpoints(seedExact: true, seedLayersTrimmable: []))
    }
}
