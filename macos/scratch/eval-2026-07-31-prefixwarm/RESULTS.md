# PREFIXWARM re-measure + the Caches-purge discovery — 2026-07-31

Raw logs beside this file. Debug build off merged master (post-#89/#90/#91),
GPU otherwise idle (live app closed), SelfTest container-config pattern.

## PREFIXWARM (mode 1: cold vs warm persona-prefix build, first-token delta)

| tier | model | cold first-token | warm first-token | delta (what the launch warm buys) |
|---|---|---|---|---|
| Lil | Qwen3-4B-Instruct-2507-4bit | 2261 ms | 160 ms | **~2.1 s** |
| Big | gemma-4-12B-it-4bit | 8826 ms | 338 ms | **~8.5 s** |

- Supersedes the stale `AppEnvironment.swift` figures ("~1.9 s lil / ~3.3 s
  big", 2026-07-11/12 — both pre-reshuffle). Lil moved a little; **Big's
  prefix build nearly tripled** (12B vs e4b) — the post-load warm is carrying
  ~8.5 s of first-turn latency, much more load-bearing than documented.
- embedwarm same runs: cold 3.4–4.6 s / warm ~15 ms (consistent with the
  ~4.0 s figure; unchanged).
- Caveat: single run per tier, same-afternoon conditions; the Big run's
  weights had just been re-downloaded (cache purge, below) but the prefix
  build is compute-bound — load-time effects don't reach the measured delta.

## ★ The incidental discovery: macOS was purging the brains

Both runs started from `localMB=0` — 2507 (2.1 GB) AND 12B (6.5 GB) were
ABSENT from `Library/Caches/models/`, though 12B had been verified-present at
16:51 the same afternoon (unified log, `weight-integrity`). Kev's own app had
re-downloaded 12B from zero at 16:29–16:51 (the "still loading" wall during
the roadmap riff). Disk was at ~15 GiB free; `Library/Caches` is
purge-eligible; the system cache purger ate the weights — twice in one
afternoon. The embedder, parked in `Documents/` by a different 2.x default,
never vanished once. Retroactively explains the 07-14 "production Lil weights
were GONE" mystery.

**Fix (same day):** `ModelStoreLocation` — weights → Application Support
(non-purgeable) + backup exclusion + one-time same-volume migration.
Live-fired: `migration: moved=3 skipped=0`, 8.4 GB renamed across, Caches
models dir gone, 12B loaded with zero re-download
(`selftest-migration-verify-20260731.txt`).

*Signed: Kev + claude-fable-5, 2026-07-31, Confidence 0.9 (numbers from the
production SelfTest harness on device; the purge attribution rests on the
log-evidenced present→absent timeline with no app process in between, the
survival asymmetry vs Documents, and measured disk pressure — circumstantial
but tight; single-run latencies carry no variance bars). Prior: Unknown*
