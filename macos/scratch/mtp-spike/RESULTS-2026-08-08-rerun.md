# MTP rerun on the unblocked upstream — ENGAGES, and it still loses (2026-08-08)

**Setup:** identical instrument to 2026-07-19 (`GemmaMTPSpike` via
`M1K3_SELFTEST_MTP=1`, greedy + production repetition guard on both legs,
fresh caches, blockSize 4), but on the bumped pin: mlx-swift-lm main
`c97539da` (2026-08-06), which carries **#415** (the Gemma4Unified MTP entry
points + `gemma4_unified_assistant` drafter registration — the exact gap
that failed gate 2 in July) and **#506** (stand down from speculation before
the sliding cache wraps). Target `mlx-community/gemma-4-12B-it-4bit` via
MLXVLM, drafter `mlx-community/gemma-4-12B-it-qat-assistant-4bit`.

## The numbers

| fixture | prompt | baseline | MTP | speedup | accept | faithful? |
|---|---|---|---|---|---|---|
| short-no-wrap | 25 tok | 17.0 tok/s | 18.2 tok/s | **1.08×** | 52% (14/27) | exact-match |
| medium-wraps-mid-decode | 588 tok | 26.3 tok/s | 20.8 tok/s | **0.79×** | 42% (243/573) | **DIVERGES@314** |
| long-wrapped-at-prefill | 2072 tok | 28.5 tok/s | 24.9 tok/s | **0.87×** | n/a (0/0) | exact-match |

RAM both-resident: active 6430MB, peak 7659MB, footprint 7013MB.

## Gate verdicts (pre-registered in July)

1. **LOADS** — PASS (was already passing).
2. **ENGAGES** — **PASS, newly.** July: sticky passthrough from round 1, 0
   drafted, "main model did not emit drafter state". Now: 52% accept on the
   short fixture. **Upstream #415 did exactly what it said.**
3. **FAITHFUL** — PASS on the never-wraps fixture (byte-identical greedy).
4. **SURVIVES THE WRAP** — **FAIL.** The medium fixture reports #506's
   stand-down (`passthrough: sliding cache wrapped mid-stream — MTP rewind
   unavailable`) *and still diverges at char 314*. Under greedy sampling
   speculative decoding is required to be byte-identical; it isn't. The
   stand-down happens, but not before rejected-token K/V has already
   polluted the ring. The July hypothesis (rewind no-ops post-wrap) is
   **confirmed**, and #506 mitigates the crash-class, not the correctness
   one.

## Why this is a NO for M1K3 production (the load-bearing reason)

gemma-4-12B's sliding window is **1024 tokens**. M1K3's measured production
prompt (2026-07-20 prompt-size instrument) is:

- persona + tools KV seed: **1380 tok** — *already over the window on its own*
- open-chat total: 1863 tok · grounded-Q total: **2998 tok**

So every real M1K3 turn lands in the `long-wrapped-at-prefill` regime, where
MTP cannot engage at all and the iterator's passthrough path runs at
**0.87× baseline**. The July bonus finding holds and is now quantified twice:
the passthrough fallback is *slower than plain generate* (synchronous
per-token eval), so wiring MTP without an engagement bail-out would make
every production turn ~13-21% slower.

**MTP's ~3× headline applies to short-prompt, unwrapped generation. M1K3
does not have any of those on the interactive path.**

## What would change the verdict

1. A prompt that fits 1024 tokens. Our persona alone is 1380 — this needs
   the persona/tool-spec budget cut roughly in half, which is a #102-shaped
   project, not a flag.
2. Upstream fixing the post-wrap rewind so the wrapped regime is faithful
   *and* engages (issue class is visible at `MTPSpeculativeTokenIterator`'s
   rewind no-op; #506 only stands down).
3. A Big with a larger sliding window.

Until one of those, MTP stays **parked with a measured reason** — an upgrade
on July's "parked because upstream can't". The instrument re-runs unchanged.

*Signed: Kev + claude-opus-5, 2026-08-08, Confidence 0.9 (three fixtures,
one run each, on-device with the app closed and the GPU idle; the numbers
are single-run with no variance bars, but the verdict rests on the regime
argument — our prompts are 1.8-2.9k against a 1024 window — which no amount
of variance changes. The divergence is a hard reproducible failure of the
algorithm's own greedy invariant). Prior: Kev + claude-fable-5
(RESULTS.md, 2026-07-19).*
