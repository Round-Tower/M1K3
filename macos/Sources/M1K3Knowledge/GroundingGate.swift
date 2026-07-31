//
//  GroundingGate.swift
//  M1K3Knowledge
//
//  Relevance gate for retrieve-first grounding. Hybrid search always returns
//  top-K — even for "what model are you?" — so ungated injection pollutes
//  every prompt with whatever the store happens to hold, derailing small
//  reasoning models. The gate keeps a hit only when its vector similarity says
//  the query is actually about the store's content; when nothing is topical it
//  injects NOTHING and the model decides via the search_knowledge tool.
//
//  Gates on cosine similarity, NOT rrfScore: RRF is rank fusion — its scale
//  (~(0, 0.0167] per ranking) says how results order, never how relevant any
//  of them is in absolute terms.
//
//  Signed: Kev + claude-fable-5, 2026-06-10, Confidence 0.8 (thresholds are
//  empirical starting points for bge-small — tune via the responder score
//  logs at ⌘R and update the constants). Prior: Unknown
//  Review: Kev + claude-fable-5, 2026-06-12, Confidence 0.9 — kind-aware
//  `relevant` (one order-preserving list for the explicit search floor) +
//  shared `clears` predicate; removed the dead public `filter` (kind-unaware,
//  zero production callers — a divergence trap beside `relevant`).
//  Review: Kev + claude-opus-4-8, 2026-06-12, Confidence 0.85 — chunkThreshold
//  0.62 → 0.68 from a live MCP gate-log measurement (off-domain noise ceiling
//  ~0.63, in-domain floor 0.736; the old 0.62 sat in the noise and leaked a
//  CoT chunk as a "source" for a sourdough query). memoryThreshold left at
//  0.54 (MEMEVAL-governed overlap). verify-at-⌘R on the live MCP loop.
//  Review: Kev + claude-opus-4-8, 2026-06-14, Confidence 0.85 — both bge-era
//  provisionals RE-TUNED from on-device ABSEP + MEMEVAL on the new
//  qwen3-embed-512: chunkThreshold 0.68 → 0.51 (dead-zone [0.315, 0.697]
//  centre, separation doubled vs bge), memoryThreshold 0.54 → 0.39 (recall-
//  first now that qwen3 dropped the negative ceiling 0.556 → 0.422). See the
//  per-constant comments for the measured distributions. verify-at-⌘R.
//  Review: Kev + claude-fable-5, 2026-07-09, Confidence 0.85 — RE-DERIVED for
//  the query-instruction adoption (EmbeddingService.embedQuery →
//  EmbeddingText.forQuery), from on-device KEYEVAL (M1K3_SELFTEST_KEYEVAL,
//  instructed arms of the SAME MEMEVAL/ABSEP fixture sets that set the old
//  floors): chunkThreshold 0.51 → 0.37 (instructed dead-zone [0.234, 0.510]
//  centre — 0.51 sat ON the weakest instructed positive), memoryThreshold
//  0.39 → 0.35 (instructed MEMEVAL: pos min 0.437 / neg max 0.260, CLEAN
//  separation where bare overlapped; suggested midpoint 0.349). New
//  edgeThreshold pins rememberConnected's content↔content bar at the old
//  0.51 — fact-to-fact cosines carry no instruction and did not move.
//  verify-at-⌘R (live keyword recall + no new noise leaks).
//  HONEST CAVEAT: these floors are derived for instructed qwen3-embed-512
//  ONLY. The HashingEmbeddingService fallback (Mac offline; the ONLY iOS
//  embedder today) shares them un-measured — a pre-existing pragmatism this
//  re-tune WIDENS (lower floors, no instruction-driven noise suppression on
//  hashing). Upgrade path: per-embedder floors, or a hashing-arm KEYEVAL
//  bracket, before iOS retrieval quality is tuned in anger.
//  Review: Kev + claude-fable-5, 2026-07-31 — the caveat above is CLOSED:
//  floors are now per-embedder (`EmbedderFloors`, selected by fingerprint at
//  every gate call site), and the hashing arm is MEASURED — deterministically,
//  in CI (HashingFloorMeasurementTests re-derives the MEMEVAL/ABSEP
//  distributions each run). The qwen constants below are unchanged and remain
//  this file's; hashing's rationale lives with its numbers in EmbedderFloors.
//  Confidence 0.85.
//

import Foundation

public enum GroundingGate {
    /// Minimum cosine similarity for a chunk to be injected. BGE-family
    /// embeddings live in a NARROW cosine cone — unrelated pairs commonly
    /// score 0.55–0.7, topical ≈0.74+ — so a "generous" floor passes
    /// everything (proven live 2026-06-10: 0.45 injected arxiv chunks for
    /// "Yo mike, what's up?").
    ///
    /// 0.51 from the ABSEP re-tune (2026-06-14, qwen3-embed-512 on device,
    /// M1K3_SELFTEST_ABSEP) after the bge-small → Qwen3-Embedding swap: the
    /// same 2026-06-13 on-device leakers as OFF-domain queries vs the ML-paper
    /// corpus now score FAR lower — sourdough 0.315, apple-pruning 0.234,
    /// CSS-div 0.209, JS-frontend 0.270 — a noise ceiling of 0.315; the
    /// IN-domain queries floored at 0.697. The dead zone is [0.315, 0.697]
    /// (margin 0.382, vs bge-small's 0.181 on the same fixtures — the swap
    /// MEASURABLY doubled separation). 0.51 is the maximal-margin centre:
    /// 0.19 of headroom to BOTH edges. The old bge-era 0.68 sat jammed against
    /// the in-domain floor (0.697) — still safe, but it gated real hits in the
    /// 0.51–0.68 band for no precision gain now that off-domain noise tops out
    /// at 0.315. The "flat pack = no real match" margin heuristic and more
    /// off-domain fixtures (n=6 here) are the durable upgrade paths.
    ///
    /// 0.37 from the 2026-07-09 KEYEVAL re-derivation (instructed queries —
    /// EmbeddingText.forQuery now applies on every query embed): the same
    /// ABSEP fixtures scored with instructed queries give in-domain floor
    /// 0.510 / off-domain ceiling 0.234 — the old 0.51 sat EXACTLY on the
    /// weakest true positive with zero margin. 0.37 is the new dead-zone
    /// centre (same maximal-margin rule that chose 0.51): 0.14 to the signal
    /// floor, 0.136 to the noise ceiling. The instruction is why this is
    /// safe: it cut the off-domain ceiling 0.315 → 0.234 and the
    /// keyword-register noise ceiling to 0.203 (KEYEVAL probes).
    ///
    /// Since 2026-07-31 these constants are the qwen3-instructed member of
    /// `EmbedderFloors` — the per-embedder seam this file's 07-09 caveat
    /// named. The values (and every measured rationale above) are unchanged;
    /// hashing gets its own measured set (`EmbedderFloors.hashing`).
    public static let chunkThreshold: Float = EmbedderFloors.qwen3Instructed.chunk

    /// Minimum cosine for a fact→fact EDGE in the memory graph
    /// (`rememberConnected`). Content↔content cosines carry NO query
    /// instruction, so this bar deliberately did NOT move with the 07-09
    /// query-side re-tune — it stays at the value chunkThreshold held when
    /// the two-bar doctrine pinned edge formation to it (2026-07-08): a weak
    /// recall hit is one prompt line, a weak edge is permanent graph
    /// structure feeding traversal.
    public static let edgeThreshold: Float = EmbedderFloors.qwen3Instructed.edge

    /// Minimum cosine similarity for a MEMORY hit. Memories are 5–40-token
    /// atomic facts; query-to-short-fact pairs sit LOWER in the cone than
    /// query-to-chunk — measured via M1K3_SELFTEST_MEMEVAL (2026-06-14, real
    /// qwen3-embed-512 on device after the embedder swap): positives
    /// 0.393–0.790 (median 0.628), negatives 0.148–0.422 (median 0.279). The
    /// classes overlap in a thin band [0.393, 0.422] — no clean cut — but the
    /// KEY shift is that qwen3 dropped the NEGATIVE ceiling from bge's 0.556 to
    /// 0.422 (one anomalous pair; the next-highest negative is 0.340), which is
    /// what finally makes lowering the bar safe. 0.39 keeps 22/22 true recalls —
    /// including the two lowest, "Kev lives in Cork" (0.393) and "Kev studied at
    /// UCC" (0.411), the exact identity-fact class whose live recall-failure
    /// drove the swap — at the cost of admitting that single 0.422 negative
    /// (one weak stray bullet). Recall wins the asymmetry: a memory miss breaks
    /// the "I'll remember" promise, a false positive is one do-not-cite line.
    /// The zero-FP alternative is 0.43 (20/22 — loses Cork + UCC); recall-first
    /// chooses 0.39. Per-query normalisation is the upgrade path if strays annoy.
    ///
    /// 0.35 from the 2026-07-09 KEYEVAL re-derivation (instructed queries):
    /// the same MEMEVAL pairs scored with instructed queries give positives
    /// 0.437–0.841 / negatives 0.068–0.260 — the instruction turned the bare
    /// overlap (pos min 0.393 vs neg max 0.422) into CLEAN separation.
    /// Suggested midpoint 0.349 → 0.35: margin 0.087 below the weakest true
    /// recall and 0.09 above the worst negative, and low enough to admit the
    /// keyword register (KEYEVAL instructed keyword positives floor at 0.420)
    /// that the old 0.39 bar was measured missing live on 2026-07-08.
    public static let memoryThreshold: Float = EmbedderFloors.qwen3Instructed.memory

    /// Split gated hits for the two prompt blocks: `.memory` hits (cleared
    /// `memoryThreshold`) feed the WHAT-I-KNOW-ABOUT-YOU block; everything
    /// else (cleared `chunkThreshold`) feeds KNOWLEDGE exactly as `relevant`
    /// would. FTS-only hits (nil similarity) are dropped from BOTH — the
    /// no-keyword-flood rule doesn't care what kind the noise is.
    public static func partition(
        _ hits: [ChunkHit],
        floors: EmbedderFloors = .qwen3Instructed
    ) -> (knowledge: [ChunkHit], memories: [ChunkHit]) {
        var knowledge: [ChunkHit] = []
        var memories: [ChunkHit] = []
        for hit in hits where clears(hit, floors: floors) {
            if hit.kind == .memory {
                memories.append(hit)
            } else {
                knowledge.append(hit)
            }
        }
        return (knowledge, memories)
    }

    /// The same kind-aware bar as `partition`, kept as ONE order-preserving
    /// list — the relevance floor for the explicit search_knowledge path,
    /// where the model needs the fused ranking, not the two prompt blocks.
    /// A hit must clear its bar ON ITS OWN: an FTS-only hit (no vector score)
    /// appeared only in the keyword ranking, never the vector top-K — lexical
    /// coincidence, not relevance — so it is dropped, NOT carried in on a
    /// topical sibling. (Letting it ride along flooded a "what's the weather
    /// in Cork" prompt with 7KB of keyword-matched noise that drowned the
    /// web_search routing — the ⌘R weather bug.)
    public static func relevant(
        _ hits: [ChunkHit],
        floors: EmbedderFloors = .qwen3Instructed
    ) -> [ChunkHit] {
        hits.filter { clears($0, floors: floors) }
    }

    /// The single relevance predicate behind `relevant` and `partition`:
    /// memories clear the memory floor, everything else the chunk floor;
    /// an FTS-only hit (nil similarity) never clears.
    private static func clears(_ hit: ChunkHit, floors: EmbedderFloors) -> Bool {
        guard let similarity = hit.similarity else { return false }
        return similarity >= (hit.kind == .memory ? floors.memory : floors.chunk)
    }
}
