# Long context and decode speed — what the cache geometry actually allows

Status: PROPOSED (2026-09-26). Evidence first, then code — every section names the
measurement that would kill it.

The 2026-09-26 sweep (memory `perf-context-sweep-2026-09-26`) found that two of our
context limits are beliefs rather than properties of the models, and that the
speculative-decoding door we parked has more than one handle. This note records the
geometry, the proposals, and the gates.

## 1. What the caches really cost

| Brain | Layers | Grows per token | Bounded part | Native context |
|---|---|---|---|---|
| Big — gemma-4-12B | 48: 8 full-attention (1 KV head × 512, `attention_k_eq_v`), 40 sliding (8 × 256, window 1024) | ~16 KB (8 × 1 × 512 × K+V × bf16) | 40 sliding layers × 1024 tokens ≈ 335 MB, constant | 262,144 |
| Lil — Qwen3-4B-2507 DWQ | 36 dense (8 KV heads × 128), 8-bit KV | ~78 KB (incl. group scales) | none | 262,144 |
| Pocket — LFM2.5-1.2B | hybrid: conv (MambaCache) + attention | small | conv state, constant | 32,768 |

Source: each model's `config.json` (gemma: `mlx-community/gemma-4-12B-it-4bit`, read
2026-09-26) and the cache classes at mlx-swift-lm e3d4a20e.

**Big's "8192-token window" is ours, not gemma's.** `BrainTier.approximateContextTokens`
(`.big: 8192`) and `HistoryBudgetPolicy` justify it as a `RotatingKVCache(8192)`, but
`maxKVSize` is only ever sent to llama-3 (`supportsCallerKVCapacity`); gemma-4 builds a
`KVCacheSimple` per full-attention layer and a 1024 rotating cache per sliding layer.
Nothing rotates the persona out at 8192. What really limits Big is time: the sliding
layers wrap on every real turn, `isTrimmable` goes false, the cross-turn reuse gate
(`MLXToolCalling`'s `reusable`) vetoes, and every turn re-prefills its whole prompt
(~6 ms/token on M1 Max, 2026-08-09). A 2,120-token history clamp is a latency choice
dressed as a capacity one.

**Lil's 32k is really ~4k of reusable conversation.** `ConversationTailCache.maxSeedTokens
= 4000` binds first: the persona + palette alone is ~1,786 tokens and grounding up to
~1,100, so roughly a thousand tokens of history ride the tail seed. Over the cap, `adopt`
refuses the new tail but KEEPS the previous one (`ConversationTailCache.adopt`, `.overCap`)
— the next turn still reuses a shorter prefix, it does not re-prefill everything (the
"next turn seeds from persona" log line in `MLXToolCalling` overstates it). `HistoryWindow`
(16 turns, 1,500 chars/turn) and the 8,000-token latency ceiling bind after that.

## 2. Proposals, cheapest first

### 2a. Lil: raise the tail cap first, then stop the history sliding
Simplest lever first (challenger, 2026-09-26): scale `maxSeedTokens` with the memory
tier and A/B it alone, with the overCap-keeps-the-old-tail behaviour pinned in a test
before the constant moves. Budget it at 2× — `snapshot` deep-copies the tail for the
turn, so a 12k-token tail is ~0.9 GB retained + ~0.9 GB in flight; on iOS size it from
the `MLXMemoryBudget` / jetsam limit, not physical RAM. Then, if the sliding history is
still the dominant miss: drop old turns in BLOCKS (start index a multiple of the block,
computed purely in `HistoryWindow.render` — no stored anchor), MLX tiers only. If this
works, the latency ceiling's premise ("replay prefill does not amortise",
`HistoryBudgetPolicy`) goes too — decide then whether it rises. **Gate:** a 30-turn
scripted chat, median TTFT per turn and peak RSS, before/after, AC + powermode logged.
**Kill:** peak RSS above the tier budget, or a recall miss on a turn referenced just
past a block boundary (N−1 is always kept, so testing it proves nothing).

### 2b. Persona prefixes survive a relaunch
`savePromptCache`/`loadPromptCache` round-trip in-app via the SelfTest probe
(`MLXBrainProvider+PromptCachePersistence.swift`) — weakly: `toolNames: []` only, judged
by an "ok" substring. Persisting the warmed prefixes turns the launch warm into a load;
the payoff is largest where the prefill is longest (Big, if 2c ever seeds it) and on
iOS relaunches. Guards, all required: (1) never load without an EXACT token-id match
against a fresh render of the current prefix — that one check covers persona, profile,
month, tool schemas and template edits the key does not fingerprint; (2) the key adds
the weights revision pin (ADR 0002) and the mlx-swift-lm revision; (3) files live in
Caches, excluded from backup, with iOS file protection, and clearing the profile
deletes them — the ids are the user's profile text in another form, a new copy with
its own lifecycle; (4) orphan GC on key change. Size: ~90–150 MB per Lil prefix, ~380
MB for Big (its sliding layers are a constant 335 MB). **Gate:** cold-launch to first
token on Lil AND Big, and on an iPhone. **Kill:** load ≥ prefill.

### 2c. Big: long context once reuse survives the wrap
Upstream PR mlx-swift-lm #622 (open) keeps a rewind reserve on rotating caches so an
exact prefix can be reused after the window wraps — the missing piece for gemma-4
cross-turn reuse. Once a pin carries it: re-derive Big's budget from the table above
(KV is ~16 KB/token beyond a constant 335 MB — `attention_k_eq_v` does not halve it, V
is copied before its own norm and both are cached), let the tail seed carry Big's
history, and lift the 2,120-token clamp by measurement. The 2,048 decode cap derives
from the same 8192 and must be re-derived with it; image turns skip reuse entirely and
stay clamped. Peak memory is NOT just the KV: MLX has no fused attention kernel for
head dim 512, so prefill on the 8 global layers materialises a chunk × L score tensor —
measure peak RSS at 8k/16k/32k. **Gate:** the 30-turn chat on Big with reuse on vs off,
plus the security/leak evals at long history (never run on the 4-bit 12B). **Kill:**
reuse that changes greedy output in the first 64 tokens, or #622 stalling upstream
(then a carried patch is NOT worth a fork).

### 2d. Prompt-lookup (n-gram) drafting — M3 and later only
Draft tokens by matching the recent output's suffix against the prompt (RAG chunks,
quoted documents, tool JSON, code being edited) and verify them with the model we
already run. No weights, no drafter memory. Published on Apple GPUs: 1.62× on coding
turns and 1.11× on chat (mlx-optiq, M4 Pro); Oilbird (arXiv 2608.03839) reports 4.4×
on tool-call traces. Upstream: mlx-swift-lm #426 (open). **Not on M1:** measured
2026-09-26 on this M1 Max, verifying 2 tokens through a 4-bit quantized matmul costs
1.86× one token (3 → 2.77×, 4 → 3.61×), so even perfect drafts cap near 1.07×. Gate it
per chip: a Python mlx-lm rig over our own RAG and tool-JSON transcripts on an M3+/M4/M5
first, Swift port only if it clears 1.2× there. **Kill:** < 1.1× on the RAG set.

### 2e. MTP and block-diffusion drafters — DON'T on M1 (measured)
Measured 2026-09-26 on this M1 Max (AC, High Power; mlx 0.32.2, mlx-dspark 0.19.0, Lil
DWQ-2510 against its sha-verified weights, greedy, interleaved ×3): plain 95–101 tok/s;
DSpark 0.63–0.86×, DFlash 0.42–0.66× at every draft cap tried (DSpark 1/2/6, DFlash
1/2/4/7/15), acceptance 0.62–0.71 / 0.31–0.56. The ceiling is the verify, not the
drafter: the per-token matmul cost curve above means even 100% acceptance at cap 1
tops out near 78 tok/s. It also explains MTP's 0.62–0.73× — the fp16/short-draft
re-check is moot. The real porting job on M1 would be a small-batch (2–4 token)
quantized-matmul kernel that reads each weight once, ahead of any drafter. Re-run the
same bench on an M4 Pro / M5 before any Swift port (upstream DFlash2 is #607, open).
Rig + raw runs: the 2026-09-26 session scratchpad (`dspark/bench2.py`, `qmm3.py`).

### 2f. Prefill while the user is still talking — DON'T as written
Grounding is retrieved FROM the question and sits before it in the render
(`AgentRAGResponder`), so the only tokens a partial transcript could prefill early are
the question's own ~30 — under 100 ms. Revisit only if the render ever puts the question
before its grounding.

## 3. Not doing

- Neural Engine / Core AI prefill: the GPU wins at every input length on published
  benchmarks (cadamcat/llms-on-apple-neural-engine), and Core AI ships no LLM path.
- 4-bit KV on Lil: plain affine 4-bit KV degrades small models; 8-bit stays.
- KV quantization on Big: its sliding layers are `RotatingKVCache`, whose
  `toQuantized()` is an unimplemented `fatalError()` upstream.

Signed: Kev + claude-opus-5-5, 2026-09-26, Confidence 0.75 (geometry read from configs
and source and checked by a challenger pass; the M1 speculative verdict is measured
here; every other gain is a published or projected number — hence the gates). Prior:
Unknown
