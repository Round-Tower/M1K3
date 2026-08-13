# Voice performance — where the time actually goes

**Status:** live doc. First written 2026-08-13, off the first end-to-end
measurements the voice loop has ever had.

Kev's framing, which is the right one: *"a lot of people look at intelligence and
performance at the same time. They want things instantaneously now."* This doc
records what a spoken turn costs, what moves it, and — as importantly — the
things that look like they'd move it and don't.

---

## 1. The measurement

Before 2026-08-13 nothing measured a voice **turn**. `ttft` logged per
*generation* (prefill ms, decode tok/s), but a turn is retrieval + a grounding
cap + an agent loop that may run several generations + a synthesiser. So the
only question a voice user asks — *how long after I stopped talking did M1K3
start talking back* — had no number anywhere in the app.

`VoiceTurnTimeline` (M1K3Voice) now logs one line per turn, both shells:

```
voice turn: first sentence 2140ms · synth 610ms · first audio 2750ms · answer 8900ms · 4 sentences
```

Read it with:

```bash
/usr/bin/log show --predicate 'subsystem == "app.m1k3" AND category == "stt"' --last 1h --style compact | rg 'voice turn'
```

### What the first readings said

Driven live over MCP against Kev's real store — Lil resident
(`Qwen3-4B-Instruct-2507-4bit`), persona prefix warm, M1 Max:

| prompt | prefill | decode |
|---|---|---|
| 822 tok | **2052 ms** | 84 tok @ 63 tok/s |
| 1401 tok | **3045 ms** | 175 tok @ 61 tok/s |

- **Marginal: 1.71 ms per prompt token** (`993 ms / 579 tok`)
- **Fixed floor: ~646 ms**
- Retrieval + grounding gate: **66–225 ms** (negligible — do not optimise this)

### ★ The conclusion that reorders the work

**Prefill dominates time-to-first-audio. Decode barely registers.**

Voice mode speaks at the first *sentence* — roughly 15 tokens, ~250 ms of
decode — while prefill is paid **in full** before a single token exists. So:

```
time to first audio ≈ 646 ms  +  1.71 ms × (prompt tokens)  +  ~250 ms decode  +  synth
```

Every 100 tokens of grounding is ~171 ms the user waits, before M1K3 has said
anything. That is the whole game.

---

## 2. What we did about it

| Change | Effect | Where |
|---|---|---|
| `spokenTokenBudget = 400` (was 1100) | ~1.2 s off every spoken turn | `GroundingBudgetPolicy` |
| iOS gains a grounding budget at all | mobile had been running Big's 1100 on a 4096-token tier | `AppCore.swift` |
| Kokoro `preload()` warms the graph | first sentence of a launch no longer compiles Metal kernels | `KokoroSynthesizer` |

The spoken budget is justified twice, and the second reason matters more than
the first: **nobody reads seven document chunks aloud.** The typed budget is
sized for an answer you can scan and re-read; a spoken one is a few sentences.
The latency win is a consequence of getting the product right, not a trade
against it.

---

## 2a. ★ The biggest lever, found and pulled: the conversation WAS re-prefilled every turn

> Status: FIXED same day — PR #122 (see the BUILT block below). The measurement
> and the killed design are kept because they are why the fix has this shape.

Measured 2026-08-13, three consecutive turns, from `toolTurnSession reuse`:

```
reuse: 1786/2390 tok from cache, prefilling  604
reuse: 1786/3441 tok from cache, prefilling 1655
reuse: 1786/2712 tok from cache, prefilling  926
```

**1786 every time.** That is exactly the persona prefix — and not one token
more. `CrossTurnCacheReuse` is real and working, but the `MLXToolTurnSession` is
built **per chat turn**, seeded from `PersonaPrefixCache` and nothing else, so
its reuse only ever serves the agent loop's own iterations *within* a turn. The
context line, the history replay and the grounding are re-prefilled from scratch
on every single turn of a conversation.

At 1.71 ms/token that is the dominant remaining cost, and unlike grounding it
**grows with the conversation**: `HistoryBudgetPolicy` replays up to 3000 chars
(~857 tokens, ~1.5 s) and a voice chat reaches that quickly. Turn 3 above spent
2032 ms prefilling 926 tokens it had almost entirely prefilled before.

### Why the reuse stops where it does

Cache after turn N holds `[persona][ctx][hist_N][grounding_N][q_N][answer_N]`.
Turn N+1 renders `[persona][ctx][hist_N + q_N + a_N][grounding_N+1][q_N+1]` on a
**fresh session**, so there is no live cache to match against at all — the seed
is the persona, and the common prefix is therefore the persona.

### ★ The challenger pass ran (2026-08-13) — append-only is DEAD, and here's why

The obvious fix — one session per conversation, append-only transcript — was
pressure-tested and killed. Do not resurrect it without new facts:

1. **It cannot exist on Big, and Big is where prefill hurts.** gemma-4-12B runs
   `sliding_window: 1024` on 40 of 48 layers; `prefixIsReusable` returns false
   for any prefix over 1024 tokens, and the app already logs *"persona prefix
   SKIPPED — longer than the sliding window"* on Big. **The 1.71 ms/token above
   is Lil's number; Big's measured prefill is ~6.1 ms/token** (13.1–14.5 s for a
   2357-token prompt, `MLXGemmaProvider`). The architecture change would deliver
   exactly zero to the slow tier.
2. **The session's transcript is not the user's transcript.** Every native
   tool-using turn synthesises its final answer through a flat fallback prompt
   *outside* the session (`AgentRAGResponder.synthesiseOverEvidence`); the
   session records the suppressed in-loop conclusion the user never saw. Today
   history replays from `ChatSession.messages` (the displayed text), so it
   doesn't matter. Make the session transcript authoritative and the model's
   memory of what it said diverges from what it said — silently, and more the
   more tools are used. Mini-routed turns (interim bridge, delegate_deep) would
   likewise be holes in the MLX transcript.
3. **The margin over a far cheaper change is ~200–430 tokens/turn** (~0.35–0.7 s
   on Lil, 0 on Big) — because turn N+1's prompt already carries only its *own*
   grounding; append-only would additionally pin every prior turn's grounding
   into an unbounded KV (~78 KB/token on Lil at kvBits=8) that `clearCache()`
   cannot reclaim, in the mode (voice) that barges in most — and barge-in's
   `finish()` nils the cache.

### ✅ BUILT + MEASURED (same day, PR #122): change the seed, not the lifetime

The endorsed design shipped as two coupled changes, and the on-device A/B
passed as the merge gate:

1. **`Goal:` renders LAST** in the native user message
   (`LocalAgent+Native.buildNativeGoal`) — it was the only per-turn-volatile
   text sitting ~30 tokens in. A/B'd on-device (both brains, tool-use +
   open-chat, live path, powermode 0): lil's pass set IDENTICAL to master,
   big's equal-or-better — no fragility signature.
2. **`ConversationTailCache`** (single slot, no conversation id):
   `finish()` hands the end-of-turn cache over instead of dropping it;
   `makeToolTurnSession` seeds from the tail before falling back to the
   persona prefix. Divergence fails soft through the common-prefix arithmetic.

**The acceptance log, from the A/B run itself:**

```
toolTurnSession reuse: 1401/1855 tok from cache, prefilling 454, seed=persona   ← first turn
toolTurnSession tail adopted: 1855 tok retained for the next turn
toolTurnSession reuse: 1839/1858 tok from cache, prefilling  19, seed=conversation
toolTurnSession reuse: 1839/1861 tok from cache, prefilling  22, seed=conversation
```

**Prefilling 17–23 tokens per turn** — the goal is genuinely the only
divergence, ~750 ms/turn saved at 1.71 ms/token even in the historyless
eval shape; a history-carrying conversation saves more.

Shipped safeguards: adoption requires every layer trimmable (which IS the
gemma tier gate — its real turns wrap, so it never stores) · 4000-token cap
(~300 MiB retained ceiling on Lil, evictions logged loud) · background
utilities skip the tail both ways · the reuse **source**
(`seed=persona|conversation|none`) in the log line so a working seed is
distinguishable from a warm persona.

Honest limit, stated up front: the replay is a suffix window (8 turns / 3000
chars), so when it slides the common prefix collapses back to
persona+preamble+context and one full re-prefill is paid. Append-only had a
longer runway but the same eventual collapse with a bigger bill. Neither escapes
"reset every N turns"; this one admits it and costs a fraction as much.

---

## 3. Things that look like wins and are not

### Speculative decoding — real, but smaller than it looks

Upstream support exists on our pin (`MLXLMCommon/SpeculativeDecoding.swift`,
`SpeculativeDecodingConfig`) and our provider already builds the `ChatSession`
it hangs off, so wiring is genuinely cheap. But:

- It speeds **decode only**, and decode is ~250 ms of time-to-first-audio.
  Against the full answer it's worth real seconds; against *the number Kev
  feels*, it is close to noise.
- ⚠️ **It conflicts with the persona-prefix KV cache.** `ChatSession` rebuilds
  BOTH caches from the full input when the main cache took a suffix-only path
  without a matching draft cache (`reusedMainCacheWithoutDraft`). We construct a
  fresh session per turn, so the draft cache would be fresh every turn — meaning
  every turn re-prefills the whole persona. That trades a decode win for a
  prefill loss, in the term that dominates. Any attempt must solve session reuse
  first.

**Verdict: not next.** Revisit once prompt size is genuinely minimal, and only
with the cache interaction designed rather than discovered.

### A leaner tool palette for voice — actively harmful

The tool palette is part of the `PersonaPrefixCache` key. Measured 2026-08-13: a
self-query turn's smaller palette missed the cache and cost a **6.2 s prefix
rebuild**. A "voice palette" would buy a few hundred prompt tokens (~0.3 s) and
pay seconds for them, every time the user alternated modes.

**Standing rule: tune the grounding, never the palette.** See issue #121. This is
also a second and stronger reason for the existing *"cut iterations, not tools"*
ruling.

### An abstain/similarity threshold — measured dead (2026-08-12)

Best-hit cosine on Kev's real store overlaps between answerable and no-answer
queries (0.497 vs 0.489). No threshold separates them. Recorded here so the
next latency idea doesn't arrive as a threshold in disguise.

---

## 4. The local speech model (Kokoro) — the upgrade question

Kev, 2026-08-13: *"the actual local speech model… is not as high fidelity as I'd
like for the size, and I'm sure there's new variants coming out now."*

He's right that the field moved. `mlx-audio-swift` — the same project our
vendored MLX Kokoro port came from (2026-07-18, PR #58) — now carries ~13 TTS
models in Swift, including **Qwen3-TTS**, **Orpheus**, **Marvis TTS**,
**Pocket TTS**, **IndexTTS**, from ~80M to ~600M with 4/6/8-bit quantisation.

### ★ But most of them break two things Kokoro gives us for free

**(a) They are autoregressive; Kokoro is not.** Kokoro (StyleTTS2 lineage) is a
**single forward pass** per chunk. The LLM-style TTS models *decode tokens in a
loop*. That reopens the question `challenger` killed on 2026-07-25: two MLX
decode loops on one Metal device stall each other, `MLXMemoryBudget` is
back-pressure and not a cap, and `clearCache()` is process-global. A 0.6B
autoregressive TTS speaking while Lil generates is the dual-resident-MLX
architecture we rejected, arriving through a side door.

**(b) They give no word alignment.** `KokoroWordTiming` derives word timings from
the phoneme alignment, and those timings drive the **karaoke highlight** and the
avatar's speaking sync. An autoregressive TTS emits audio tokens, not phoneme
durations. Losing that is losing a shipped feature, not a nice-to-have.

### So the honest shortlist

1. **Cheapest first — is it the model or the voice?** We ship `bm_daniel` and our
   own bespoke G2P. Some of the "fidelity for the size" gap is plausibly voice
   preset and phonemisation, both of which are ours to fix and neither of which
   costs an architecture. **Measure before porting.**
2. **A non-autoregressive upgrade** keeps both properties. This is the search to
   run — not "the best TTS", but "the best *single-forward-pass* TTS with phoneme
   durations".
3. **An autoregressive model** is a real option only if we accept losing karaoke
   sync AND have an answer for the two-decode-loops problem (e.g. TTS on ANE/Core
   ML rather than Metal, which sidesteps the contention entirely).

Any candidate must also be **pure MLX** — ONNX Runtime was removed deliberately
in PR #58 because it had no visionOS slice.

---

## 5. Background conversations and the "call API" question

Kev, 2026-08-13, on the Claude Android app: *"it now diverts through calls, the
call API… it's coming over as a call, which I think is a great feature."*

That's Android's `ConnectionService`/telecom stack. **iOS has no sanctioned
equivalent for an assistant.** CallKit exists, but it is for VoIP apps, and
adopting it purely to obtain background mic priority is App Review exposure with
no functional payoff.

What the field actually does: **ChatGPT's iOS "Background Conversations" is a
background `AVAudioSession` plus a Live Activity** — not CallKit. That is the
Apple-blessed shape, and it is the same **Live Activity / Dynamic Island phase
already scoped in project memory on 2026-07-29**, which named the real costs
honestly: background-audio mode, keeping the loop alive in the background (today
we deliberately exit on `scenePhase`), and a widget extension.

Also worth knowing before anyone plans around it: **Apple reserves the wake-word
layer for Siri.** There is no OS-level custom wake word; an always-on hot word
means running our own detector on a background audio session, with the battery
and privacy story that implies.

### ★ The distinction that matters for this thread

**None of this makes anything faster.** CallKit, Live Activities and background
audio are *continuity* features — they let a conversation survive leaving the
app. They do not touch prefill, decode or synthesis. Worth building, on its own
merits, in its own phase. Not part of the performance work.

On macOS none of it applies: the app is already running.

---

## 6. Owed

- **A real spoken-turn reading from the instrument this doc is built on.** Every
  number above comes from the MCP/chat/eval path; no HUMAN voice turn has yet
  been timed end-to-end. First voice-mode run on a build carrying #120+#122
  settles it — read with the `log show` line in §1, plus
  `rg 'seed=conversation'` for the tail engaging mid-conversation (the eval
  proved the mechanism 2026-08-13; the felt conversation is the remaining half).
- The 400-token spoken budget's effect on answer **quality** is unmeasured.
- The Kokoro graph warm's saving is verify-by-launch (metallib wall) — the
  `kokoro warm:` log line reports it.

---

*Signed: Kev + claude-opus-5, 2026-08-13, Confidence 0.85 (the latency
arithmetic is read off live instruments on Kev's machine, not inferred; the
prefix-cache and speculative-decoding interactions are read off upstream source
on our own pin. Honest opens: the TTS model survey is from web sources and one
repo README rather than a build, so treat the model list as a starting point and
not a spec; no spoken turn has been measured by the new instrument yet.)
Prior: Unknown.*
