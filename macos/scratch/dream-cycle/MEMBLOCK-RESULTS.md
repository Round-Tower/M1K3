# MEMBLOCK Tier-1 probe — 2026-07-30 (two on-device runs, both brains)

Raw logs: `memblock-run-v1-20260730.txt` (dates only) and
`memblock-run-v2-20260730.txt` (dates + conflict clause) in this directory.
Scenario: in-memory store seeded through the production EmbeddingText
composition with a dated contradiction — "Kev lives in Dublin." (~400 days
ago) vs "Kev lives in Ardmore." (2 days ago) — plus a neutral dated fact
("collie named Bran", 30 days ago). Question asked through the REAL
AgentRAGResponder live path: "Where do I live?"

## Run v1 — dated lines only

- **Lil (Qwen3-4B-2507): PASS** — "Kev lives in Ardmore … that's the last
  solid pin we had." Recency preference from dates alone.
- **Big (gemma-4-12B): HEDGE** — "you're either in Ardmore or Dublin. I've
  got both on the record." Sees both facts, does not use the recency signal.

## The iteration

One clause appended to the block header: "…use naturally, do not cite;
**where facts conflict, trust the most recently learned**". Pinned by test.

## Run v2 — dates + conflict clause: PASS on both brains

- **Big:** "You're in Ardmore." (25.6s first turn, 12.4s second) — decisive,
  correct, terse, in-register.
- **Lil:** "Right now, Kev lives in Ardmore." (8.0s) — and its dog answer
  renders the seeded 30-day date as "4 weeks ago" in prose, i.e. the model
  is actively consuming the recency metadata.
- No latency anomaly; register intact on both.

## Honest caveats

- Lil decorates memory answers with invented pseudo-citation labels
  ("[Context]", "[Personal observation, 4 weeks ago]") despite "do not
  cite" — a pre-existing Lil register quirk on memory-only grounding (not
  introduced by the dates; observed in both arms), logged as a follow-up
  candidate for the refusal/marker ledger, not chased here.
- Scope: this probes the DATED build's behaviour; the same-binary undated
  control would need the private prompt renderer widened for eval. The
  bounded risk argument: the no-memory prompt is BYTE-PINNED unchanged
  (MemoryGroundingTests), so the changed surface exists only when memories
  ground in — and that surface is what both runs watched, on both brains.
- Single run per arm; latencies are one sample each.

Signed: Kev + claude-fable-5, 2026-07-30, Confidence 0.85 (live-path probe
through the production responder + embedder on both production brains; the
one gemma failure mode found was fixed by a pinned clause and re-proven
same-day). Prior: MEMSTAT-RESULTS.md (PR #83).
