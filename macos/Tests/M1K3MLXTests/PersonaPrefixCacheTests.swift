//
//  PersonaPrefixCacheTests.swift
//  M1K3MLXTests
//
//  The persona prefix cache key: a cached system-block prefill is only valid
//  for the exact (model × tools × persona text) it was rendered from — Qwen
//  renders TOOLS inside the SYSTEM block, so a different tool set is a
//  different prefix, and a profile update (future) changes the persona hash.
//
//  Signed: Kev + claude-fable-5, 2026-06-10, Confidence 0.85, Prior: Unknown
//

import Foundation
@testable import M1K3MLX
import Testing

struct PersonaPrefixCacheTests {
    @Test("the key fingerprints model, tools, and persona text")
    func keyComponents() {
        let base = PersonaCacheKey(
            modelID: "mlx-community/Qwen3.5-2B-4bit",
            toolNames: ["web_search", "datetime"],
            personaText: "You are M1K3."
        )
        let sameDifferentOrder = PersonaCacheKey(
            modelID: "mlx-community/Qwen3.5-2B-4bit",
            toolNames: ["datetime", "web_search"],
            personaText: "You are M1K3."
        )
        #expect(base == sameDifferentOrder) // tool ORDER must not matter

        let differentTools = PersonaCacheKey(
            modelID: "mlx-community/Qwen3.5-2B-4bit",
            toolNames: ["datetime"],
            personaText: "You are M1K3."
        )
        #expect(base != differentTools)

        let differentPersona = PersonaCacheKey(
            modelID: "mlx-community/Qwen3.5-2B-4bit",
            toolNames: ["web_search", "datetime"],
            personaText: "You are M1K3, updated."
        )
        #expect(base != differentPersona)
    }

    @Test("a mismatched key yields no snapshot; invalidate clears the slot")
    func missAndInvalidate() {
        let store = PersonaPrefixCache()
        let key = PersonaCacheKey(modelID: "m", toolNames: [], personaText: "p")
        #expect(store.snapshot(for: key) == nil)

        store.store([], tokenIDs: Array(0 ..< 42), for: key)
        #expect(store.snapshot(for: key)?.tokenCount == 42)
        #expect(store.snapshot(for: key)?.tokenIDs == Array(0 ..< 42))

        let otherKey = PersonaCacheKey(modelID: "m", toolNames: ["x"], personaText: "p")
        #expect(store.snapshot(for: otherKey) == nil)

        store.invalidate()
        #expect(store.snapshot(for: key) == nil)
    }

    // MARK: - Capacity (the 2026-08-09 live finding)

    private func key(_ tools: [String]) -> PersonaCacheKey {
        PersonaCacheKey(modelID: "gemma-4-12B", toolNames: tools, personaText: "You are M1K3.")
    }

    /// MEASURED LIVE, 2026-08-09, on Kev's running app: the provider renders TWO
    /// prefixes — the tool-turn one (persona + tool specs, 1991 tok) and the
    /// plain-generate one (no tools, 1170 tok, used by the conversation titler
    /// and other background work). The slot held ONE, so a 64-token background
    /// title evicted the interactive prefix and the next chat turn spent
    /// 16–19 SECONDS re-prefilling it. Decode was healthy at 30 tok/s
    /// throughout: the pause was never the model thinking.
    @Test("the interactive and background prefixes coexist — neither evicts the other")
    func twoPrefixesCoexist() {
        let store = PersonaPrefixCache()
        let interactive = key(["web_search", "search_knowledge"])
        let background = key([])

        store.store([], tokenIDs: Array(0 ..< 1991), for: interactive)
        store.store([], tokenIDs: Array(0 ..< 1170), for: background)

        #expect(store.snapshot(for: interactive)?.tokenCount == 1991)
        #expect(store.snapshot(for: background)?.tokenCount == 1170)
    }

    /// Capacity is finite because each slot retains Metal-backed KV arrays for
    /// a ~2k-token prefix across every layer of a 12B model. When it overflows,
    /// the LEAST RECENTLY USED entry goes — so a prefix in constant interactive
    /// use survives a parade of one-off tool palettes.
    @Test("overflow evicts the least recently USED, not the least recently stored")
    func overflowEvictsLeastRecentlyUsed() {
        let store = PersonaPrefixCache(capacity: 2)
        let hot = key(["web_search"])
        let cold = key([])

        store.store([], tokenIDs: [1], for: hot)
        store.store([], tokenIDs: [2], for: cold)
        // Touching `hot` makes `cold` the eviction candidate even though it was
        // stored more recently.
        #expect(store.snapshot(for: hot) != nil)

        store.store([], tokenIDs: [3], for: key(["a", "b"]))
        #expect(store.snapshot(for: hot) != nil, "a hot prefix must survive overflow")
        #expect(store.snapshot(for: cold) == nil)
    }

    /// The coalescer's re-check ("did a build finish while I queued?") only ever
    /// asked whether an entry EXISTS — and asking with `snapshot(for:)` deep-copies
    /// the Metal-backed KV arrays of a ~2k-token prefix just to throw them away.
    /// In a PR whose whole point is not paying for KV work nobody uses, that stung.
    @Test("contains answers existence without paying for a copy")
    func containsIsACheapPeek() {
        let store = PersonaPrefixCache(capacity: 2)
        let known = key(["web_search"])
        #expect(store.contains(known) == false)
        store.store([], tokenIDs: [1], for: known)
        #expect(store.contains(known))
        #expect(store.contains(key(["something_else"])) == false)
    }

    /// A peek is not a use. If `contains` promoted its hit, a caller that merely
    /// asked would outrank a turn that actually generated from the prefix, and the
    /// eviction candidate would stop being the genuinely coldest entry.
    @Test("contains does not count as a use — it cannot reorder eviction")
    func containsDoesNotPromote() {
        let store = PersonaPrefixCache(capacity: 2)
        let older = key(["web_search"])
        let newer = key([])
        store.store([], tokenIDs: [1], for: older)
        store.store([], tokenIDs: [2], for: newer)

        #expect(store.contains(older)) // a peek, not a touch

        store.store([], tokenIDs: [3], for: key(["a", "b"]))
        #expect(store.contains(older) == false, "a mere peek must not have saved it")
        #expect(store.contains(newer))
    }

    @Test("invalidate clears every slot, not just the newest")
    func invalidateClearsAll() {
        let store = PersonaPrefixCache(capacity: 2)
        store.store([], tokenIDs: [1], for: key(["web_search"]))
        store.store([], tokenIDs: [2], for: key([]))
        store.invalidate()
        #expect(store.snapshot(for: key(["web_search"])) == nil)
        #expect(store.snapshot(for: key([])) == nil)
    }

    @Test("re-storing a known key refreshes it in place rather than adding a slot")
    func reStoreDoesNotGrow() {
        let store = PersonaPrefixCache(capacity: 2)
        let a = key(["web_search"])
        let b = key([])
        store.store([], tokenIDs: [1], for: a)
        store.store([], tokenIDs: [9], for: a)
        store.store([], tokenIDs: [2], for: b)
        #expect(store.snapshot(for: a)?.tokenIDs == [9])
        #expect(store.snapshot(for: b)?.tokenIDs == [2])
    }
}
