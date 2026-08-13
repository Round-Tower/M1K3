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

@testable import M1K3MLX
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
}
