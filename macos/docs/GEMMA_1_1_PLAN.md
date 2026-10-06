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
- `Qwen3.5-4B` 4-bit → `mlx-community/Qwen3.5-4B-MLX-4bit` (base_model `Qwen/Qwen3.5-4B`, 3.06 GB, `qwen3_5`, vision config present). Thinking model — the template pre-opens `<think>`; already handled (`templatePreOpensThink`, `.xmlFunction`).
- phone tier side-bout: `Qwen3.5-2B` vs pocket `LFM2.5-1.2B` (and `LFM2.5-2.6B`, already a noted candidate)

Steps:
- [x] Quit the live app (the runner does it, `--no-relaunch` per run, `open` at the end of the chain).
- [~] **2026-10-06 shootout** (×1, fast kinds: open-chat, tool-use, reasoning, refusal, security, world-knowledge, instruction-following, sycophancy) → `docs/evals/2026-10-06-lil-shootout-<model>-x1-ac.json`; then the full ×3 all-kinds chain overnight → `…-lil-bakeoff-<model>-x3-ac.json`. Order: E4B-OptiQ, Qwen3.5-4B, incumbent. App = TF build 453 (`--commit tf-build-453`: no GitCommitSHA in store builds).
- [ ] Text + tools, per candidate: `python3 tools/eval/run_chateval.py --direct --name lil-bakeoff-<model> --brains lil --model lil=<id> --repeats 3 --save-to docs/evals/2026-10-XX-lil-bakeoff-<model>.json`
- [ ] E4B specifically: re-check the no-response bug with the open-chat fixtures and "How are things M1K3?" (`MODEL_CHOICES.md:86`). Record whether the July refresh fixed it.
- [ ] Qwen3.5-4B: confirm prefill is no longer CPU-heavy (Activity Monitor + `tools/eval/power_receipt.py`). Tool dialect is `.xmlFunction`.
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

### Open next (the fixed harness, then one proper run)

- [ ] Local eval build from this branch (the installed TF build can't carry harness fixes).
- [ ] Tier-shaped thinking in the eval: `evalMLXBrain(thinkingEnabled:)` + `fastThinkingProvider`
      per tier, an env override for an always-think arm; Lil's 4096 cap. Then Qwen3.5 gets a fair re-test.
- [ ] Scorer: the two false-fails (`it's perfect` vs "perfectly"; quoted text inside a decline) —
      `challenger` first (heuristic); full answer text kept for bake-off runs.
- [ ] Record peak RAM per brain in the run provenance; set the Lil RAM cap.
- [ ] E4B vision-load launch (widen `usesVLMLoadPath` locally) → if it loads, the bake-off counts.
- [ ] Decide the E4B artifact: OptiQ (pin it) or uniform 4-bit + the E4B template pair in
      `Gemma4TemplateFix`.
- [ ] Stream F (image turns on Lil escalate) — likely the 1.1 vision path if Lil stays Qwen3.

- Shootout + bake-off results → table here + `MODEL_CHOICES.md` decision log; `challenger`
  on the conclusion before any tier swap.
- E4B VLM-path launch check (§5 row 1) → then the stale comment and `usesVLMLoadPath`.
- Stream A: `swift test`, app build, vision baseline on mini (native) + big; grow toward ~30.

## Sources

- EmbeddingGemma 2: [Google blog](https://blog.google/innovation-and-ai/technology/developers-tools/embeddinggemma-2/) · [developer guide](https://developers.googleblog.com/en/embeddinggemma-2-the-developer-guide/) · [MarkTechPost](https://www.marktechpost.com/2026/10/06/google-deepmind-releases-embeddinggemma-2-a-740m-open-multimodal-embedding-model-built-on-gemma-4/) · [AI Weekly](https://aiweekly.co/alerts/google-ships-embeddinggemma-2-740m-multimodal-embedder-apache-20) · [Sentence Transformers guide](https://ai.google.dev/gemma/docs/embeddinggemma/inference-embeddinggemma-with-sentence-transformers)
- Gemma 4: [July 2026 refresh](https://runaihome.com/blog/gemma-4-july-2026-flash-attention-4-prefill-ollama-update/) · [releases](https://ai.google.dev/gemma/docs/releases) · [model card](https://ai.google.dev/gemma/docs/core/model_card_4) · [12B intro](https://blog.google/innovation-and-ai/technology/developers-tools/introducing-gemma-4-12b/) · [12B on DataNorth](https://datanorth.ai/news/google-releases-gemma-4-12b)
- Qwen3.5 small: [MarkTechPost](https://www.marktechpost.com/2026/03/02/alibaba-just-released-qwen-3-5-small-models-a-family-of-0-8b-to-9b-parameters-built-for-on-device-applications/) · [mlx-swift-lm releases](https://github.com/ml-explore/mlx-swift-lm/releases)
