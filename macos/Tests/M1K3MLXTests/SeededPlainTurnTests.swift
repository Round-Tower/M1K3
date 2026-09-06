//
//  SeededPlainTurnTests.swift
//  M1K3MLXTests
//
//  The pure decision behind a plain-chat turn on a seeded persona prefix.
//
//  The bug this pins (2026-09-06, pocket security 0/14 → 1/7 reproduced): the
//  plain path handed the seeded persona cache to upstream `ChatSession(cache:)`,
//  which renders the NEXT turn on its own — `[user]` alone through the chat
//  template. Templates that open with `bos_token` (LFM2, Llama) then emit a
//  SECOND start-of-text after the cached persona, and the model reads the user
//  turn as a fresh document: no persona, no rules. Replaying the exact bytes in
//  mlx-lm with that one extra token reproduced the app's answers verbatim
//  (question echoed back, "My rules are: 1. Always be honest", a fake base64
//  blob); without it the same prompt scored 18/35. Qwen's template has no BOS,
//  so Lil never showed it.
//
//  The fix renders `[system, user]` as ONE template pass and prefills only the
//  suffix past the seed — the tool path's shape. This enum is the slice
//  decision; the render itself is verify-by-launch.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-06, Confidence 0.9 (the arithmetic is
//  pinned here; the double-BOS cause was proven by byte replay, not inferred).
//  Prior: Kev + claude-opus-4-8 (CrossTurnCacheReuseTests, the sibling seam).
//

import Foundation
@testable import M1K3MLX
import Testing

struct SeededPlainTurnTests {
    @Test("the seed is an exact prefix of the full render → prefill only the suffix")
    func exactPrefixReusesSeed() {
        // seed = [BOS, system…]; full = seed + [user turn…]
        let plan = SeededPlainTurn.plan(seed: [1, 10, 11, 12], full: [1, 10, 11, 12, 20, 21, 22])
        #expect(plan == .reuse(prefixTokens: 4))
    }

    @Test("a render that diverges inside the seed cannot use it — fresh, full prefill")
    func divergenceIsFresh() {
        // A persona-text or tool-palette mismatch between seed and render.
        let plan = SeededPlainTurn.plan(seed: [1, 10, 11, 12], full: [1, 10, 99, 12, 20])
        #expect(plan == .fresh)
    }

    @Test("a render no longer than the seed leaves nothing to prefill — fresh")
    func nothingPastTheSeedIsFresh() {
        #expect(SeededPlainTurn.plan(seed: [1, 10, 11], full: [1, 10, 11]) == .fresh)
        #expect(SeededPlainTurn.plan(seed: [1, 10, 11], full: [1, 10]) == .fresh)
    }

    @Test("an empty seed is never reused")
    func emptySeedIsFresh() {
        #expect(SeededPlainTurn.plan(seed: [], full: [1, 2, 3]) == .fresh)
    }

    @Test("a lone user render (the old bug: BOS first) is NOT a continuation of the seed")
    func loneUserRenderDoesNotMatch() {
        // What upstream ChatSession(cache:) fed after the seed: [BOS, user…] —
        // it shares only the BOS with the seed and must never be treated as
        // the seed's suffix.
        let plan = SeededPlainTurn.plan(seed: [1, 10, 11, 12], full: [1, 20, 21, 22])
        #expect(plan == .fresh)
    }
}
