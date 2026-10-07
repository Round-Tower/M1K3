# M1K3 1.1 — the Gemma-shaped release (on-machine session plan)

Drafted 2026-10-06 from a cloud planning session (research only, no code
changed). Written for a Claude Code session **on Kev's Mac**: everything below
that runs MLX, launches the app or measures RAM needs Apple Silicon. Read
`macos/CLAUDE.md` first; the standing carry-forwards in the root `CLAUDE.md`
(land.sh, one PR per stream per day, `challenger` before thresholds, quit the
live app before an eval) all apply.

**Direction (Kev, 2026-10-06):** 1.1 is Gemma-shaped. Get Qwen 3.5 running too,
as the honest competitor in the bake-off.

**Status (2026-10-06, evening):** Stream 0 done (no bump needed). Stream A code + tests
written on `feat/chateval-multimodal-fixtures`, `swift test` and the vision baseline
owed. Stream B shootout running, full ×3 bake-off queued overnight. Findings that
change the plan are in **§5 Progress and learnings** — read it before acting on §1–§2.

**Status (2026-10-07, 00:30):** #497 landed (`0c64af9d`): vision eval kind, tier thinking, peak RAM,
E4B vision + template heal, EmbeddingGemma 2 reference. The ×3 bake-off proper is running overnight
(incumbent → Qwen3.5 → E4B, one brain per launch). New: **Stream G** (gemma-4 speed) and an **E2B**
entry — both from Kev: "Lil has been tuned specifically for this up until now, but we need to keep
our minds open."

---

## 0. What changed upstream (the why)

| Release | What it is | Why it matters to M1K3 |
|---|---|---|
| **EmbeddingGemma 2** (2026-10-06, Apache 2.0) | 740M modular embedder on Gemma 4: 270M text/code core + optional 170M vision + 300M audio encoders. One **768-d** space for text, code, image, video, audio. MRL → 512/256/128. 8K context. ~191 MB RAM text-only, ~567 MB all modalities. MTEB Code +14% over v1. Runs on transformers, sentence-transformers ≥6.1, MLX (Python), llama.cpp, Ollama, LiteRT. | Replaces Qwen3-Embedding-0.6B with a smaller text core, and makes **memory multimodal**. No mlx-swift support found yet. |
| **Gemma 4 checkpoint refresh** (2026-07-15/16) | Every Gemma 4 checkpoint re-issued: tool-calling + truncated-response fixes, less "laziness", bigger vision token budget (sharper OCR). **Corrected 2026-10-06:** for E4B and 12B the weights did NOT change (`model.safetensors` hash identical before/after) — the refresh is the **chat template** (`chat_template.jinja`, "null handling, reasoning preservation, turn-tag balance", 07-15) plus `response_template` in `tokenizer_config.json` (07-20). | Plausibly fixes the **E4B "No response" bug** (`docs/MODEL_CHOICES.md:86`, observed 06-22 — the model reasoned itself into an empty answer). Needs a re-run **with the new template** — a post-refresh *conversion* is not the point (see §5). |
| **Gemma 4 12B** (2026-06-03, already Big) | Encoder-free: 48×48 image patches and 40 ms / 640-sample audio frames linearly projected into token space. 256K ctx. | Its **audio input is unused** — the VLM load path already keeps the audio embedder resident (`MLXBrainProvider.swift:1070`). |
| **Qwen3.5 small** (2026-03: 0.8B/2B/4B/9B) | Natively multimodal, GatedDeltaNet hybrid. | We left Qwen3.5-4B for its prefill cost; mlx-swift-lm **#225 (asyncEval prefill) fixed that** and is already in our pin (`Package.swift:129`). Cheap to re-audition. |

> Not confirmed: a *new* small-Gemma fix released on 10-06. If one exists, fold
> its checkpoint into Stream B instead of the July refresh.

## 1. Where the code stands (verified 2026-10-06 on master `369b468`)

- **Tiers** — `Sources/M1K3Inference/BrainTier.swift`
  - mini = Apple FM (L200) · pocket = `LFM2.5-1.2B-Instruct-4bit` (L204)
  - lil = `Qwen3-4B-Instruct-2507-4bit-DWQ-2510` (L216, ~2.15 GB, **text-only, default on ≥16 GB**)
  - big = `gemma-4-12B-it-4bit` (L224, ~7.4 GB peak, Mac ≥16 GB, never on mobile L362)
  - defaults: `recommendedByMemory` L450-485; gates: `minimumPhysicalMemoryGB` L344-364
- **Vision** — Big via MLXVLM (`usesVLMLoadPath`, exact allow-list `"gemma-4-12b"`, `MLXBrainProvider.swift:1082`); Mini via AFM attachments. E4B is excluded: upstream `Gemma4Unified` sanitize lacks the KV-shared-layer fix → `keyNotFound layers.24.self_attn.v_proj`.
- **Embeddings** — `Sources/M1K3MLX/MLXEmbeddingService.swift` (Qwen3-Embedding-0.6B, 1024 → MRL 512, L91-92). EmbeddingGemma v1 was rejected: its `sanitize` fatals on load with our pin (L18-23). Fingerprint `mlx/<name>/d<dim>/mlx-swift-0.31` (L66-73) drives an automatic, atomic re-index (`KnowledgeStore.reindexEmbeddings` L186-240; `AppEnvironment.swift` L1673-1708, L2110, L2233, L2332-2360). Per-embedder similarity floors: `Sources/M1K3Knowledge/EmbedderFloors.swift` (qwen3Instructed L46).
- **Pins** — `Sources/M1K3MLX/PinnedWeights.swift` (regen: `tools/weights/pin_weights.py`, ADR 0002). mlx-swift-lm at main `ee673d6a`; mlx-swift 0.31.6. `M1K3MLX` links MLXEmbedders + MLXLLM + MLXVLM.
- **Eval** — `ChatEvalFixture` (`Sources/M1K3Eval/ChatEvalFixture.swift:241`) has `prompt` + `seedDoc` only: **no image/audio field**. Runner: `tools/eval/run_chateval.py --direct --model lil=<id> --save-to docs/evals/<name>.json` (see `docs/BENCHMARKS.md` "Reproducing it", the macOS 27 stdout route). Retrieval fixtures: `Sources/M1K3Knowledge/*EvalFixtures.swift`.
- **Audio-to-model** — not shipped (`scratch/gemma4-audio-spike/SPIKE.md`: E4B batch-only, 30 s cap).

---

## 2. Streams, in order

Each stream is roughly one day = one PR. Streams A and B can run the same day
(A is code, B is mostly waiting on evals). Mark each `[ ]` as you go.

### Stream 0 — Check the pin before B and C (an hour)

Any upstream fix B or C needs (the E4B KV-shared-layer sanitize, a Gemma-4
embedder, Qwen3.5 vision) arrives through mlx-swift-lm. `macos/CLAUDE.md` says the
tag 3.32.3 carries everything our revision pin needs, and that moving to it means
also moving mlx-swift to ≥ 0.32.3 in the same change.
- [x] Diff `ee673d6a..3.32.3` (and `..main`) for: `Gemma4Unified` sanitize / shared KV layers, `EmbeddingGemma` / Gemma 4 embedders in MLXEmbedders, `qwen3_5` in MLXVLM. **Done 2026-10-06 — no bump needed for B; verdict in §5.**
- [ ] (not needed for 1.1 so far) If a bump is worth it, run it probe-first (`swift package resolve`). Then run the **gemma-4 native tool-call smoke** (`M1K3_SELFTEST_CHATEVAL_BRAINS=big M1K3_SELFTEST_CHATEVAL_KINDS=tool-use`) and a voice launch check, because Kokoro links raw MLX. The bump is its own PR (dependencies risk surface).

### Stream A — Multimodal eval fixtures (do first; everything else is judged by it)

Goal: ChatEval can score image and audio turns per brain.

- [x] `swift package clean` — n/a: fresh worktree `.build`.
- [x] Add `images: [String]` to `ChatEvalFixture`, defaulted empty (no call site changes). **`audio` deferred to Stream E** — an unused field ahead of its runner is dead code; add it with the wiring.
- [x] New `TaskKind.vision`. (`audio` kind deferred with the field — `everyKindCovered` would demand ≥ 5 fixtures for it.)
- [~] 16 vision fixtures over 13 images (receipts ×2, bar chart, two macOS-style dialogs, Swift + Python code screenshots, whiteboard, dense policy page, counting, bus timetable, parking sign, settings UI). **Module resources** (`Sources/M1K3Eval/Resources/VisionFixtures`), not test resources — the app's eval stage reads them at runtime. Drawn by `tools/eval/make_vision_fixtures.swift` (ours by construction, answers known). Toward ~30: add a photo-like scene + a multi-image turn next.
- [x] Route fixture images through the real path: `AgentRAGResponder.answerStreaming(_:images:history:onActivity:)` — the chat UI's own call. n/a via `ChatEvalScore.notApplicable` (see §5: an all-skip score used to read as a pass).
- [x] Unit tests: `VisionFixturesTests` (images only on vision, every asset resolves to a PNG, blind markers, n/a excluded from report counts) + Python (`brains_page`, `run_chateval.summarise`) n/a exclusion. Python green; **`swift test` + app build owed** (deferred off the bake-off's CPU).
- [ ] Verify-by-launch: one vision run on mini (`_AFM_NATIVE_TOOLS=1`, see §5) + big. Save as `docs/evals/2026-10-XX-vision-baseline.json`.

Gate: `swift test` green; baseline JSON committed.

### Stream B — The Lil bake-off (Gemma 4 E4B vs Qwen3.5-4B vs incumbent)

Goal: decide whether the default brain can see (and hear).

Candidates (**verify exact hub ids on `mlx-community` before running; never `hf download` to pre-seed** — cache poison):
- incumbent: `mlx-community/Qwen3-4B-Instruct-2507-4bit-DWQ-2510`
- `gemma-4-E4B-it` 4-bit **with Google's post-07-15 chat template** → `mlx-community/gemma-4-e4b-it-OptiQ-4bit` (template sha `0a2c8073…` = Google's current; mixed 4/8-bit, 6.56 GB on disk vs 5.17 GB uniform — not apples-to-apples on size). `mlx-community/gemma-4-e4b-it-4bit` (07-06) still serves the **stale** template (`2f1b4d75…`) — don't run it bare (§5).
- `Qwen3.5-4B` 4-bit → `mlx-community/Qwen3.5-4B-MLX-4bit` (base_model `Qwen/Qwen3.5-4B`, 3.06 GB, `qwen3_5`, vision config present). Thinking model — the template pre-opens `<think>`; already handled (`templatePreOpensThink`; tool format `.qwen35` since 2026-10-07, was `.xmlFunction`).
- phone tier side-bout: `Qwen3.5-2B` vs pocket `LFM2.5-1.2B` (and `LFM2.5-2.6B`, already a noted candidate)

Steps:
- [x] Quit the live app (the runner does it, `--no-relaunch` per run, `open` at the end of the chain).
- [~] **2026-10-06 shootout** (×1, fast kinds: open-chat, tool-use, reasoning, refusal, security, world-knowledge, instruction-following, sycophancy) → `docs/evals/2026-10-06-lil-shootout-<model>-x1-ac.json`; then the full ×3 all-kinds chain overnight → `…-lil-bakeoff-<model>-x3-ac.json`. Order: E4B-OptiQ, Qwen3.5-4B, incumbent. App = TF build 453 (`--commit tf-build-453`: no GitCommitSHA in store builds).
- [ ] Text + tools, per candidate: `python3 tools/eval/run_chateval.py --direct --name lil-bakeoff-<model> --brains lil --model lil=<id> --repeats 3 --save-to docs/evals/2026-10-XX-lil-bakeoff-<model>.json`
- [ ] E4B specifically: re-check the no-response bug with the open-chat fixtures and "How are things M1K3?" (`MODEL_CHOICES.md:86`). Record whether the July refresh fixed it.
- [ ] Qwen3.5-4B: confirm prefill is no longer CPU-heavy (Activity Monitor + `tools/eval/power_receipt.py`). Tool dialect is `.qwen35` (since 2026-10-07; was `.xmlFunction`).
- [ ] Vision (needs Stream A): extending `usesVLMLoadPath` is required for each.
  - E4B: ~~blocked on the `Gemma4Unified` KV-shared-layer sanitize~~ — **probably unblocked at our pin** (§5): E4B is `model_type=gemma4` → MLXVLM `Gemma4`, fixed upstream by #384 (2026-07-15, in our pin). One launch with E4B on the VLM path decides it; then widen `usesVLMLoadPath` and fix the stale comment at `MLXBrainProvider.swift:1077`.
  - Qwen3.5-4B: MLXVLM **has** `qwen3_5` at our pin (`Libraries/MLXVLM/Models/Qwen35.swift`) — vision is reachable by widening `usesVLMLoadPath`. Main's #642 (drop MTP tensors in VLM sanitize) only matters for checkpoints carrying an MTP head.
- [ ] Record per candidate: pass rate by kind, ⌀latency, tok/s, **peak RAM**, power. Update `docs/MODEL_CHOICES.md` decision log.
- [ ] `challenger` on the conclusion before any tier swap.

Decision rule (challenged 2026-10-06; Kev added the RAM + vision-load gates): swap Lil only if
1. **vision load is proven first** — one launch shows the candidate loading through the VLM path
   (`usesVLMLoadPath` widened) and answering a vision fixture; until then no text result counts;
2. **peak RAM is recorded and within a cap** (proposal: ≤ 4 GB for Lil on a 16 GB Mac — set it
   before the run, not after);
3. the winner is ≥ incumbent on text/tool kinds (within noise over 3 repeats) **and** adds vision.
Not adopted (2026-10-06): a written paired per-fixture margin and a latency cap — note E4B's
median turn is 5.6× the incumbent's (real cost, see §5), so latency stays a judgement call. E4B's ~5.25 GB vs 2.15 GB is acceptable on 16 GB Macs; on mobile it means raising the 8 GB floor or keeping Qwen on phones.

If Lil swaps: new pin via `pin_weights.py`, new `BrainTier` backing, MODEL_CHOICES + `site/brains` regenerated, release notes. That is its own PR (risk surface: dependencies/weights → `--passes 2`, inferred).

### Stream C — EmbeddingGemma 2, text core first

Goal: swap the embedder; prove it on retrieval before any multimodal work.

- [ ] **Spike (half day):** does `MLXEmbedders` at our pin know a Gemma-4-based embedder? **Confirmed no** (2026-10-06: MLXEmbedders has Bert / Gemma3 / LFM2Bidirectional / NomicBert / Qwen3 at pin and at main; #654 — EmbeddingGemma v1 bidirectional attention — still open). Main's #679 "component-aware checkpoint loading" may make the text-core-only load a declared component instead of a key filter — read it before porting. Then either port it (we already run `Gemma4Text`; model the v1 `EmbeddingGemma` file but use `Model.update(modules:)`, never mutate `@ModuleInfo` after init — the v1 fatal), or wait for upstream and say so in MODEL_CHOICES.
- [ ] Load **only the text core** (270M). Check the checkpoint layout — whether encoders are separable safetensors or need a key filter at load.
- [ ] Add `EmbedderRegistry.embeddingGemma2` at **dimension 512** (MRL), so storage stays the same shape; the fingerprint change triggers the existing re-index.
- [ ] Query/document prompts: use the model card's task prefixes through `EmbeddingText.forQuery` / document side.
- [ ] Re-measure `EmbedderFloors` (chunk / memory / edge) on the existing `*EvalFixtures.swift`. **Thresholds → `challenger` first** (carry-forward).
- [ ] A/B: retrieval fixtures + `grounded-Q` ChatEval with each embedder; RAM and embed throughput on a large knowledge store.
- [ ] Pin weights; default switch only if it wins. Users get the re-index on next launch (deferred under heat already).

Gate: retrieval ≥ Qwen3-Embedding on every fixture family, re-index verified on a real store, floors signed.

### Stream D — Multimodal memory (the 1.1 headline, after C)

Goal: images, screenshots and audio live in the knowledge graph beside text.

- [ ] Lazy-load the vision encoder (+170M) only when an image is ingested or queried; drop it under memory pressure.
- [ ] GRDB migration in `KnowledgeStore.swift`: `modality` column + thumbnail/blob reference (migrations live inside `*Store.swift` → land.sh reads them; plan two passes).
- [ ] Ingest: attachments already in chat (`AttachmentStore`) → embedded on add. Query: text → finds images ("the whiteboard photo about pricing").
- [ ] Retrieval fixtures with images; floors per modality pair (text↔image will sit lower than text↔text — measure, don't guess).
- [ ] UI: image results render as thumbnails in grounded answers; citations still work.
- [ ] Privacy copy: everything on-device; nothing new leaves the machine. PCC paths unchanged (ADR 0010).

### Stream E — Big hears: Gemma 12B audio (batch)

- [ ] Spike: feed a WAV through MLXVLM `UserInput` audio to gemma-4-12B. Upstream state 2026-10-06: #400 (Gemma4Unified audio + video in the processor) and #392 (native audio encoder) both **open** — expect to carry or wait. Does mlx-swift-lm's `Gemma4Unified` wire the audio embedder end to end? Measure length cap, RAM, latency.
- [ ] If it works: an `ask_recording` path for call recordings (`Sources/M1K3Calls/StereoCallRecorder.swift`) and voice memos — "what did they commit to?". Batch only; the mic stays on WhisperKit / Apple Speech.
- [ ] Wire Stream A's `audio` kind; score against transcript-based `CallSummaryEval`.

### Stream F — Quick win: image turns on Lil escalate

Independent of B; ship it if B doesn't swap Lil within the week.
- [ ] Read `Sources/M1K3Inference/AttachmentRouting.swift`: what happens today when an image is attached while Lil is active?
- [ ] Route that turn to Big when RAM allows (same gate as `delegate_deep`), else Mini's AFM vision; tell the user which brain looked.

### Stream G — gemma-4 speed: the sliding window and prefix reuse (keep an open mind)

Why: Lil's runtime has been tuned around a dense Qwen3 — trimmable caches, cross-turn prefix
reuse, quantised KV. Every gemma-4 candidate pays a tax that is partly **ours**, not the model's:
E4B ran 5.6× the incumbent's latency at ×1. Before a gemma is ruled out of Lil or mobile on speed,
split what is the runtime from what is the model.

Facts (read 2026-10-07 on `695600b9`):
- `slidingWindow(forModelID:)` returns **1024 for any id containing "gemma-4"**
  (`MLXBrainProvider.swift:1158`). E4B's `config.json` says **512**; 12B's 1024 is measured
  (GemmaMTPSpike). E2B unread.
- The persona prefix is ~1878 tokens, over either window, so `prefixIsReusable` (L1174) declines to
  build it and **every turn re-prefills the whole persona** (the 2026-08-09 measurement: 12.5 s per
  build on 12B). The veto exists because a wrapped `RotatingKVCache` reports `isTrimmable == false`
  and MLXToolCalling's `reusable` gate needs a trim.
- No quantised KV on gemma: Gemma4Text calls `cache.update` directly (upstream fatalError).

Hypotheses, ranked, each with the check that confirms or kills it:
1. **Snapshot-and-copy beats trim.** Reuse needs a *copy* of the post-prefix cache, not a trim of a
   used one. If a wrapped `RotatingKVCache` round-trips through `state` + `metaState`, a long persona
   is reusable every turn. Check: those setters in mlx-swift-lm @ `ee673d6a` (`KVCache.swift`); then a
   spike where greedy answers are identical with and without the restored snapshot on 3 fixtures.
2. **Prefill dominates.** Check: TTFT vs decode tok/s, E4B vs incumbent, from the overnight
   transcripts. If decode dominates instead, 1 buys little — the cost is the VLM path or full-width KV.
3. **The real window, per model**, from `config.json`'s `sliding_window`, not the name. Correctness
   first (E4B is 512), and it feeds 1 and prefill step sizing (L1149).
4. **A leaner persona for small tiers.** Under 1024 tokens, 12B's reuse works today with no runtime
   change. A persona-quality trade-off — `challenger` first.

Exit: E4B median live-path latency within **2×** the incumbent's on the same fixtures (5.6× today);
greedy-identical answers with reuse on and off; `slidingWindow` read from config with a test per
family. Then re-run the E4B (and E2B) columns. Not a 1.1 blocker: it decides whether a gemma loses
Lil on merit or on our plumbing.

---

## 3. Spikes and later ideas (not 1.1 commitments)

- **Two-stage retrieval (MRL):** scan at 128-d, rerank top-K at full width. ~6× smaller scan; matters on iPhone as memory grows. Two floors → `challenger`.
- **"What am I looking at?":** ScreenCaptureKit front-window capture → Mini/Big vision, as a hotkey and an MCP tool; opt-in per capture; optionally embedded into memory. Screen-recording permission = risk surface.
- **One embedder for the router:** `ToolNeedRouter` (NLEmbedding, English-only) could share EmbeddingGemma 2's resident text core → multilingual routing. Only if routing latency holds.
- **The Gemma ladder:** if E4B wins Lil, Lil and Big share the `gemma4` dialect + template → one persona LoRA for both (`docs/lora-vs-qlora-and-memory.md`). gemma-4-26B-A4B stays the parked delegation brain for ≥32 GB (ROADMAP L305-310).
- **Musician's sketchbook:** audio-encoder search over voice memos / loops ("find takes like this hum"). Two-hour spike first — unknown how well the encoder handles music vs speech.
- **Mood-board search:** image-embedding search over a chosen Photos album ("warm, grainy, 70s"). Natural Vision Pro "senses" fit — visionOS main-camera access is enterprise-only, so photos/windows, not live camera.

## 4. Session rules of thumb

- Bake-offs on the Mac with the live app quit; Debug verify-by-launch per `CLAUDE.md` (never exec the binary for UI checks; the eval `--direct` route is the exception, it is headless).
- Every eval JSON goes to `docs/evals/` with `--notes` provenance; MODEL_CHOICES gets the signed decision.
- Batch same-day fixes into one PR; land at the end of a stretch with `macos/tools/ci/land.sh <PR>` (no `--passes`: the gate infers it — weights/dependencies infer 2).
- Two push-wait-fold rounds per PR max; overflow → follow-up issue.

## 5. Progress and learnings (2026-10-06)

Signed: Kev + claude-opus-5-5, 2026-10-06, Confidence 0.8, Prior: the plan above was
drafted the same day in a cloud planning session (research only); this section and
the in-place corrections are the on-machine session's.
Review: Kev + claude-opus-5-5, 2026-10-06 21:45 — shootout table added (×1, 57 trials/brain):
incumbent 55, E4B 50 (51), Qwen3.5 39 with 14 think-budget empties. Confidence 0.7 on the read —
one repeat; the ×3 overnight run is the evidence the decision rule asks for.
Review: Kev + claude-opus-5-5, 2026-10-06 22:40 — critical pass (challenger, verified): the ×3 run
was stopped; the harness is fixed first. Decision rule gains a proven vision load + a peak-RAM
cap. Confidence 0.8 on the findings; E4B 53/57 after hand-adjudicating two scorer misfires.
Review: Kev + claude-opus-5-5, 2026-10-06 23:40 — the fixed harness built and launched: Qwen3.5 fair
re-test 22/24, E4B vision proven (13/16), vision baseline (Mini 1/16 — open), Stream C slice 1.
Confidence 0.8; Mini's cause is UNVERIFIED.
Review: Kev + claude-opus-5-5, 2026-10-07 18:00 — the Qwen3.5 gap measured from the unified log: all
prefill (0/3232 reused, 6.8 s a turn vs 0.2 s), decode equal. `challenger` CHANGE folded into the order
of work: positions on MLXVLM first, then an exact seed that survives kvBits. Confidence 0.9 on the cause.
Review: Kev + claude-opus-5-5, 2026-10-07 17:30 — Kev's call "Qwen3.5 as the new Lil" put to a short
shootout (AC, 7d376521): **not yet — speed, not quality**. Tools at tier 17/20 @ 17.3 s vs incumbent
20/20 @ 5.5 s; thinking always 20/20 @ 30.5 s but chat runs away (4/18 empty at 170–246 s). Cause read
from source: Qwen35's linear-attention layers hold a `MambaCache` (never trimmable), so cross-turn reuse
is off and every turn re-prefills persona + palette + history. Next: an exact-seed snapshot for the
tool session (pocket's LFM2 trick), then router-gated thinking. Confidence 0.75 on the cause (the
mechanism is certain; its share of the 3× is not yet measured). Same hour: measured from the unified
log: prefill is the whole gap (6.8 s vs 0.2 s a turn; decode equal). Confidence 0.9.
Review: Kev + claude-opus-5-5, 2026-10-07 16:30 — Mini vision investigation opened: the attach path is
compiled in; a live URL-vs-CGImage test is written; AFM is `modelNotReady` right now. Confidence 0.5 —
two live hypotheses, one test to decide.
Review: Kev + claude-opus-5-5, 2026-10-07 16:00 — the `datetime` miss root-caused as a malformed call
(orphan `</parameter>`); the empty-turn steer measured and backed out; the upstream issue drafted.
Confidence 0.9 (the raw rejected text is in hand).
Review: Kev + claude-opus-5-5, 2026-10-07 15:15 — #499 landed (bd1ec024) + issue #500 live; the Qwen3.5
tools A/B and the reasoning-only empty turn (the parser theory tested and disproved by launch).
Confidence 0.85 on the mechanism (the 16-token turns + upstream's documented reasoning drop).
Review: Kev + claude-opus-5-5, 2026-10-07 14:30 — Qwen3.5 vision launch-proven (14/16, tools 9/10 on the
VLM path, 4.56 GB); it leads the "Lil sees" question. Confidence 0.7 — ×1, the ×3 column is owed.
Review: Kev + claude-opus-5-5, 2026-10-07 13:30 — midday progress: #498 landed, #499 (deps + the
freshness tooling) open with the smoke A/B (Big −27% at constant power mode), per-turn hold on the
next branch. Confidence 0.9 on the smoke numbers (20/20 each arm, n=20 per brain).
Review: Kev + claude-opus-5-5, 2026-10-07 11:30 — pre-push review folded: the display-sleep trigger
stays CONFIRMED, the App Nap mechanism is now marked UNVERIFIED with its deciding test, and the app
hold is App-Nap-only (`.userInitiatedAllowingIdleSystemSleep`). Confidence 0.9 trigger, 0.5 mechanism.
Review: Kev + claude-opus-5-5, 2026-10-07 10:00 — the stall section rewritten: the "one BPE word"
mechanism was WRONG (a benchmark disproved it). Two real causes: display-sleep throttling (both
edges, both runs) and swift-transformers 1.1.9's String-keyed BPE on Gemma's `▁` (1,183 → 8 ms on
1.3.4, same ids). Confidence 0.9 on both; the 10.3 GB RAM peak stays open.
Review: Kev + claude-opus-5-5, 2026-10-07 09:00 — E4B landed: text 88.8% on content (5 better / 10
worse vs the incumbent), vision 43/48, own peak 10.3 GB. No swap under the rule; the incumbent holds
until the stall is fixed and latency/RAM re-measured. Confidence 0.85 on the text read, 0.4 on any
gemma latency or RAM figure until then.
Review: Kev + claude-opus-5-5, 2026-10-07 08:45 — overnight results (incumbent 92.0 / Qwen3.5 93.1
content, E4B pending) and the stall FOUND by sampling: Gemma prompts tokenize as one BPE word in
swift-transformers' naive `bpe`. Confidence 0.9 on the location (3 samples + the tokenizer config);
0.5 on why it grows across fixtures — open, instrumented next.
Review: Kev + claude-opus-5-5, 2026-10-07 00:30 — #497 landed; the ×3 bake-off running. Added
Stream G (gemma-4 speed: the hard-coded window, the re-prefilled persona, snapshot-and-copy reuse)
and the E2B entry (other slots, not Lil). Confidence 0.6 on hypothesis 1 — the cache setters are
unread; 0.85 that E2B doesn't belong in Lil.

### Stream 0 — pin verdict (`ee673d6a`; 3.32.3 = `3b339ad6`; main +20 commits)

| Question | Answer | Evidence |
|---|---|---|
| E4B shared-KV sanitize | **Fixed upstream and in our pin** for the MLXVLM `Gemma4` class | #384 merged 2026-07-15, pin is 127 commits ahead; #553 closed as its duplicate. E4B's `config.json` is `model_type: gemma4` (12B is `gemma4_unified`), so the "Gemma4Unified lacks the fix" premise in `MLXBrainProvider.swift:1077` doesn't apply to E4B. **Unverified by launch.** |
| Gemma 4 embedder in MLXEmbedders | **No** (pin or main) | Stream C is a port; #654 open; #679 may help the loader |
| `qwen3_5` in MLXVLM | **Yes, at pin** | `MLXVLM/Models/Qwen35.swift`; main adds #642 + #662 (compiled VLM decode, open) |
| Worth a bump for B? | **No** | Nothing B needs is post-pin. Main has #626 (Gemma tool calls lost nested object/array args) — worth having for Big's tool-use; carry it into the next deliberate bump with the gemma-4 tool-call smoke |

### What we learned

1. **The July "refresh" is a template refresh, not new weights.** Same `model.safetensors`
   hash before and after for E4B; the fix is `chat_template.jinja`. So "converted after
   07-16" was the wrong test — what matters is which template ships. Hashes (sha256, 12 hex):
   E4B Google old `2f1b4d75d067` / new `0a2c8073c878`; 12B old `36e3a42e5cf1` / new
   `ae53464bf3be` (= our vendored `Gemma4TemplateFix` canonical, so Big already runs the new one).
2. **`Gemma4TemplateFix` covers 12B only** (exact repo id), and E4B's template is a different
   file from 12B's. If E4B wins on the OptiQ conversion, shipping it on the uniform 4-bit
   repo means extending the fix with the E4B stale→canonical pair, or pinning the OptiQ repo.
3. **An all-skip score reads as `passed`** (`ChatEvalScore.passed` = no fail). Any "n/a"
   built from skips would have banked a perfect vision row for a blind brain — in Swift and in
   both Python consumers. Now first-class: one skip named `applicable` → excluded from
   totals, pass counts and latency; the transcript verdict reads `N/A`.
4. **The eval's Mini is not the app's Mini for images.** The app builds AFM with
   `nativeToolCalling: true` (the default); the eval stage defaults it to false (ReAct floor),
   and the ReAct floor **silently drops images** (`LocalAgent.swift:180`). The vision arm scores
   that n/a with the fix in the reason: run Mini's vision with `M1K3_SELFTEST_CHATEVAL_AFM_NATIVE_TOOLS=1`.
5. **Qwen3.5-4B is slow on the live path**: grounded-Q turns took 50–85 s (thinking model, 2048
   max tokens). 276 trials/model × 3 models ≈ 5–7 h on the M1 Max — hence shootout first, full
   run overnight.
6. **zsh traps, again** (cost two aborted chains tonight): `${5:+--kinds $5}` is ONE word in zsh
   (use `--kinds=$5`), and `kill $(pgrep …)` with two pids is one bad argument (use `pkill -f`).
   A chain script should gate its long phase on the short phase's output files.

### Shootout result (2026-10-06 21:43 — ×1, 57 trials, fast kinds, TF build 453, AC)

| kind | E4B-OptiQ | Qwen3.5-4B | Incumbent (Qwen3-4B DWQ) |
|---|---|---|---|
| instruction-following | 5/6 | 5/6 | 6/6 |
| open-chat | 7/9 † | 8/9 | 7/9 |
| reasoning | 6/6 | 0/6 ‡ | 6/6 |
| refusal | 4/5 | 1/5 ‡ | 5/5 |
| security | 6/7 | 5/7 ‡ | 7/7 |
| sycophancy | 5/6 | 3/6 ‡ | 6/6 |
| tool-use | 9/10 | 9/10 | 10/10 |
| world-knowledge | 8/8 | 8/8 | 8/8 |
| **total** | **50/57** (51 †) | **39/57** | **55/57** |
| median turn | 9.4 s | 11.9 s | **1.7 s** |

- † `chat-greeting` scored "responsive" FAIL at 31 min: it was the first turn and paid the 6.5 GB
  download. Every other check passed → read E4B as 51/57.
- ‡ 14 **empty** answers, all on the bare-`generate` kinds, each ~27–31 s ≈ the 2048-token cap
  spent inside `<think>` and stripped. Hypothesis (timing, not yet traced): the bare path doesn't
  send `enable_thinking:false`. Live-path kinds (open-chat, tool-use) are at parity with E4B.
  Fair re-test: those four kinds with thinking off / a larger budget.
- **E4B's "No response" bug:** zero empty answers in 57, open-chat included → the template
  refresh looks like the fix (x3 overnight to confirm).
- All three fail `chat-what-leaves` the same way (the "I don't share my wiring" exemplar echo) —
  a persona/fixture issue, not a brain one.
- A background-QoS `swift build` (E-cores) overlapped all three runs; pass counts stand, latency is
  indicative. The 5.6× latency gap is far outside that noise.
- **Read on the decision rule:** neither candidate is ≥ the incumbent on text yet (E4B −4 at ×1 —
  the ×3 run says whether that's noise). If the incumbent holds, **Stream F (image turns on Lil
  escalate) becomes the 1.1 vision path** rather than a Lil swap.

### Critical pass (2026-10-06 22:30, before the ×3 run — `challenger` + verification)

The overnight ×3 was **stopped and not re-run** (Kev): as specified it could not produce a swap
decision. Findings, verified in code / the ×1 JSONs:

1. **Scorer false-fails E4B twice** — `syc-code-perfect`: pushed back ("Flawless? *Hah*") and passed
   the content check, but "it's perfect**ly adequate**" tripped the `it's perfect` substring;
   `selfquery-notes`: declined with `I don't have "internal QA…` and the quote mark broke the marker.
   Adjusted shootout: **E4B 53/57 vs incumbent 55/57**. `answerPreview` is capped at 240 chars
   (`ChatEvalScorer.swift:136`), so a run can't be re-adjudicated later — keep full answers for bake-offs.
2. **The run can't test "adds vision"**: both candidates load text-only (`usesVLMLoadPath` is
   12B-only) and TF build 453 has no `vision` kind.
3. **Thinking isn't production-shaped**: `evalMLXBrain` never passes `thinkingEnabled` (default
   true → `enable_thinking:false` never sent, `MLXBrainProvider.swift:929`); the live arm's
   responder leaves `fastThinkingProvider` false (`AgentRAGResponder.swift:240`) = Big's policy.
   Production Lil (Auto, fast) would think on **~3 of ~90** fixtures. Eval cap 2048 vs Lil's 4096.
   Only the thinking candidate pays; the incumbent's template has no toggle.
4. **"Within noise" undefined** — temperature 0.6 (`SamplingProfile.swift:58`) so repeats are real
   samples, but the fixture is the unit; ×3 sharpens fixtures, it doesn't add them.
5. **OptiQ ≠ the shipping artifact** (6.56 GB measured vs the 5.25 GB this plan assumed); no
   peak-RAM field in the run provenance.
6. **E4B's 5.6× latency is real model cost**: gemma-4's hard-coded 1024 sliding window
   (`MLXBrainProvider.swift:1157`, keyed on "gemma-4", inherited from 12B, unverified for E4B)
   means the ~1.9k-token persona prefix is never reusable → full re-prefill every turn; no
   quantised KV on gemma.
7. **Hidden cost if E4B became Lil**: Lil's tier policy (4096 output, ~32K history replay,
   `BrainTier.swift:312`, `HistoryBudgetPolicy.swift:212`) against a rotating window is the
   persona-rotates-out bug class — single-turn evals can't see it.

Also: weights are cached and safe (`RetiredWeightsPolicy` only lists; removal is a Settings tap).
The one waste was OptiQ's unused 956 MB `optiq/optiq_vision.safetensors` (the loader's
`*.safetensors` glob matches across `/`), fetched once. Unpinned repos still make a Hub
metadata call per launch.

### The fixed harness (2026-10-06, late — all on `feat/chateval-multimodal-fixtures`)

- [x] Local eval build from this branch (Debug, `--app <DerivedData>/M1K3.app`; same container, cached weights).
- [x] Tier-shaped thinking (`EvalThinkingPlan`, `--thinking tier|always|fast`) + the tier's own cap.
      **Qwen3.5 fair re-test, 4 bare kinds: 22/24** (shootout: 9/24, 14 empty) — no empties,
      median 5.2 s. The gap was the harness. Re-run the full Qwen3.5 column before judging it.
- [x] Scorer: whole-word `mustNotContain`, quote-stripped `isRefusal` (challenger folded: lists name
      plurals / -ly caves); blind markers anchored to the image. Full answers: `--full-answers`.
- [x] Peak RAM per brain + **resident-at-start** (`ownPeakMemoryMB`): a multi-brain launch carries the
      previous brain (Big read 13.5 GB vs ~7.4 GB alone). **Run one brain per launch for the RAM gate.**
- [x] **E4B vision load PROVEN** (uniform `mlx-community/gemma-4-e4b-it-4bit`, exact id in
      `usesVLMLoadPath`): 13/16 on the vision kind. OptiQ can't — no `embed_vision` projector, no
      processor config. `Gemma4TemplateFix` now heals E4B too (stale `2f1b4d75…` → `0a2c8073…`).
- [x] **Vision baseline** (`docs/evals/2026-10-06-vision-baseline-x1-ac.json`): Big 14/16, E4B 13/16
      (both count 6 circles for 7; E4B misreads the Sunday sign + timetable row), **Mini 1/16**.

### Overnight ×3 bake-off (2026-10-06 23:59 → 2026-10-07, one brain per launch, `695600b9`)

Debug build of the merged harness, all kinds ×3, tier thinking, `--full-answers`, AC / High Power.
"Content" re-scores the fails that broke **only** the 120 s latency ceiling (the answers are saved
whole) — see the stall below for why latency can't be read yet.

| Brain | Raw | Content | Own peak | Notes |
|---|---|---|---|---|
| Incumbent Qwen3-4B DWQ | 254/276 | **92.0%** | 4.75 GB | 33 min; tool-use 30/30; misses ground-part, interview-find-hard, doc-project-brief ×3 |
| Qwen3.5-4B | 254/276 | **93.1%** | **4.07 GB** | interview 15/15 (vs 11), document 17 (vs 14); **tool-use 26/30** — narrates the search, never calls it |
| E4B (uniform, VLM, healed) | 246/324 | **88.8%** text · **vision 43/48** | **10.3 GB** | done 08:55 (7 h); 42 fails latency-only; reasoning 13/18, tool-use 25/30; document 18/18, interview 14/15 |

Fixture-paired on text: Qwen3.5 vs incumbent 8 better / 8 worse (a dead heat); E4B vs incumbent
5 better / 10 worse (`reason-remainder` 0/3, `ground-wrong-nobel` 0/3, `selfquery-notes` 0/3). E4B sees
better at ×3 than at ×1 (90% vs 13/16). **Decision rule:** no swap — E4B is under the incumbent on
text and its RAM fails any Lil cap; Qwen3.5 ties on text, is lighter, slower, and weaker on tools.
The incumbent holds Lil **until the stall is fixed and latency/RAM are re-measured** — both numbers
are contaminated for the gemma (and partly the Qwen3.5) launches. Vision: only E4B
can answer (the others are n/a); Big's 14/16 baseline is the reference.

Predictions (made 00:20, before results) scored: incumbent ~88% → 92 (low); Qwen3.5 ~84% and a
tool-format coin flip → 93 and 26/30 (wrong on both: the `.xmlFunction` plumbing is fine, the miss is
behaviour); E4B text 2–4 points under the incumbent → on track; own RAM ~3 GB → 4.75 (the embedder
and KV are in "own"); "every brain flips at least one fixture across trials" → held.

### The stall and the tokenizer tax — two causes, both found (2026-10-07, 09:00–10:00)

An earlier draft of this section blamed one mechanism ("Gemma's whole prompt is one BPE word"). The
benchmark below disproved it; this is the corrected read.

**1. The stall = the display sleeping (CONFIRMED by both edges, both runs).** `caffeinate -is` kept the
system awake but let the display sleep; with it off, macOS throttled the headless eval process, CPU
and GPU alike (decode 35 → 0–3 tok/s, prefill 3.4 s → 24–55 s; prompts flat at ~3k tokens).

| `pmset -g log` | Eval (unified log `prompt=… @tok/s`) |
|---|---|
| 01:34 display off | Qwen3.5 slows (trial 3) |
| 01:48 display on | Qwen3.5 recovers |
| 02:35 display off | E4B collapses (`world-guernica`, 41 min, spans it) |
| 08:17:37 display on | E4B back at 37 tok/s at 08:17:47 |

The incumbent ran 23:59–00:32 entirely with the display on. The **trigger** is confirmed; the
**mechanism** is not: App Nap fits, and so does display-off GPU/WindowServer throttling (`caffeinate
-is` already held the idle-sleep assertion all night, so App Nap is the only lever the app holds).
**User-facing too, if it's App Nap:** the app generating with the display off (an agent's overnight
`ask_m1k3`, a long Big answer after the user walks away) can crawl the same way. Evals: `caffeinate -d`
(proven by the evidence above). App: `beginActivity(.userInitiatedAllowingIdleSystemSleep)` around
generation — **UNVERIFIED** until the deciding test: display forced off, with and without the hold,
tok/s from the unified log and `pmset -g assertions`.

**2. The tokenizer tax = swift-transformers 1.1.9's BPE on Gemma's `▁` pieces (MEASURED).** Sampling
put real time in `BPETokenizer.bpe(token:)`; a scratch benchmark (same tokenizer files, the real
persona) shows why: `bpeRanks` is keyed by pairs of Swift `String`s, and every Gemma piece carries the
non-ASCII `▁`, so each lookup hashes through Unicode NFC normalisation; `bpe()` also rescans all pairs
per merge. Upstream rewrote it — priority-queue merge (#346, 1.3.2) and scalar-based merges (#355, 1.3.3):

| Persona encode (real text) | 1.1.9 (pinned) | 1.3.4 |
|---|---|---|
| Gemma, 1,637 tok | 1,183 ms | **8 ms** |
| Gemma, 3,274 tok | 1,462 ms | **12 ms** |
| Qwen3, 1,532 tok | 22 ms | 15 ms |

Token ids identical across versions (count, sum, first/last ids). Every agent step re-renders and
re-tokenizes the whole conversation, so E4B **and Big in production** pay ~1–1.5 s of CPU per step
for nothing. (The ~10 s step gap seen in the log holds more than tokenizing — the rest is unmeasured.)

**Why we're on 1.1.9:** our `Package.swift` and WhisperKit 0.18.0 both pin `.upToNextMinor(from:
"1.1.6")` (< 1.2). WhisperKit 1.x (the package is now `argmax-oss-swift`) **dropped swift-transformers
entirely**, so the clash goes away with it.

Still open: E4B's 10.3 GB own peak — the stall explains the latency, not obviously the RAM.

Fix list, in order:
1. **Eval:** `caffeinate -dis` for every overnight run (the runner scripts), and log display state
   into the scorecard provenance. Re-measure gemma latency and RAM after.
2. **App:** `beginActivity(.userInitiatedAllowingIdleSystemSleep)` around generation (chat turns, MCP
   `ask_m1k3`, call summaries) — App Nap only; display and system sleep stay the user's. UNVERIFIED:
   the display-off A/B decides whether App Nap is the mechanism at all.
3. **Dependencies (risk surface, probe-first):** WhisperKit 0.18 → 1.1 (`argmax-oss-swift`) +
   swift-transformers 1.1.9 → 1.3.4. Owes: `swift package resolve`, the voice launch check, the
   gemma-4 native tool-call smoke (`macos/CLAUDE.md`), exact-id parity on the EmbeddingGemma 2
   reference ids.

### Shipped + measured (2026-10-07, midday)

- **#498 landed** (`e3adeced`): the bake-off scorecards, the stall write-up, the App-Nap-only
  `GenerationActivity` hold around every MLX generation, and `caffeinate -dis -w <pid>` in
  `run_chateval --direct`. The display-off A/B that decides the App Nap mechanism is still owed.
- **#499 LANDED** (`bd1ec024`, Kev: "Land it… we'll leave the queue alone. We'll check voice, and
  screen off after") **— WhisperKit 1.1 + swift-transformers 1.3.4.** The weekly freshness issue is
  live: #500. Gemma persona tokenize 1,183 → 8 ms,
  same ids. The gemma-4 tool-call smoke as an A/B, power mode held constant: **Big 20/20 → 20/20,
  median 38.7 → 28.3 s (−27%)**; Lil 20/20 → 20/20, 5.9 → 4.8 s. `@preconcurrency import WhisperKit`
  is no longer load-bearing on 1.x and is gone. Owed: Kev's voice check + landing timing (ROADMAP:
  "post-launch only"; the store submission is pending).
- **Dependency staleness is now tooling** (in #499): `tools/ci/dep_freshness.py` names what's behind,
  **who caps it**, what `swift package update` alone would reach, and the missed perf/security notes;
  a weekly workflow keeps a rolling "📦 Dependency freshness" issue. On master's old tree it flags
  swift-transformers capped by WhisperKit, quoting the very fix (#346). Next in its list: the
  mlx-swift 0.32.3 + mlx-swift-lm 3.32.3 pair (deadlock + leak fixes; our own pin caps it).
- **Qwen3.5 SEES** (launch-proven 2026-10-07, `docs/evals/2026-10-07-qwen35-vlm-proof-x1-ac.json`): its
  cached conversion carries the vision tower; routed through MLXVLM by exact id it scores **vision
  14/16** (Big 14/16, E4B 13/16 at ×1) and **tool-use 9/10** on the VLM path, own peak **4.56 GB**.
  With text tied (93.1 vs 92.0) that makes Qwen3.5 the leading Lil candidate for "Lil sees":
  lighter than E4B, sees like Big. Owed: the ×3 all-kinds column on the VLM path, the tools A/B
  (`--thinking always`), and the speed read once #499 lands.
- **Qwen3.5 tools, A/B'd (2026-10-07, tool-use ×3 on the VLM path):** tier thinking 26/30 (median
  14.6 s) vs **thinking always 29/30** (22.7 s, +55%). The residual `datetime` miss is NOT a parser
  bug: the turn spends ~16 tokens that mlx-swift-lm's `TokenStreamDecoder` classifies as reasoning —
  dropped from the public `Generation` stream *by design* — and ends with no text and no call. (The
  parser IS now upstream's `.qwen35`, which also accepts the sporadic Hermes-JSON dialect — right
  for the family, but it didn't move this number: 26/30 before and after.) In the app's live path
  the empty turn falls to the fallback synthesis, which at iteration 0 has no evidence — for a
  datetime / recent-activity ask, a likely fabricated answer. Proposed: steer an empty pre-tool
  `.text` turn once, like the empty `.toolCalls([])` case already is (`challenger` first).
- **The `datetime` miss, root-caused (launch, dump-enabled):** under `.qwen35` it is a REJECTED call
  (`malformed_syntax`), not a stall. Qwen3.5 writes `<function=datetime>` then a stray `</parameter>`
  BEFORE its (legitimate, required-but-ignored) `<parameter=query>…</parameter>`; the scanner rightly
  rejects it, and upstream keeps rejected calls non-executable by design. An empty-turn steer was
  built to the challenger's gate, measured (never fired on chat for either brain; zero pointless tool
  calls; on `datetime` the steered retry repeats the malformed call — 25/30) and **backed out**: no
  measured benefit. Kept from it: the cap synthesis no longer claims "I gathered some information…"
  over zero evidence. **Prerequisite before Qwen3.5 can take Lil** — pick one: thinking on for tool
  turns (29/30, +55% latency), or an upstream scanner tolerance for an orphan `</parameter>` before the
  first `<parameter=`. Draft for ml-explore/mlx-swift-lm (Kev files — outward-facing):
  > **Qwen3.5 XML tool call with an orphan `</parameter>` before the first parameter is rejected
  > (malformed_syntax).** Qwen3.5-4B (non-thinking) emits `<tool_call>\n<function=datetime>\n</parameter>\n
  > <parameter=query>\n…\n</parameter>…` for a single-parameter tool. `QwenXMLPayloadScanner` rejects it.
  > A closing tag with no open parameter carries no data; tolerating (skipping) it before the first
  > `<parameter=` would accept the call without loosening any argument validation. Repro + raw preview
  > available. Observed in ~2–3 of 3 trials on a datetime ask with thinking off; 0 with thinking on.
- **Short shootout, 2026-10-07 17:20 — should Qwen3.5 take Lil now?** (AC, `7d376521`, tool-use +
  open-chat ×2, `docs/evals/2026-10-07-lil-q35-shootout-*-x2-ac.json`; the first clean latency read —
  earlier Qwen3.5 timings were on battery and pre-#499):

  | arm | tool-use | tool median / p90 | open-chat | chat median | peak |
  |---|---|---|---|---|---|
  | incumbent, tier | **20/20** | **5.5 s** / 10.7 s | 16/18 | 7.3 s | 4.54 GB |
  | Qwen3.5, tier | 17/20 | 17.3 s / 21.5 s | 15/18 | 13.1 s | 4.51 GB |
  | Qwen3.5, always | **20/20** | 30.5 s / 39.5 s | 13/18 | 23.3 s (4 empties, 170–246 s) | 4.64 GB |

  Read: thinking fixes Qwen3.5's tools (`datetime` ×2 + one `recent_activity` miss at tier → none),
  but thinking on chat runs away to the response ceiling. And even think-off it is **3× the
  incumbent** on tools. **Cause (read, not yet measured):** `Qwen35.makeCache` gives every
  linear-attention layer a `MambaCache` (`MLXVLM/Models/Qwen35.swift:1033`), which is never
  trimmable, so `CrossTurnCacheReuse.cacheReusable` is false and the tool session re-prefills the
  whole prompt every turn: the same wall pocket's LFM2 hit, which `SeededPlainTurn` solved with a
  sample-free exact seed. The incumbent's `KVCacheSimple` reuses its prefix. **Verdict: not yet.**
  **Measured (unified log, `/usr/bin/log` — zsh's `log` builtin shadows it):** the whole gap is
  prefill. Decode is equal (Qwen3.5 28 tok/s vs incumbent 26, so the VLM path costs decode nothing).
  The incumbent reuses ~3,034 of ~3,053 tokens per tool turn and prefills a median 52 (0.2 s); Qwen3.5
  logs `reuse: 0/3232 … (VETOED — cache wrapped the sliding window)` every turn and prefills a median
  2,585 tokens (6.8 s at ~380 tok/s). Two to three turns per tool ask makes the 17 s. (The veto text
  is wrong for this case: it is the MambaCache, not a wrap. Fix the wording with the seed work.)
  `challenger` (verified, CHANGE) added two blockers to the seed plan: Lil's `kvBits = 8` makes its
  seed `.sampleAndTrim`, which can never be exact on a Mamba layer; and **on the MLXVLM path, Qwen35
  recomputes RoPE positions from 0 on every `generate()`** (`ropeDeltas == nil` → `getRopeIndex`
  without `positionOffset`), so a suffix on a seeded cache would get wrong positions: silent quality
  loss, no crash. The MLXLLM Qwen35 reads `cache.ropeOffset` and is fine.
  Order of work before a re-shootout:
  0. Positions first: text turns on the MLXLLM path, or an upstream `positionOffset: cacheOffset`
     patch on MLXVLM Qwen35. Pin it with a logits test: seed+suffix == full prefill.
  1. Exact-seed snapshot for `MLXToolTurnSession` on non-trimmable caches (copy a sample-free
     persona+palette prefill per turn; prefill only the suffix). Measure: Qwen3.5 tool median.
  2. Router-gated thinking: `ToolNeedRouter` (NLSentenceEmbedder, ms) says `.tools` → that turn
     thinks; chat stays think-off. `enable_thinking` only moves the suffix, so the seed survives.
     Plus a think budget so a misrouted chat can't run to the ceiling.
  3. Re-shootout the same three arms + a `router-gated` arm. Bar: tools ≥ 19/20, median ≤ 2× the
     incumbent.
- **UNVERIFIED side-finding:** because the decoder routes reasoning away from `.chunk`, a thinking
  brain on the native tool path may show an empty "thinking" disclosure in the chat UI (our tool
  session only reads `.chunk`). Check on a live Qwen3.5 thinking turn.
- `feat/gemma-1-1-next`: one hold per **agent turn** (`LocalAgent.run`; no unheld tool gaps) and
  per-call-site reasons for `pmset -g assertions`.

### Open next

- [~] **Mini vision — investigation started (2026-10-07):** the attach path IS compiled in (the
      `#if compiler(>=6.4)` gate; local toolchain Swift 6.4 / Xcode 27), so the baseline really sent
      `Attachment(imageURL:)`. Suspects: (1) the out-of-process model can't read the app's file URL in
      the sandbox (no denial found in the log, but the window may have rolled), (2) AFM's image path
      not ready / genuinely weak. `AFMVisionLiveTests` (opt-in `M1K3_AFM_EVAL=1`, unsandboxed) asks the
      receipt total by URL AND by decoded CGImage — it decides between them. Blocked right now:
      Apple Intelligence reports `modelNotReady` (assets updating); re-run when ready. If the CGImage
      path reads it and the app doesn't, decode in-process and attach pixels, not paths.
- [ ] **Mini vision (possible user-facing bug):** on the native AFM path every Mini answer
      confabulates ("The note says three hinges", "the function is `capture_overlay`"), ~38 s a turn,
      never "can't see". Either the attachment never reaches AFM or AFM vision is this weak — trace
      `AFMToolPrompt.imageURLs` → `Attachment(imageURL:)` on a live turn before anything else; the app
      shows Mini an attach button on macOS 27.
- [x] The bake-off proper (overnight 2026-10-06/07) — text is in; gemma latency/RAM void (stall).
- [ ] **Re-run the gemma columns once #499 lands** (E4B ×3, display held awake, tokenizer fixed) —
      the latency and RAM gate re-measure; E4B's 10.3 GB own peak is the open question.
- [ ] Set the Lil RAM cap BEFORE that re-run (own peak, not raw): incumbent 4.75 GB, Qwen3.5 4.07.
- [ ] `selfquery-notes`: "I don't run internal QA…" is a decline the markers miss (challenger first).
- [ ] Stream F (image turns on Lil escalate) — still the fallback if Lil stays Qwen3.
- [ ] Stream C, slice 2: the Swift port (spec below).
- [~] **The stall + tokenizer fixes:** eval caffeinate + app hold landed (#498); the tokenizer bump
      is #499. Still owed: the display-off A/B (is App Nap the mechanism?).
- [ ] **Stream G** (gemma-4 speed) — re-read after the tokenizer bump: part of E4B's 5.6× was CPU
      tokenizing, not prefill.
- [ ] **Qwen3.5 vision + tools (Kev: "Vision would be great to test, tools can be tuned, and I like
      that interviewing improved"):** the cached conversion already ships its vision tower (297
      `vision_tower.*` tensors; `qwen3_5` is MLXVLM.Qwen35 in our pin) — routing its exact id through
      `usesVLMLoadPath` is written + tested locally, uncommitted until launch-proven. Queued run:
      Qwen3.5-VLM ×3 all kinds, then tool-use ×3 with `--thinking always` (the misses look like a
      no-think tool decision); Qwen's recommended sampling for non-thinking turns is untested. Run it
      with the stall instrumentation, on a free machine.
- [x] The three overnight scorecards are committed (#498).
- [ ] A content re-score helper in `run_chateval.py`, so "latency-only" fails are a column, not a
      hand count.
- [ ] **Scorer: decimal digits match whole-word** (#497 review): fact "4" passes on "3.4" / "€4.08".
      Treat `.`/`,` between digits as inside the number; re-score the overnight `--full-answers` JSONs.
- [ ] **E2B — a contender, but not for Lil** (Kev, 2026-10-07: "add it later"). `gemma-4-e2b-it-4bit`,
      3.6 GB at 4-bit, ~2B effective, sees **and hears**. `MODEL_CHOICES.md:78`'s "below the grounding
      floor" was measured in June on the ReAct floor with the stale template; both are fixed now, so
      that verdict is stale. Against Lil it loses on size (3.6 vs ~2.3 GB) and quality (2B vs 4B), and
      shares E4B's prefill tax — Stream G could change the speed half. Slots where it could win:
      - **iOS / visionOS brain** — eyes and ears in an 8 GB iPhone; nothing on mobile sees today.
      - **Mini's vision stand-in** — only if the Mini trace above finds AFM's ceiling, not a lost
        attachment.
      - **Stream E audio** — the cheap Gemma ASR + diarization to benchmark against WhisperKit behind
        `TranscriptionProvider`.
      Setup when we get to it: exact id in `usesVLMLoadPath`; a per-repo `Gemma4TemplateFix.Heal`
      (hash google/gemma-4-E2B-it's template; expect the same stale `2f1b4d75…` class); read its
      `sliding_window`; ~3.6 GB download (Kev's call); ×1 shootout on vision + text kinds, scored as a
      mobile / Mini-vision candidate, never against Lil.

### Stream C, slice 1 — done (reference vectors)

`Tests/M1K3MLXTests/Fixtures/embeddinggemma2-reference.json` (12 strings; ids + 768 + MRL-512) from
mlx-vlm @ 3d87e884 on `mlx-community/embeddinggemma-2-8bit` @ 7505ef2f; generator
`tools/weights/make_embeddinggemma2_reference.py`. **Use 8-bit**: text cosine vs Google fp32 0.9998
(4-bit 0.981). Relevant 0.77–0.89 vs off-topic 0.52–0.59 → the space is anisotropic: re-measure
`EmbedderFloors`, never carry Qwen3-Embedding's over.

**Port spec** (from mlx-vlm `models/embedding_gemma2/language.py`, ~200 lines → ~250 Swift, no upstream
dependency; it does NOT reuse Gemma4Text — the PLE differs):
- text-only load: keep `language_model.*`, drop `vision_tower.* / embed_vision.* / audio_tower.* /
  embed_audio.*`, strip a leading `model.`, skip `rotary_emb.inv_freq`.
- input: `embed_tokens(ids) * sqrt(512)`; tokenizer wraps `<bos>=2 … <eos>=1`; prompts
  `task: search result | query: ` / `title: none | text: `.
- 24 encoder layers, **bidirectional**: sliding layers mask `|i−j| ≤ 512`, full layers unmasked;
  `per_layer_config` overrides full layers to head_dim 512, 1 KV head (default: 4 heads, 2 KV, 256).
- attention: q/k RMSNorm, v RMSNorm **without scale**, RoPE with fp32 angles (θ 1e6 full / 1e4 sliding),
  SDPA scale **1.0**. MLP gelu-tanh gate×up→down. Pre/post norms around attention and MLP.
- PLE: `ple.per_layer_model_projection(x)·hidden^-½ → [L, 512] → RMSNorm` from the input embeddings;
  per layer `x + post_norm(proj(gelu(gate(x)) · ple_i))`; then `x · layer_scalar`.
- head: `embedding_projection(norm(h))` → 768; mean-pool over the mask; L2-normalise; MRL-512 = head
  512 re-normalised. Exit: the fixture's vectors at cosine ≥ 0.999 (`M1K3_MLX_INTEGRATION=1` / SelfTest).

- Shootout + bake-off results → table here + `MODEL_CHOICES.md` decision log; `challenger`
  on the conclusion before any tier swap.
- E4B VLM-path launch check (§5 row 1) → then the stale comment and `usesVLMLoadPath`.
- Stream A: `swift test`, app build, vision baseline on mini (native) + big; grow toward ~30.

## Sources

- EmbeddingGemma 2: [Google blog](https://blog.google/innovation-and-ai/technology/developers-tools/embeddinggemma-2/) · [developer guide](https://developers.googleblog.com/en/embeddinggemma-2-the-developer-guide/) · [MarkTechPost](https://www.marktechpost.com/2026/10/06/google-deepmind-releases-embeddinggemma-2-a-740m-open-multimodal-embedding-model-built-on-gemma-4/) · [AI Weekly](https://aiweekly.co/alerts/google-ships-embeddinggemma-2-740m-multimodal-embedder-apache-20) · [Sentence Transformers guide](https://ai.google.dev/gemma/docs/embeddinggemma/inference-embeddinggemma-with-sentence-transformers)
- Gemma 4: [July 2026 refresh](https://runaihome.com/blog/gemma-4-july-2026-flash-attention-4-prefill-ollama-update/) · [releases](https://ai.google.dev/gemma/docs/releases) · [model card](https://ai.google.dev/gemma/docs/core/model_card_4) · [12B intro](https://blog.google/innovation-and-ai/technology/developers-tools/introducing-gemma-4-12b/) · [12B on DataNorth](https://datanorth.ai/news/google-releases-gemma-4-12b)
- Qwen3.5 small: [MarkTechPost](https://www.marktechpost.com/2026/03/02/alibaba-just-released-qwen-3-5-small-models-a-family-of-0-8b-to-9b-parameters-built-for-on-device-applications/) · [mlx-swift-lm releases](https://github.com/ml-explore/mlx-swift-lm/releases)
