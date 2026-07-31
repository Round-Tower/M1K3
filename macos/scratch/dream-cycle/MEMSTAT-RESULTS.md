# MEMSTAT Tier-0 run — 2026-07-30 (first run, idle GPU, app otherwise closed)

Raw log: `memstat-run-20260730.txt` (same directory). Embedder: production
qwen3-embed-512 (`MLXEmbeddingService()` default). Dedupe bar: the live
`MemoryDistillationCoordinator.semanticDedupeThreshold` (0.90).

## The graph (Kev's real container, read-only)

- **147 live nodes** · 0 superseded · 388 edges.
  Kinds: note 93 · decision 17 · profile 17 · preference 14 · episode 6.
- Pairwise census, 10,731 pairs: **1 pair ≥ 0.90** · **51 pairs in [0.75, 0.90)**.
  Distribution peaks at [0.40, 0.45) — a healthy, spread-out cone.
- **Corpus divergence: 349 corpus `.memory` items vs 147 graph nodes (Δ202)**
  — the pre-dual-write backlog. This is Tier 3's actual target population,
  not same-night pairs.

## The probe pairs (challenger #2/#4 — VERDICTS)

| class | min | median | max | ≥ 0.90 | in [0.75, 0.90) | ingest probe |
|---|---|---|---|---|---|---|
| contradictions (10) | 0.686 | 0.858 | 0.969 | 3/10 | 6/10 | **3/10 EATEN** |
| compatibles (10) | 0.550 | 0.733 | 0.768 | 0/10 | 4/10 | 0/10 eaten |
| restatements (5) | 0.892 | 0.934 | 0.957 | 4/5 | 1/5 | 4/5 eaten |

1. **Finding #2 CONFIRMED, regime MIXED.** 30% of the correction class embeds
   at/above the dedupe bar, and the end-to-end ingest probe (real
   coordinator, production embedder) ate exactly those three. The eaten shape
   is the small-lexical-delta value flip (dark/light mode, March/September,
   110→95 cm); proper-noun flips (Dublin→Ardmore, 0.800) currently survive.
   The correction-eating bug is real and quantified.
2. **No cosine bar separates correction from restatement.** Contradiction max
   (0.969) sits ABOVE restatement min (0.892) — moving the 0.90 threshold
   cannot fix #1 without breaking dedupe. Tier 2's ≥ 0.90 disambiguation must
   be content-aware (lexical-delta check or a judge on the ONE candidate
   pair), exactly the branch the spec pre-registered.
3. **Cosine alone cannot arbitrate the mineable band either.** 4/10
   compatibles land in [0.75, 0.90) alongside 6/10 contradictions — a
   write-time supersede search needs contradiction-vs-compatible
   discrimination on the candidate, not a similarity bar.
4. **Dedupe is otherwise healthy:** 0/10 compatibles eaten; 4/5 restatements
   correctly eaten (the 0.892 restatement slipping under the bar is a
   tolerable false-negative — it costs one duplicate row, not a lost truth).
5. **Tier 3 has a measured target:** 51 live mineable pairs + the Δ202
   corpus/graph backlog. Small enough that write-time repair (Tier 2) plus a
   one-shot backfill may cover it without a nightly scheduler — re-check
   after Tier 2 lands.

## What this unlocks (spec §2 gates)

- Tier 1 (date the block): unaffected by this data, already greenlit.
- Tier 2 (write-time repair): **mandatory** (verdict 1) and its mechanism
  question is **answered** (verdicts 2/3: content-aware check, not thresholds).
- Tier 3 (the dream): target measured (verdict 5); decision deferred until
  Tier 2's residue is known — per the spec, the dream stays earned.

Signed: Kev + claude-fable-5, 2026-07-30, Confidence 0.85 (single run, idle
GPU, production embedder + real coordinator end-to-end; probe classes are
10/10/5 hand-authored pairs — directionally strong, not tight confidence
intervals; the 1 real ≥ 0.90 graph pair is counted but not yet identified —
the census reports counts, not IDs, by design §1). Prior: SPEC.md v2 (same
directory).

---

## Tier-2 acceptance re-run — 2026-07-30 (same instrument, post-repair build)

Raw log: `memstat-run-tier2-20260730.txt`. Same 25 probe pairs, same
production embedder, through the REAL coordinator with the write-time repair.

| class | pre-Tier-2 eaten | post-Tier-2 eaten |
|---|---|---|
| contradictions | **3/10** | **0/10** |
| compatibles | 0/10 | 0/10 |
| restatements | 4/5 (silently) | 0/5 (superseded — refresh, one live row) |

- **The eaten-correction bug is CLOSED**: every correction now lands; the
  ≥ 0.90 twin is superseded, never the new fact discarded.
- Restatement "survived" here means SUPERSEDE-refresh, not duplication —
  the exactly-one-live-row invariant is unit-pinned
  (`MemoryCorrectionTests` / `semanticSupersede`); the probe's
  survived/eaten column only counts writes.
- Real-graph census unchanged (read-only): 147 live, 1 pre-existing ≥ 0.90
  pair (it stays until a write touches that fact), corpus divergence Δ202.

Signed: Kev + claude-fable-5, 2026-07-30, Confidence 0.9 (same-day A/B on the
identical instrument + fixture set; the closed bug is the exact failure the
Tier-0 run quantified). Prior: this file (Tier-0 section).
