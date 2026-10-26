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
| Lil — Qwen3.5-4B (since 2026-10-08) | 32 layers: 8 full-attention (4 KV heads × 256, `full_attention_interval` 4) + 24 GatedDeltaNet (MambaCache, never trims) | ~32 KB fp16 / ~16 KB at kvBits 8 | the 24 recurrent states, ~25–50 MiB per cache copy | 262,144 |
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

**Status 2026-10-25 — the cross-turn seed is in, as an exact checkpoint, not a trimmed tail.** The
September shape (adopt the live cache in `finish()`, trim to the common prefix) could never fire on a
shipping tier: Lil's recurrent layers and Big's wrapped window put the tool turn in checkpoint mode, where
no live cache survives a turn. What ships instead (`ExactPrefixReuse.tailCut`, `ConversationTailCache
.adoptCheckpoint`): the first send of a turn splits its exact prefill at the common prefix with the previous
turn's first render — turn N's render and turn N+1's share exactly through N's replay — copies the cache
there (with its model state) into the slot, and the next turn plans over [persona, tail, rolling], longest
strict prefix wins. The tail lags one exchange and needs no layout knowledge; a tail the conversation left
loses the plan to the persona. Capped by MEASURED bytes (512 MiB; Lil's tail reads ~135–170 MiB at
2,700–3,600 tokens, Big's ~370–382 MiB — its ~335 MiB sliding state before a token, so the September "scale
the token cap" is moot: tokens mislead across tiers). Desktop only; `-conversationTailCheckpoint NO`.
Measured (§3, second table): reuse grows every message from the third, per-message prefill falls ~1 s on
Lil and up to 6.7 s on Big — **until the HistoryWindow slides at message 10**, when the common prefix
collapses to the persona and both brains pay the September cost again. So the sliding history IS the
dominant miss now, exactly as this section guessed, and block eviction is the next lever; its gate stands.

**Status 2026-10-26 — block eviction is in** (`HistoryWindow.Budget.evictionBlockTurns`): after the newest-first
fill the window's start snaps UP to a multiple of the block (fewer turns, never more, so every bound holds; the
newest turn survives; an orphaned M1K3 opener drops too; a snap that would halve a char-limited window is skipped).
Six on the MLX tiers, four on spoken Big (its 8-turn ceiling), one on Mini; `-historyEvictionBlock N`. The
distillation trigger reads `minimumKeptTurns` (the ceiling less a block), so a snapped-away turn is distilled
before it is forgotten. Measured (§3, third table): past message 10 the tail hits on **one message in three**
on both brains, not the two in three the arithmetic promised, because the LCP cut lags a turn: the first
render after a shift shares nothing, the second adopts the long tail, the third reuses it. On a hit Big's
transcript prefill is 5.8 s against 11.8 s on a miss, Lil's 1.8 s against 2.8 s; peaks unchanged. The lag is
the next lever: a caller-marked stable prefix (the plan's `StableUserPrefix`) would cut at the replay boundary
on the first render after a shift and lift the rate to two in three at the same block — or a block of eight
buys one in two at a floor of ten turns. The recall probe (a turn referenced just past a boundary) is still
owed: the curve records answer lengths, not answers.

**Status 2026-10-26, later — the caller-marked stable prefix is in**, and the lag with it. The responder knows
where its grounding stops being stable (the context line + the replay, `groundingWithStablePrefix`); the agent
maps that onto the message it lands in (`LocalAgent.stablePrefix`, `ToolTurnOptions.stablePrefix`); the MLX
session renders the transcript cut there on its first send and hands both renders to `tailCut(stable:)`, the
longer valid cut winning. Measured (§3, fourth table, mains): past the window the tail hits on **two messages
in three** on both brains (14/21; the miss is the first render after each block shift, by construction), and
every adoption was cut at the stable prefix (58/58 in the log); messages 3–9 hit 7/7, the message-3 lag gone
too. Big's transcript prefill past the window: 4.4 s on a hit against 9.4 s on a miss, a median of 4.8 s
where the sliding window paid 10–12 s. The recall probe is still owed.

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

## 3. Measured 2026-10-25 — where a Release turn goes

The first baseline on what users run (Release, AC, High Power, `--router dispatch --thinking tier`, ×3, M1 Max 64 GB;
`docs/evals/2026-10-25-speed-baseline-{lil,big}.json`, every score carrying `GenerationFigures`, #683). Medians.

| | Lil (Qwen3.5-4B) | Big (gemma-4-12B) |
|---|---|---|
| decode | **83 tok/s** | **31 tok/s** |
| prefill past the persona seed | ~600 tok/s (357 tok in 587 ms) | ~210 tok/s (360 tok in 1,708 ms) |
| open-chat turn · first token | 2.7 s · 0.66 s | 5.8 s · 1.8 s |
| grounded-Q turn | 1.4 s | 1.7 s |
| tool-use turn · first token | 4.9 s · 3.8 s | 7.0 s · 5.2 s |
| security turn · first token | 4.0 s · 3.6 s | 5.5 s · 4.8 s |
| share of the turn before the first token | 59 % | 56 % |
| share of the turn decoding | 40 % | 40 % |
| MLX peak | 4.3 GB | 8.8 GB |

**The route decides the turn, not the model.** Same brain, same build, by the router's stage (`routeStage`):

| route | trials | Lil turn · first token | Big turn · first token |
|---|---|---|---|
| chat (plain generation) | 48 | 1.45 s · 0.65 s | 2.7 s · 1.8 s |
| head (group head picked) | 18 | 1.65 s · 0.70 s | 3.9 s · 2.1 s |
| **picker (Apple's model picked)** | **63** | **4.9 s · 3.8 s** | **7.1 s · 5.1 s** |

The picker route costs **~3.1 s (Lil) / ~3.4 s (Big) before the first token** over the chat route, and half the
trials take it — every security fixture, every tool ask the group head does not resolve. The pick is one guided
generation on a FRESH `LanguageModelSession(instructions:)` per turn (`AFMToolPicker`), measured at ~1.2 s in the
2026-09-26 spike; the rest is the session's own start. Nothing logged the pick until `tool pick: picker → … in Nms`
(this branch); the first arm evals carry it. Levers, cheapest first, each wanting its own paired eval: a prewarmed
picker session kept ready per menu (`prewarm()` after each use); the group head covering more of what the picker
decides (it already answers in 0.05 s); overlapping the pick with the plain generation on the GPU (AFM runs beside
it) and cancelling the loser. **Debug is not the product:** the October arms ran Debug, where Lil decoded 28 tok/s;
decode is 40 % of a Release turn, and the wait before the first token is the larger half.

**Every message re-prefills the conversation, on both routes, on both brains** (the 20-message chat-curves, same
build and power, `docs/evals/2026-10-25-chatcurve-{lil,big}-{agent,dispatch}.txt`; the agent route is the tool
session in checkpoint mode, whose transcript prefill is the `extend` column; the dispatch arm is the Mac's plain
route, whose prefill is the generate's own past the persona seed). Reuse never grows past the persona (Lil 2,444,
Big 2,184 tokens); from message 6 the history is ~1,400–2,500 tokens and it is prefilled again every turn:

| per message, from message 6 | Lil agent | Lil plain | Big agent | Big plain |
|---|---|---|---|---|
| tokens re-prefilled | ~2,100–2,400 | ~1,300–1,900 | ~2,400–2,700 | ~1,500–1,800 |
| time | 2.6–3.5 s | 2.0–2.8 s | **10–12 s** | **6–7.7 s** |
| slope (total prefill ms / message) | 60 | 117 | 494 | 250 |

None of the 129 baseline trials took the agent route (the eval's tool asks dispatch outside the loop), so the
scorecards above are single-turn plain generations; the curves are what a conversation costs. §2a's cross-turn
seed is worth 2–3 s a message on Lil and 6–12 s on Big, from the second exchange — far more than the September
arithmetic said. The render plateaus at the HistoryWindow's 16 turns, so the per-message cost caps there too.

**With the cross-turn tail checkpoint (same day, same build line, agent route; `docs/evals/2026-10-25-chatcurve-
{lil,big}-agent-tail.txt`):** reuse grows every message from the third — Lil 2,520 → 3,338 tokens by message 9,
Big 2,262 → 3,774 — and the per-message transcript prefill (`extend`) falls with it. From message 10 the
HistoryWindow's `suffix(16)` drops the oldest exchange each turn, the common prefix of consecutive renders
collapses to the persona + preamble (Lil 2,535, Big 2,277), and the cost returns to the table above:

| per message | Lil, tail off | Lil, tail on | Big, tail off | Big, tail on |
|---|---|---|---|---|
| messages 3–9: reuse (tokens) | 2,444 flat | 2,520 → 3,338 | 2,184 flat | 2,262 → 3,774 |
| messages 3–9: `extend` | 2.1 → 3.5 s | **1.5–1.9 s** | 6.1 → 11.2 s | **5.7 → 4.5 s** |
| messages 10–20: reuse | 2,444 | 2,535 | 2,184 | 2,277 |
| messages 10–20: `extend` | 2.6–3.3 s | 3.0–3.8 s | 10.5–12.1 s | 9.8–11.6 s |
| tail checkpoint stored | — | 135–169 MiB | — | 370–382 MiB |
| MLX own peak (max over the curve) | 4.44 GB | **4.84 GB** | 8.64 GB | 9.36 GB |

(Shipped head 1f557f97; the script's answers differ run to run, so the message-10+ Lil figures ride a render that
grew to ~5,000 tokens.) Lil's peak sits 160 MB under its 5 GB own-peak cap (`BrainTier.lilOwnPeakCapMB`): the first
send of a turn holds the pristine copy, the work cache, the tail copy and the rolling copy at once. A lower
`maxCheckpointBytes` for Lil, or consuming the tail without the rolling copy on the first send, is the headroom lever
if a longer render crosses it. The win is real and bounded by the window: block eviction (§2a) is what extends it
past message 9.

**With block eviction (2026-10-26, head 2d6a197d, agent route, 30 messages, `docs/evals/2026-10-26-chatcurve-
{lil,big}-agent-{blocks,block1}.txt`; the stage now runs the tier's LIVE window — Lil 28,000 chars, Big 7,420 —
where the 10-25 curves ran the eval's default 8,000-char window):** messages 3–9 are unchanged; from message 10 the
block holds the window's start for three messages and the tail hits on the third of each:

| messages 10–30 | Lil, block 1 | Lil, block 6 | Big, block 1 | Big, block 6 |
|---|---|---|---|---|
| tail hits | 0/21 | **7/21** | 0/21 | **7/21** |
| `extend` on a hit | — | **1.8 s** (1.6–2.2) | — | **5.8 s** (4.3–7.5) |
| `extend` on a miss | 3.0 s (2.6–4.0) | 2.8 s (2.4–3.3) | 17–44 s † | 11.8 s (9.6–14.1) |
| MLX own peak (max over the curve) | 4.82 GB | 4.85 GB | 9.33 GB | 9.35 GB |

Run on battery (powermode 0), so the seconds pair within the run, not with the mains table above. † Big's block-1
run was the last of four and ended at 7 % battery; its extends climbed from 17 to 44 s over the run (the same
~2,300-token miss took 10–14 s in the block-6 run minutes earlier), so read that column's reuse, not its clock.
The floor is unchanged on typed Lil (12–16 of 16 turns kept); the lag of the LCP cut is what caps the rate.

**With the stable-prefix marker (2026-10-26, head 15b93a09, mains, agent route, 30 messages,
`docs/evals/2026-10-26-chatcurve-{lil,big}-agent-marker.txt`; block 6 as above):**

| messages 10–30 | Lil, block 6 (LCP cut) | Lil, block 6 + marker | Big, block 6 (LCP cut) | Big, block 6 + marker |
|---|---|---|---|---|
| tail hits | 7/21 | **14/21** | 7/21 | **14/21** |
| `extend` on a hit | 1.8 s | **1.7 s** (1.5–1.9) | 5.8 s † | **4.4 s** (4.1–5.5) |
| `extend` on a miss | 2.8 s | 3.4 s (3.0–6.7) | 11.8 s † | 9.4 s (8.5–10.5) |
| `extend`, median over 10–30 | 2.6 s | **1.8 s** | 10.6 s † | **4.8 s** |
| messages 3–9: hits | 6/7 | 7/7 | 6/7 | 7/7 |
| MLX own peak (max over the curve) | 4.85 GB | 4.73 GB | 9.35 GB | 9.19 GB |

† the block-6 columns are this morning's battery run; the marker columns ran on mains. Compare the hit
fractions and the hit-to-miss ratio within a column, not the seconds across. Every tail in the marker run was
cut at the stable prefix (58 of 58 adoptions); the remaining miss is the first render after a block shift,
which no prefix of the previous render can cover.

## 4. Not doing

- Neural Engine / Core AI prefill: the GPU wins at every input length on published
  benchmarks (cadamcat/llms-on-apple-neural-engine), and Core AI ships no LLM path.
- 4-bit KV on Lil: plain affine 4-bit KV degrades small models; 8-bit stays.
- KV quantization on Big: its sliding layers are `RotatingKVCache`, whose
  `toQuantized()` is an unimplemented `fatalError()` upstream.

Signed: Kev + claude-opus-5-5, 2026-09-26, Confidence 0.75 (geometry read from configs
and source and checked by a challenger pass; the M1 speculative verdict is measured
here; every other gain is a published or projected number — hence the gates). Prior:
Unknown
Review: Kev + claude-fable-5.1, 2026-10-25 — §4: the first Release baseline (both brains, per route) and the
Lil row of §1 corrected to Qwen3.5-4B's geometry (the dense Qwen3-4B left Lil on 2026-10-08). The picker route's
3 s before the first token, on half the trials, is one finding (the timed pick then read a median 3.1 s over 45
picks); the four mains chat-curves are the other: every message re-prefills the conversation on both routes, 2–3 s
on Lil and 6–12 s on Big. Confidence 0.9 (all measured on one build, one power state).
Review: Kev + claude-fable-5.1, 2026-10-25 (later) — §3 gains the four mains chat-curves as a table (agent and plain
routes, both brains); the battery smoke's figures are superseded by them.
Review: Kev + claude-fable-5.1, 2026-10-25 (evening) — §2a status: the cross-turn seed shipped as an exact checkpoint
cut at the common prefix of consecutive renders (not the September trim), capped by measured bytes; §3's second
table measures it on both brains: reuse grows from message 3, Big's per-message prefill 11.2 → 4.5 s by message 9,
and the HistoryWindow slide at message 10 takes it all back — block eviction is the next lever. Confidence 0.85
(one build line, one power state, agent route only; the plain route is phase 2).
Review: Kev + claude-fable-5.1, 2026-10-25 (night) — §3's second table re-read on the shipped head (the lazy tail copy):
Lil's own peak 4.84 GB against its 5 GB cap, the headroom levers named; a single-turn kill-switch A/B (Lil ×3 ON vs OFF,
paired, identical content, medians inside the pick's variance) clears the first-send path. Confidence 0.85.
Review: Kev + claude-fable-5.1, 2026-10-26 — §2a status (block eviction shipped, one hit in three, the LCP lag named as the next
lever) and §3's third table (block 1 vs 6, both brains, 30 messages, live window; the battery caveat on Big's block-1 clock).
Review: Kev + claude-fable-5.1, 2026-10-26 (later) — the stable-prefix marker: §2a's lag is closed (two hits in three past the
window, 58/58 cuts at the marker) and §3 carries the fourth table (block 6 with and without the marker, both brains).
