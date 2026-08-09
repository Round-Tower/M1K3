//
//  PersonaPrefixCache.swift
//  M1K3MLX
//
//  The enabler for richer prompting: M1K3's persona (and the tool specs —
//  Qwen renders TOOLS inside the SYSTEM block) is prefilled into a KV cache
//  ONCE per (model × tools × persona), and every turn starts from a deep COPY
//  of that prefix instead of re-prefilling it. A longer persona stops being a
//  per-turn TTFT tax — it costs once per launch.
//
//  The retained cache is never handed out: `snapshot` returns
//  `copy()`-deep copies (upstream KVCache.copy() materialises new arrays), so
//  turns mutate their own offsets independently. In-memory only — on-disk
//  persistence (savePromptCache) is a follow-up with model-versioning needs.
//
//  Signed: Kev + claude-fable-5, 2026-06-10, Confidence 0.8 (key/store logic
//  tested; the prefill render + trim normalisation is verify-at-⌘R like all
//  MLX generation). Prior: Unknown
//

import Foundation
import MLXLMCommon

/// Identity of one rendered system-block prefix.
struct PersonaCacheKey: Hashable {
    let modelID: String
    let toolsFingerprint: String
    let personaText: String

    init(modelID: String, toolNames: [String], personaText: String) {
        self.modelID = modelID
        toolsFingerprint = toolNames.sorted().joined(separator: ",")
        self.personaText = personaText
    }
}

/// One cached prefix + its token ids (for prefill-savings logging AND
/// cross-turn reuse: a seeded MLXToolTurnSession needs the exact token
/// sequence the cache holds to compute a valid common-prefix reuse).
struct PersonaPrefixSnapshot {
    let cache: [KVCache]
    let tokenIDs: [Int]
    var tokenCount: Int {
        tokenIDs.count
    }
}

/// `@unchecked Sendable`: a single NSLock guards the slot; the retained
/// cache is only ever read to produce copies. NSLock, not Mutex, on purpose:
/// `KVCache` is non-Sendable, and extracting it from a `Mutex` trips region
/// isolation ("inout sending") — the same wall MLXToolTurnSession documents.
///
/// Invalidation is IMPLICIT: the key fingerprints (model × tools × persona
/// text), and the persona text embeds the user profile — a profile edit
/// changes the key, misses the slot, and the prefix rebuilds on next use.
/// `invalidate()` exists only to reclaim memory eagerly.
final class PersonaPrefixCache: @unchecked Sendable {
    /// One entry per rendered prefix. MRU-first.
    private struct Entry {
        let key: PersonaCacheKey
        let cache: [KVCache]
        let tokenIDs: [Int]
    }

    /// TWO, because the provider renders exactly two prefixes in normal use:
    /// the interactive tool-turn one (persona + tool specs) and the plain
    /// one used by background work. A single slot made them evict each other
    /// on every alternation — measured live on 2026-08-09 as a 16-19 SECOND
    /// re-prefill on the next chat turn, with decode healthy at 30 tok/s the
    /// whole time. The pause was never the model thinking; it was M1K3
    /// re-reading its own personality before every answer.
    ///
    /// Kept deliberately small: each entry retains Metal-backed KV arrays for
    /// a ~2k-token prefix across every layer of a 12B model, and
    /// `MLXMemoryBudget`'s ceiling is back-pressure, not a cap (the 2026-07-14
    /// lesson). Raise this only with a measured RAM snapshot in hand.
    static let defaultCapacity = 2

    private let lock = NSLock()
    private let capacity: Int
    private var entries: [Entry] = []

    init(capacity: Int = PersonaPrefixCache.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    /// A deep, independently-mutable copy of the cached prefix — or nil when
    /// no entry matches the requested render.
    func snapshot(for requested: PersonaCacheKey) -> PersonaPrefixSnapshot? {
        // Grab the refs under the lock, copy OUTSIDE it: KVCache.copy()
        // materialises new Metal-backed arrays per layer (a pure read of the
        // source), and holding the lock for that would block store/invalidate
        // (brain-switch path) for the whole copy. Lock-free safety rests on
        // TWO guarantees: ARC — `held` keeps the snapshotted arrays alive even
        // if a concurrent store/invalidate drops the entry mid-copy — and
        // immutability: retained arrays are never mutated after store.
        lock.lock()
        let held: (cache: [KVCache], tokens: [Int])? = {
            guard let index = entries.firstIndex(where: { $0.key == requested }) else { return nil }
            // A HIT is a use: move to front so the eviction candidate is always
            // the genuinely coldest entry, not merely the oldest stored.
            let entry = entries.remove(at: index)
            entries.insert(entry, at: 0)
            return (entry.cache, entry.tokenIDs)
        }()
        lock.unlock()
        guard let held else { return nil }
        return PersonaPrefixSnapshot(cache: held.cache.map { $0.copy() }, tokenIDs: held.tokens)
    }

    func store(_ cache: [KVCache], tokenIDs: [Int], for newKey: PersonaCacheKey) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll { $0.key == newKey }
        entries.insert(Entry(key: newKey, cache: cache, tokenIDs: tokenIDs), at: 0)
        // Dropping the Entry releases its KVCache refs — the Metal arrays go
        // with them once no in-flight snapshot still holds a copy.
        if entries.count > capacity { entries.removeLast(entries.count - capacity) }
    }

    /// Drop every slot (persona text changed — e.g. a profile update — or the
    /// caller wants the memory back).
    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }
}
