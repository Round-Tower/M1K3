//
//  ConversationTailCacheTests.swift
//  M1K3MLXTests
//
//  Store logic only — the payload arrays are empty `[KVCache]` because the
//  cache's decisions (key match, cap, displacement, invalidation) never look
//  inside them; what the arrays MEAN is the live turn's business and is
//  verified at ⌘R like all MLX generation (same tested-surface convention as
//  PersonaPrefixCacheTests).
//
//  Signed (this contribution only): Kev + claude-fable-5.1, 2026-10-25, Confidence 0.8 — the exact-checkpoint
//  cases (`adoptCheckpoint`, byte cap, token belt, `recordRender`/`previousRender`, invalidate). Prior: Unknown.
//

@testable import M1K3MLX
import MLXLMCommon
import Testing

struct ConversationTailCacheTests {
    private let key = PersonaCacheKey(
        modelID: "test/model", toolNames: ["b", "a"], personaText: "persona"
    )

    @Test("an adopted tail comes back for the same key, token ids intact")
    func adoptRoundTrip() throws {
        let cache = ConversationTailCache()
        #expect(cache.adopt([], tokenIDs: [1, 2, 3], for: key) == .stored)
        let seed = try #require(cache.snapshot(for: key))
        #expect(seed.tokenIDs == [1, 2, 3])
    }

    @Test("a different key misses — persona edit, palette change, model swap all land here")
    func keyMismatchMisses() {
        let cache = ConversationTailCache()
        cache.adopt([], tokenIDs: [1, 2, 3], for: key)
        let other = PersonaCacheKey(
            modelID: "test/model", toolNames: ["a"], personaText: "persona"
        )
        #expect(cache.snapshot(for: other) == nil)
    }

    @Test("an over-cap tail is refused — and the previous good tail SURVIVES")
    func overCapRefusedKeepsPrevious() throws {
        // The refused tail is the newest state, but the old one is still a
        // self-consistent (cache, ids) pair and still a strict prefix of the
        // growing conversation — a smaller win beats no win, and the reuse
        // arithmetic (common prefix, trim to offset) stays valid either way.
        let cache = ConversationTailCache(cap: 4)
        cache.adopt([], tokenIDs: [1, 2, 3], for: key)
        #expect(cache.adopt([], tokenIDs: [1, 2, 3, 4, 5], for: key) == .overCap)
        let seed = try #require(cache.snapshot(for: key))
        #expect(seed.tokenIDs == [1, 2, 3])
    }

    @Test("a newer tail displaces the older one — single slot, most recent wins")
    func newerDisplacesOlder() throws {
        let cache = ConversationTailCache()
        cache.adopt([], tokenIDs: [1, 2], for: key)
        cache.adopt([], tokenIDs: [1, 2, 3, 4], for: key)
        let seed = try #require(cache.snapshot(for: key))
        #expect(seed.tokenIDs == [1, 2, 3, 4])
    }

    @Test("a tail under a NEW key displaces the old key's tail — one slot total")
    func newKeyDisplacesOldKey() {
        // Single slot is the memory ceiling: two retained tails would double
        // the ~300 MiB worst case. A brain/palette alternation pays a persona
        // fallback, exactly today's behaviour.
        let cache = ConversationTailCache()
        cache.adopt([], tokenIDs: [1, 2], for: key)
        let other = PersonaCacheKey(
            modelID: "test/model", toolNames: ["a"], personaText: "persona"
        )
        cache.adopt([], tokenIDs: [9], for: other)
        #expect(cache.snapshot(for: key) == nil)
        #expect(cache.snapshot(for: other)?.tokenIDs == [9])
    }

    @Test("invalidate drops the slot")
    func invalidateDrops() {
        let cache = ConversationTailCache()
        cache.adopt([], tokenIDs: [1], for: key)
        cache.invalidate()
        #expect(cache.snapshot(for: key) == nil)
    }

    @Test("the default cap carries the RAM arithmetic it was sized by")
    func defaultCapIsBounded() {
        // ~78 KB/token on Lil (36 layers × 8 KV heads × 128 dim × 2, kvBits 8)
        // → 4000 tokens ≈ 300 MiB retained ceiling. Raise only with a measured
        // RAM snapshot in hand — the PersonaPrefixCache rule.
        #expect(ConversationTailCache.maxSeedTokens == 4000)
    }

    // MARK: - Exact checkpoints (2026-10-25): the cross-turn tail in checkpoint mode

    @Test("an adopted checkpoint comes back vouched exact, with its state and ids")
    func checkpointRoundTripIsExact() throws {
        let cache = ConversationTailCache()
        let outcome = cache.adoptCheckpoint([], tokenIDs: [1, 2, 3], state: LMOutput.State(), bytes: 10, for: key)
        #expect(outcome == .stored)
        let seed = try #require(cache.snapshot(for: key))
        #expect(seed.exact)
        #expect(seed.state != nil)
        #expect(seed.tokenIDs == [1, 2, 3])
    }

    @Test("a live-path tail is still not vouched exact — the two kinds never get confused")
    func liveTailStaysInexact() throws {
        let cache = ConversationTailCache()
        cache.adopt([], tokenIDs: [1, 2, 3], for: key)
        let seed = try #require(cache.snapshot(for: key))
        #expect(!seed.exact)
        #expect(seed.state == nil)
    }

    @Test("a checkpoint over the BYTE cap is refused — and the previous checkpoint survives")
    func overBytesRefusedKeepsPrevious() throws {
        let cache = ConversationTailCache(byteCap: 100)
        #expect(cache.adoptCheckpoint([], tokenIDs: [1, 2], state: nil, bytes: 90, for: key) == .stored)
        #expect(cache.adoptCheckpoint([], tokenIDs: [1, 2, 3, 4], state: nil, bytes: 101, for: key) == .overBytes)
        let seed = try #require(cache.snapshot(for: key))
        #expect(seed.tokenIDs == [1, 2])
    }

    @Test("the checkpoint token belt is a belt, not the cap: bytes bind first, tokens still bound")
    func checkpointTokenBelt() {
        let cache = ConversationTailCache(checkpointCap: 3, byteCap: 1000)
        #expect(cache.adoptCheckpoint([], tokenIDs: [1, 2, 3, 4], state: nil, bytes: 1, for: key) == .overCap)
        #expect(cache.adoptCheckpoint([], tokenIDs: [1, 2, 3], state: nil, bytes: 1, for: key) == .stored)
    }

    @Test("the previous render is kept per key, so the next turn can find where the renders diverge")
    func previousRenderPerKey() {
        let cache = ConversationTailCache()
        #expect(cache.previousRender(for: key) == nil)
        cache.recordRender([1, 2, 3, 4], for: key)
        #expect(cache.previousRender(for: key) == [1, 2, 3, 4])
        let other = PersonaCacheKey(modelID: "test/model", toolNames: ["a"], personaText: "persona")
        #expect(cache.previousRender(for: other) == nil)
        // A newer render replaces it; a checkpoint adopt leaves it alone.
        cache.recordRender([1, 2, 3, 4, 5, 6], for: key)
        cache.adoptCheckpoint([], tokenIDs: [1, 2], state: nil, bytes: 1, for: key)
        #expect(cache.previousRender(for: key) == [1, 2, 3, 4, 5, 6])
    }

    @Test("invalidate drops the checkpoint AND the recorded render — a brain swap leaves nothing to diverge from")
    func invalidateDropsBoth() {
        let cache = ConversationTailCache()
        cache.recordRender([1, 2, 3], for: key)
        cache.adoptCheckpoint([], tokenIDs: [1, 2], state: nil, bytes: 1, for: key)
        cache.invalidate()
        #expect(cache.snapshot(for: key) == nil)
        #expect(cache.previousRender(for: key) == nil)
    }
}
