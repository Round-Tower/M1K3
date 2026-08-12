# MODEL_CHOICES.md — picking M1K3's local brains

> Living decision doc for the MLX-backed brain tiers (lil / big / huge). Mini is Apple
> Foundation Models and is out of scope here. Started 2026-06-22 after the Phase 21
> OptiQ swap was reverted; this is the evidence base for what replaces it.
>
> **The golden rule (learned the hard way):** existence ≠ loadability ≠ quality. Verify each
> stage. OptiQ repos existed and had correct sizes/names but didn't *load*; Qwen3.5 loads but
> CPU-spikes; gemma-4 loads and runs but *reasons itself into silence*. Specs get you a
> shortlist; only an on-device CHATEVAL picks the winner.

---

## The runtime constraint: mlx-swift-lm (now a main-HEAD revision pin)

**Update 2026-06-23:** M1K3 now builds off **mlx-swift-lm main** (`revision 40c2ff06`, = PR #330's
merge) to unlock Gemma 4 native tool-calling — the last *release*, 3.31.3, had no `.gemma4` parser.
See "Runtime watch" below for the full why + the (temporary) revert path. The failure-axes analysis
below still holds; what runs is decided by the registry (`Libraries/MLXLLM/LLMModelFactory.swift`) +
which arches it implements (main's registry ⊇ 3.31.3's).

Three independent failure axes, all seen this session:
1. **Format loadability** — OptiQ (`mlx-optiq` mixed precision) has no Swift loader → won't load
   (Qwen3.5 OptiQ → token-soup; gemma-4 OptiQ → `k_proj.weight not found`). **OptiQ is parked.**
2. **Architecture / perf** — SSM/linear-attention hybrids (GatedDeltaNet, e.g. Qwen3.5) were
   CPU+GPU-heavy at prefill. **Corrected 2026-06-24:** this was NOT per-token CPU dispatch — on Apple
   Silicon the fused Metal kernel runs the whole T-step loop in ONE GPU dispatch (`GatedDelta.swift:244`'s
   `for t` is the CPU *fallback*, not the path taken). The real cost was the prefill **sync stall**, and
   **main's #225 (asyncEval prefill) fixes it** (2.7–14.6× prefill). See "What building off main unlocks."
3. **Tool-calling dialect** — M1K3 runs a tool loop every turn. Models with a native dialect in
   `MLXToolCalling.resolveToolCallFormat` (json / xmlFunction / gemma / **gemma4** / glm4 / lfm2) are
   reliable; the rest fall to the **prompt-ReAct floor**, which gemma-4 handled badly (the no-response
   bug). **As of the main pin, gemma-4 resolves `.gemma4` → native tools** (on-device verify-owed that
   this kills the no-response bug).

---

## The registry, sorted by what matters

### ✅ Dense attention — safe (no recurrent-scan spike), all registry-confirmed
`qwen3` (dense Qwen3, **not** `.5`), `phi3` (Phi-4-mini), `llama`, `qwen2`, `gemma3`/`gemma3_text`,
`gemma4`/`gemma4_text` (E-variants only), `glm4`, `mistral3`, `smollm3`, `cohere`, `internlm2`,
`minicpm`, `starcoder2`, `olmo2/3`, `exaone4`.

### ⚠️ SSM / hybrid — GatedDeltaNet prefill cost (largely LIFTED on main)
`qwen3_5` (current lil/huge), `qwen3_next`, **`granite` / `granitemoehybrid`** (← the plan's
"Granite 4.1" candidate is a Mamba2 hybrid — *same family*), `falcon_h1`, `nemotron_h`, `jamba_3b`,
`minimax`. The prefill spike was the **sync stall**, not a per-token CPU scan — **main's #225 (asyncEval)
lifts it** (2.7–14.6× prefill on GDN models, scaling with context). Now a bake-off question, not an
automatic avoid; the recurrence itself stays on-GPU per step (inherent to SSMs).

### 🚫 Registered-but-blocked / RAM-heavy
- **`gemma4_unified` — registered on main's LLM path (#0767814), but gemma-4-12B STILL won't load as-is.**
  `LLMModelFactory.swift:35` maps `gemma4_unified → Gemma4Model` (text wrapper) and the 12B config decodes
  cleanly (text_config nested; 48 layers / hidden 3840; KV-share=0, PLE=0, k_eq_v=true all match). BUT the
  12B-unified checkpoint renamed its vision encoder to **`vision_embedder.*`** (11 tensors), which
  `Gemma4Model.sanitize` (mlx-swift-lm `MLXLLM/Models/Gemma4.swift:72-77`) does NOT drop — it drops
  `vision_tower`/`audio_tower`/`embed_vision`/`embed_audio` (e4b's names), not `vision_embedder`. → 11 orphan
  keys → `model.update(verify:[.all])` throws `UpdateError.unhandledKeys`. **Fix = one upstream line** (add
  `vision_embedder` to that drop list). Verified statically (conf 0.85) + the 11 tensors confirmed in the HF
  index; on-device load is the final gate. So: a `huge` candidate gated on an upstream `sanitize` fix, NOT a
  drop-in. (12B-4bit = 6.74 GB.)
  **⚠️ SUPERSEDED 2026-07-15:** the drop-list fix (#363/#366, merged 06-29) shipped in **tag 3.31.4** — the
  current pin. 12B loads clean, and the temporalOrder crash below did not reproduce. See the 2026-07-15 entry.
- MoE (RAM-hungry, viable but heavy): `qwen3_moe`, `glm4_moe`, `gpt_oss`, `deepseek_v3`, `phimoe`,
  `olmoe`, `bailing_moe`, `afmoe`.

---

## Verified candidates (HF API + config, 2026-06-22)

| Model id | Size (4-bit) | Arch | `model_type` | Tool dialect | Loads on 3.31.3 | Notes |
|----------|-------------|------|-------------|-------------|-----------------|-------|
| `mlx-community/Qwen3-4B-4bit` | 2.27 GB | **dense** | `qwen3` | `.json` (native) | ✅ verified | lil candidate; smaller than current lil |
| `mlx-community/Qwen3-8B-4bit` | 4.62 GB | **dense** | `qwen3` | `.json` (native) | ✅ verified | **huge candidate** — only loadable capable native-tool model at this size |
| `mlx-community/Phi-4-mini-instruct-4bit` | 2.17 GB | **dense** | `phi3` | `.json` (native) | ✅ verified | lil candidate; strong reasoning-per-size |
| `mlx-community/gemma-4-e4b-it-4bit` | ~5.25 GB | attention | `gemma4` | **ReAct floor** | ✅ (big until 2026-07-15 — 12B took the slot) | ⚠️ **no-response bug** (below); no quantized KV |
| `mlx-community/gemma-4-e2b-it-4bit` | 3.6 GB | attention | `gemma4` | **ReAct floor** | ✅ verified | ~2B-eff → **below M1K3's grounding floor** (per the 2026-06-13 2B→4B promotion) |
| `mlx-community/Qwen3-14B-4bit` | ~8 GB (verify) | dense | `qwen3` | `.json` | ⏳ verify-owed | would make a clean all-dense huge |
| `mlx-community/SmolLM3-3B-*` | ~1.8 GB (verify) | dense | `smollm3` | ReAct floor (no dialect) | ⏳ verify-owed | plan candidate; small |
| **current** lil `Qwen3.5-4B` / huge `Qwen3.5-9B` | — | **GatedDeltaNet hybrid** | `qwen3_5` | `.xmlFunction` | ✅ but **CPU-spikes** | works; the perf problem |
| **blocked** `gemma-4-12B-it-*` | — | unified | `gemma4_unified` | — | ❌ won't load | not in registry · **⚠️ SUPERSEDED 2026-07-15: loads on 3.31.4, promoted to big** |

---

## ⚠️ The gemma-4-e4b "No response" bug (observed 2026-06-22)

**Symptom:** simple chat ("How are things M1K3?") → chat shows **"No response."** with a full
`<think>` block present. The model's own reasoning ends: *"No action or response is required
unless the user speaks again. I must remain silent/ready."* — it **deliberately emits an empty
final answer.**

**Likely cause (primarily model behaviour, not pure UI):** M1K3 wraps every turn in the
agentic ReAct tool-loop framing + a brevity/DRY persona. gemma-4 was trained on its **own** native
tool format (not our ReAct text protocol), so on the ReAct floor it interprets the turn as "is a
tool ACTION needed?" → concludes "no action required" → **stays silent**. The brevity/DRY persona
reinforces silence as "correct." This is the same family of issue as the 2026-06-10 note ("Gemma-3n
announces tools in prose without emitting `ACTION:`").

**Verify-owed:** confirm it's not *also* a reasoning-split parse bug — i.e. check the raw model
output for any post-`</think>` answer text that M1K3's splitter is swallowing. The reasoning content
("remain silent") points at intent, but a parse contribution isn't excluded.

**Implication:** this is a **third strike** against gemma-4 for `big` (after ReAct-floor tools and
can't-fill-huge). Either fix the prompt/parse for gemma-4, or move `big` to a native-tool dense model.

---

## Recommendation (pending CHATEVAL)

| Tier | Recommended | Rationale | Confidence |
|------|------------|-----------|-----------|
| **mini** | Apple Foundation Models (keep) | works; no download | high |
| **lil** | eval **Qwen3-4B** vs **Phi-4-mini** | dense, native `.json` tools, smaller download; same-family (Qwen3) vs strong-small (Phi) | high it loads, eval picks winner |
| **big** | **Qwen3-8B** dense (or fix gemma-4 first) | gemma-4's no-response + ReAct-tools make it shaky for an agentic app; Qwen3-8B is dense + native tools | medium — depends on gemma-4 bug fix |
| **huge** | **Qwen3-8B** or **Qwen3-14B** dense | the only loadable, capable, native-tool models at this size (gemma-4-12B blocked); dense → kills the spike | high it loads, eval picks size |

**Cleanest single-family option:** an **all-dense-Qwen3 ladder** — `Qwen3-4B` (lil) / `Qwen3-8B`
(big) / `Qwen3-14B` (huge). One family, native `.json` tools, dense (no spike), fills every size.
Trade-off: one generation older than Qwen3.5 (Apr 2025 vs newer) and no on-device vision — both
largely moot for a RAG/text app (see "what we lose going dense" below).

### What we lose going dense (honest)
1. **One model generation** (Qwen3 ≈ Apr 2025 vs Qwen3.5 newer) — possible small quality/recency
   regression; *this is the only real cost, and CHATEVAL measures it.* A working older model beats a
   spiking/silent newer one.
2. **Long-context efficiency + a 256k window** — moot: M1K3 is RAG-bounded, and the hybrid's
   efficiency never materialised on 3.31.3 (it became the CPU spike).
3. **Multimodality / vision** — never used (text path only); only matters if M1K3 wants on-device
   image understanding later.

### License axis (the whole MLX lineup is Apache 2.0)

Verified on HF metadata + Google's announcement (2026-06-23):
- **Qwen3** (lil/huge): **Apache 2.0** — commercial use, fine-tuning, distillation, redistribution all
  clean (keep attribution / the `NOTICE`).
- **Gemma 4** (big): **Apache 2.0** — Google moved Gemma 4 to the OSI-approved Apache 2.0 license
  (Mar 2026, "first in the Gemmaverse"; no acceptable-use overlay per the announcement). The old custom
  **Gemma Terms** do NOT apply to Gemma 4. (M1K3's #86 licenses surface tagging it apache-2.0 is correct.)
- **Apple Foundation Models** (mini): used via the OS framework under Apple's terms; not redistributed.

So M1K3's model foundation is **unencumbered** — fine-tune any tier on Kev's own data and ship commercially.

Caveats (not legal advice — get a real IP review before a commercial ship leans on tuned/distilled weights):
- **Only Gemma 4 got Apache 2.0 — Gemma 3 still carries the custom Gemma Terms.** Moving `big` to Gemma 3
  (e.g. for native tools on 3.31.3) would RE-introduce license baggage. Gemma 4 is the clean Gemma.
- **Distillation legality is about the TEACHER, not the student's license tag.** Distilling from closed
  models (GPT/Claude/Gemini) likely violates their ToS (no-train-competitors) → provenance taint;
  murky-provenance HF "distilled" repos are a commercial + ethics risk (unauditable, and counter to M1K3's
  help-not-exploit thesis). Distill from an **Apache teacher you control** (Qwen3 / Gemma 4) instead.
- **Verify the repo's actual `LICENSE` file** (the announcement ≠ the authoritative text), and don't trust
  a community quant's license *tag* in isolation — confirm against the base model.

---

## Next steps

1. **CHATEVAL bake-off (the make-or-break measurement).** Candidates × tasks
   (`grounded-Q`, `open-chat`, `tool-use`, thinking quality), on an **idle** machine, **serialised**
   (per the 2026-06-20 thermal/contention lesson). Shortlist: lil = {Qwen3-4B, Phi-4-mini}; huge =
   {Qwen3-8B, Qwen3-14B}; big = {Qwen3-8B, gemma-4-e4b-if-fixed}. This is the one number that turns
   opinion into data.
2. **Investigate the gemma-4 no-response bug** — raw-output check (parse vs model intent); decides
   whether gemma-4 is salvageable for `big` or retired.
3. **Verify-owed repos** — confirm `Qwen3-14B-4bit` + a good `SmolLM3-3B` quant exist + sizes (HF tree API).
4. **Tier-count decision (product):** keep three MLX tiers, or collapse to two (a fast small lil +
   one strong big) — the loadable dense range may not justify three distinct steps.
5. **Ship the winners** as TDD'd id swaps (registry-confirmed dense → far lower risk than OptiQ).
   The code already distinguishes `qwen3` (dense, `.json`, no pre-open-think) from `qwen3_5`
   (xmlFunction, pre-open-think), so dense Qwen3 is near-drop-in.

---

## Runtime watch — mlx-swift-lm version (the gemma-4 unlock) — ✅ DONE 2026-06-23

**M1K3 now builds off `mlx-swift-lm` main** (`revision 40c2ff06` = PR #330's merge). The last
*release* was 3.31.3 (2026-04-15); two fixes that materially change the Gemma 4 calculus landed in
**main** after that tag, so a release pin couldn't reach them:

- **Native Gemma 4 tool-calling** — `mlx-swift-lm` **PR #183** ("Adopt GemmaFunctionParser to
  accommodate Gemma4 tool calls", merge commit `8c618003`, ~2026-05-22) extends the `gemma` parser to
  Gemma 4's `<|tool_call>call:name{key:<|"|>value<|"|>}<tool_call|>` format. (Python `mlx-lm` got the
  same via PR #1105, 2026-04-05 — but that's the Python package, irrelevant to our Swift app.) Once
  this is in a release, M1K3's `resolveToolCallFormat` can return a real dialect for gemma-4 instead
  of `nil` → gemma-4 gets NATIVE tools instead of the ReAct floor, which likely kills its no-response bug.
- **Gemma 4 E-series load fix** — `mlx-swift-lm` **PR #330** (MERGED to main 2026-06-23) "Fix Gemma4
  QAT (E-series) load: KV-shared layers have no k_proj/v_proj/k_norm" is the exact `k_proj.weight not
  found` error we hit loading gemma-4 OptiQ — a known gemma-4-loader gap, not purely OptiQ's fault.
  **As of 2026-06-23, main has BOTH #183 and #330.**

**The spike PASSED (2026-06-23) → shipped.** `Package.swift` pins `revision 40c2ff06` + the regenerated
`Package.resolved` is committed (Xcode Cloud needs the lockfile — the exit-74 lesson). What the spike proved:
- **The WhisperKit / swift-transformers clash did NOT fire** — mlx-swift-lm depends on *neither*
  swift-transformers nor WhisperKit (only mlx-swift + swift-syntax), so it can't drag them. Confirmed both
  analytically and by a clean `swift package resolve`.
- **Blast radius = exactly two resolved pins:** mlx-swift-lm → the revision, and swift-syntax
  `600.0.1 → 603.0.2` (a prebuilt macro artifact — no source compile). Every other pin (incl.
  swift-transformers 1.1.9, WhisperKit 0.18.0, mlx-swift 0.31.4) is byte-identical to master. Zero new packages.
- **The whole lineup builds + the full suite is green off main** (1525 tests / 237 suites). The
  ~2-months-of-drift regression risk is covered by the on-device verify (esp. the dense Qwen3 path).
- **gemma-4 now routes `.gemma4` → native tools.** Whether that kills the no-response bug is the named
  **on-device verify-owed**.

**The pin is explicitly TEMPORARY.** The armed weekly release-watch flags when `mlx-swift-lm` cuts a
*release* > 3.31.3 (which will contain #183 + #330); at that point swap the revision back to
`.upToNextMinor(from: "<next-tag>")` — the cleaner long-term pin. Until then the revision is reproducible
(fixed SHA) and gives us gemma-4 native tools + Apache 2.0 now.

**Net for `big`:** gemma-4-e4b now has native tools AND Apache 2.0 (vs Gemma 3's custom Gemma Terms),
clearing two of the three strikes against it — *if* the on-device verify confirms the no-response bug is
gone. Otherwise dense Qwen3-8B stays the `big` fallback (see Recommendation).

---

## What building off main unlocks (the level-up — 2026-06-24)

Pinning main wasn't just the gemma-4 tool-calling fix — the same ~40 commits (3.31.3 → `40c2ff06`)
carry a stack of capabilities. Verified against the local checkout. **✅ = now live via the pin ·
🔬 = reachable, needs a verify/eval · 🚫 = still blocked.** Each is its own scoped piece of work.

**Gemma 4 (`big`) — went from shaky to strong:**
- ✅ **Native tool-calling** (#183) — shipped (PR #98); `resolveToolCallFormat` → `.gemma4`. Should kill
  the no-response bug (on-device verify-owed).
- ✅ **E-series load fix** (#330) — the `k_proj.weight not found` gap closed.
- 🔬 **Decode +23.8%** (#82d9cd6) + **MTP speculative decoding** (#e145aca) + a **MoE router fix** —
  gemma-4 is now faster, not just functional. Free on the pin; confirm on-device.
- 🚧 **gemma-4-12B — registered (#0767814) + config decodes, but BLOCKED by a `vision_embedder` sanitize
  gap** (one upstream line in mlx-swift-lm `Gemma4Model.sanitize`). The 12B-unified checkpoint renamed its
  vision encoder `vision_tower`→`vision_embedder` (11 tensors); the LLM-path drop-list misses it → orphan
  keys → load throws `unhandledKeys`. A real **`huge`** candidate + all-Gemma-4 ladder (`big` e4b + `huge`
  12B, Apache 2.0) ONCE the drop-list is patched. 12B-4bit = 6.74 GB (fits the 12 GB ceiling, but gemma-4 has
  no quantized KV → tight). Verified statically (recon workflow 2026-06-24); on-device load is the gate.
  **⚠️ SUPERSEDED 2026-07-15:** shipped in tag 3.31.4; 12B is live as `big`. See the 2026-07-15 entry.

**Qwen3.5 — the perf blocker is GONE (re-opens the bake-off):**
- ✅ **GatedDeltaNet prefill 2.7–14.6×** (#225 asyncEval) — scales with context = our exact symptom.
  Plus #229 (−2× SSM memory) + fp32 state (quality) + #323 recurrent-cache fixes.
- 🚫 **OptiQ still won't load** — zero OptiQ loader on main; the token-soup cause is unchanged.
- 🔬 **Net:** Qwen3.5 (4B/8B) is worth a CHATEVAL vs dense Qwen3 again — the perf blocker that made it
  "not worth measuring" is lifted. Decider = reasoning quality vs dense, on our context lengths.

**New quant + tuning machinery:**
- 🔬 **ParoQuant + AutoAWQ loader** (#164) — a real mixed-precision / AWQ-checkpoint path (≠ OptiQ);
  opens AWQ-quantized variants we couldn't load before.
- 🔬 **LoRA runtime toggle + PEFT adapter loader** (#5626257) — directly enables the long-carried
  **"knows-me" LoRA** thread: load a fine-tuned adapter at runtime over a base brain.
- ℹ️ **Audio I/O plumbing** (#a47894a) — `UserInput.audios` exists now, but there's still no Gemma audio
  *tower* in Swift (`Gemma4.swift` = "text + vision only") → **WhisperKit stays** (the STT decision holds).
- ℹ️ Quant *formats* (mxfp4/mxfp8/nvfp4) were already in 3.31.3 — no new bit-widths, just ParoQuant/AWQ.

**The shape of the level-up:** `big` becomes a fast, native-tool, Apache-2.0 Gemma 4; `huge` could become
Gemma-4-12B (one clean family, no SSM); `lil`/`huge` get a fair Qwen3.5 re-match; and the knows-me LoRA
path finally has a loader. Nothing here is claimed shipped beyond #98 — it's the now-reachable menu, each
item its own TDD'd id-swap or eval.

---

## ⚠️ Promoting a brain now requires re-pinning (since 2026-07-21)

Shipped model weights are pinned to a commit SHA and verified against sha256
digests committed in `Sources/M1K3MLX/PinnedWeights.swift` — see
[ADR 0002](adr/0002-pin-and-verify-downloaded-model-weights.md). Swapping a
model id is therefore **two** changes, not one:

```bash
# 1. download + actually exercise the new checkpoint (pin bytes you have run)
# 2. regenerate the manifests — cross-checks against HF, hard-stops on mismatch
python3 macos/tools/weights/pin_weights.py
```

That writes **two** files from the same data: `PinnedWeights.swift` (what the
app enforces) and `weights-manifest.json` (the published, machine-readable
twin — see [MIRRORING_WEIGHTS.md](MIRRORING_WEIGHTS.md)). Commit both; a
published manifest that disagrees with what the app enforces is worse than
publishing none. `--check` fails if either is stale.

The script also refuses to pin unless the local snapshot's recorded commit
matches the revision being pinned, so a stale local cache cannot silently
produce a manifest that makes every honest download look tampered with.

Add the repo to `SHIPPED_REPOS` in that script first. An unpinned repo still
loads (`WeightIntegrity.Verdict.unpinned`), so **a forgotten re-pin fails open,
silently** — it does not break the build. The `PinnedWeightsTests` suite is the
backstop: it asserts every user-selectable brain has a pin with real weights in
it. Extend it when a tier changes.

Eval A/B overrides (`M1K3_SELFTEST_CHATEVAL_MLX_MODEL`) and spike checkpoints
are deliberately left unpinned so the evaluation loop stays usable.

---

## Decision log

- **2026-08-08: pin bumped to main `c97539da` (MTP-capable) · gemma-4 chat template FIXED
  in-app · MTP re-measured and still PARKED — now for a measured reason.**
  Three findings, in order of how much they cost:
  - **The bump broke gemma-4 tool-calling, 5/5 → 0/5**, and only the mandated NATIVE
    tool-call smoke caught it. Upstream #453 (typed KV cache config + validation, 08-05)
    now *throws* `incompatibleCapacity(expected: 8192, count: 8)` on a caller-requested
    `maxKVSize`. Root cause is worse than a regression: `Gemma4Text.newCache` **ignores
    `parameters` entirely** (StandardKVCache for the 8 `full_attention` layers, a
    modelNative `RotatingKVCache(slidingWindow)` for the rest) — so our 8192 "hard bound on
    KV growth" was **always a silent no-op on Big**. Upstream merely made a false belief
    loud. Fix: `MLXGemmaProvider.supportsCallerKVCapacity`. A test that pinned
    `maxKVSize == 8192` for gemma-4 was corrected, not deleted.
    **⚠️ CORRECTED IN #108 — the first cut of this fix was a deny-list with a
    permissive default (gemma-4/3n excluded, everything else allowed), and it was
    wrong.** Evaluating LFM2.5 hours later hit the identical throw, because 27 of
    upstream's models override `newCache` and ignore `parameters` — the hybrids
    (Mamba/Jamba/Granite/Nemotron/Qwen3Next) as much as gemma. #108 flips it to an
    **allow-list defaulting to false**, version-scoped (`llama-3`, not `llama`),
    on the asymmetry: wrongly requesting a capacity fails the model every turn;
    wrongly omitting one only forgoes a backstop `maxTokens` already bounds.
  - **The gemma-4 chat template is now fixed on-device.** Google published the canonical
    template 2026-07-09 (tool-call loops, turn closures, null args, thinking order);
    `mlx-community/gemma-4-12B-it-4bit` still shipped the 2026-06-03 one, 7 weeks
    unpropagated. Rather than keep waiting, M1K3 **vendors** the canonical file and
    installs it over exactly the known-stale bytes (`Gemma4TemplateFix`, exact-hash-gated
    both ways) *before* the integrity scan — whose manifest now pins the healed hash. The
    template is tokenizer metadata, independent of the safetensors, so this is precisely
    what a re-quantize would have carried. Verified live: on-disk hash went
    `36e3a42e…` → `ae53464b…` on first load.
  - **MTP: engages now, and still loses on our prompts.** #415 fixed the July blocker
    (gate 2 went from "0 drafted, sticky passthrough" to **52% accept**), but gemma-4-12B's
    sliding window is **1024 tokens** and M1K3's measured production prompt is
    **1863–2998** (persona+tools KV seed alone is 1380). Every real turn lands in the
    wrapped regime: **0.79–0.87× baseline** (the passthrough path is slower than plain
    generate) and the medium fixture **diverges at char 314 despite #506's stand-down** —
    a hard failure of speculative decoding's own greedy invariant. Full numbers:
    `scratch/mtp-spike/RESULTS-2026-08-08-rerun.md`. **Revisit trigger changes** from
    "upstream can't" to "our prompt fits 1024 tokens, or upstream makes the wrapped regime
    faithful+engaging". Also note `mlx-swift` had to move 0.31.4 → 0.31.6 (main needs
    `DType.greatestFiniteMagnitudeArray` / `MLXArray.maskFill`), and its `CudaBuild` plugin
    now needs `-skipPackagePluginValidation` on `xcodebuild`.

- **2026-07-02 (later): HUGE RETIRED — Qwen3-8B leaves the catalogue; three tiers (Mini/Lil/Big).**
  Step 1 of Kev's all-gemma reshuffle (standing intent since the Golden Gate session: mini=AFM ·
  lil=gemma-4-e4b · big=gemma-4-12B, gated upstream). The gate that mattered cleared: **gemma-4
  native tool-calling on 3.31.4 is Kev-verified live and performing well**, so Qwen3-8B's one
  remaining role (the "biggest brain" slot) no longer justified its record — 2/5 on tool-use with
  130–315 s loop-thrash (the 06-24 bake-off), nobody's favourite at anything. Retirement is
  unblocked and independent of the 12B gate. Mechanics: `.huge` removed from `BrainTier`; a
  persisted `"huge"` migrates to `.big` via the new `BrainTier(persisted:)` (never a silent Mini
  downgrade); 48GB+ Macs now recommend Big; the memory-floor/`isSelectable` seam is KEPT (nil
  today) for 12B-Big's return. **Side effect:** the MTP entry below named "classic speculative
  decoding on huge (Qwen3-8B + 0.6B draft)" as the realistic decode-speed experiment — that spike
  is MOOTED with the tier; a future spec-decode look targets whatever 12B-class model lands in Big.
  Follow-up (not in this change): stale Qwen3-8B weights (~4.6 GB) linger in the container cache
  for migrated Huge users until a cache-cleanup pass.
- **2026-07-02: MTP PARKED for big (gemma-4-e4b) — batch-1 evidence is a regression, not a win.**
  Review triggered by "Python MLX shipped MTP" — which is a conflation: **`mlx-lm` proper has NOT
  shipped MTP** (latest v0.31.3, no MTP commits; only unmerged PR #1161). MTP in the Python ecosystem
  lives in **mlx-vlm** (v0.6.0/0.6.1, June 2026: Qwen MTP + Gemma 4 Unified/MTP), LM Studio's MLX
  engine 1.8.1, and Ollama 0.31. On OUR runtime: **mlx-swift-lm 3.31.4 DOES carry the MTP API**
  (#308/e145aca — `generate(... mtpDrafter:blockSize:)`, `MTPSpeculativeTokenIterator`,
  `MTPDrafterModelFactory`), and Google ships an official ~79M gemma-4-E4B drafter checkpoint. BUT:
  (a) the only MTP-aware **target** is MLXVLM's Gemma4 — M1K3 loads via **MLXLLM**, whose Gemma4 has
  zero mtp plumbing (silent single-token passthrough, no crash, no speedup); (b) the load-bearing
  batch-1 benchmark (M1 Max, mlx-vlm) shows **E4B + MTP = 29.6 → 18.1 tok/s, a −39% REGRESSION** —
  the technique pays on 12B/26B-class models at batch >1, not E4B at batch 1; (c) quantized KV
  disables MTP upstream. Also: Swift **strips `mtp.` weights even from Qwen3.5 checkpoints** —
  Qwen-side MTP heads (3.6-era) are Python-only. **Revisit trigger:** big ever moves to a 12B+ model
  (where the RotatingKVCache 12B crash is the other gate anyway). **The realistic decode-speed
  experiment instead: classic speculative decoding on huge** (Qwen3-8B target + Qwen3-0.6B-4bit draft
  ≈0.4 GB, shared tokenizer ✓, `SpeculativeDecodingConfig` + memory policy already in 3.31.4, fits
  the 12 GB ceiling) — M-sized spike via the SelfTest TTFT harness; verify-owed: quantized-KV
  trimmability in practice + tool-calls parsing through the speculative loop. No published Apple-
  Silicon numbers for that pairing — measure, don't assume.
- **2026-06-22:** OptiQ swap reverted — `mlx-optiq` incompatible with mlx-swift-lm 3.31.3 (no Swift
  loader). Huge CPU spike root-caused to Qwen3.5 GatedDeltaNet. gemma-4-e4b no-response bug observed.
  Direction set: move off the Qwen3.5 hybrid to **dense** models; CHATEVAL to pick. See
  `.claude/project-memory.md` 2026-06-22 for the full arc.
- **2026-06-23:** Dense Qwen3 (lil/huge) shipped + verified on-device (clean prose, native tool-calling).
  Leaked-tool-call stripper shipped (spurious `<function_call>` blocks). **License axis clarified: whole
  MLX lineup is Apache 2.0** (Gemma 4 moved to Apache 2.0 Mar 2026 — *not* the custom Gemma Terms;
  corrected an earlier wrong read). **mlx-swift-lm main now has #183 (gemma-4 tools) + #330 (E-series
  load), both merged** → gemma-4-native-tools is now reachable via a main pin (spike-first, WhisperKit
  clash risk) or the next release (watch armed).
- **2026-06-23 (cont.):** **Shipped the build-off-main spike.** `mlx-swift-lm` pinned to `revision 40c2ff06`
  (main HEAD = #330 merge); `resolveToolCallFormat` flips gemma-4 `nil → .gemma4` + a `gemma4CallText` echo
  renderer (extracted a shared `gemmaStyleCallText`; Gemma 3 unchanged). TDD'd RED→GREEN; tdd-enforcer +
  code-quality + pr-reviewer all green; full suite **1525** green off main. Resolve was clean — NO
  WhisperKit/swift-transformers clash (mlx-swift-lm depends on neither); only mlx-swift-lm + swift-syntax
  (600→603, prebuilt) move. gemma-4 native tools now REACHABLE; the **no-response-bug fix is the on-device
  verify-owed**. Pin is temporary → swap to a tag when the release-watch fires.
- **2026-06-24:** **Mapped what building off main unlocks** (see the section above) + **corrected the
  06-22 GatedDeltaNet diagnosis** — the Qwen3.5 spike was the prefill *sync stall* (fixed by #225's
  asyncEval, 2.7–14.6×), NOT per-token CPU dispatch (the fused kernel was always one GPU dispatch; the
  `for t` at `GatedDelta.swift:244` is the CPU fallback). Confirmed against the local checkout: **OptiQ
  still has no Swift loader** (token-soup cause unchanged), but **ParoQuant/AWQ** (#164) is a new
  mixed-precision path; **gemma4_unified is now registered on the LLM path** (#0767814) but gemma-4-12B is
  **blocked by a one-line `vision_embedder` sanitize gap** upstream (recon 06-24 — config decodes, but the
  renamed vision tensors orphan-throw at load; on-device load is the gate); gemma-4 gained **decode +23.8%** (#82d9cd6) + MTP spec-decoding; and a **LoRA/PEFT adapter
  loader** (#5626257) lands the knows-me thread. Net: `big` = strong Gemma 4; Qwen3.5 perf blocker lifted
  (bake-off worth running again); OptiQ stays parked.
- **2026-06-24 (bake-off):** **gemma-4-12B PARKED as `huge` — verified on-device, fails on tool-use.**
  Built off the #363 pin (the `vision_embedder` sanitize fix) and ran it end-to-end. It **LOADS clean** (no
  `vision_embedder` orphan-throw — #363 works), generates coherent prose, and fits memory comfortably (**peak
  7.4 GB** active vs the 12 GB ceiling, flat across a memloop — better than the ~9 GB estimate). BUT it
  **crashes on the first tool-use fixture**: a `RotatingKVCache.temporalOrder` assertion (`Gemma4Attention →
  RotatingKVCache.update`). Proven **unfixable from M1K3's side** — it crashes under `maxKVSize=8192` AND
  `maxKVSize=nil` (the "maxKVSize forces a uniform cache" theory was disproven on-device; both configs crash).
  The bug is **12B-specific**: `big` (gemma-4-e4b) shares the same RotatingKVCache path but passed tool-use
  **5/5, no crash** — e4b has 18 KV-shared layers + PLE, the 12B has **0 KV-shared layers**, and that
  no-sharing sliding geometry is what trips `temporalOrder`. So **no `big`/production regression**, and the
  swap is blocked on an **upstream** `RotatingKVCache` bug, *separate from #363*. **Decision: `huge` stays
  Qwen3-8B.** Revisit gemma-4-12B when upstream fixes `temporalOrder` for no-KV-sharing gemma-4 (the
  release-watch will catch a tag carrying it). CHATEVAL data (the clean parts): on the
  openChat/grounded/reasoning overlap (19 fixtures) gemma-4-12B and Qwen3-8B both scored ~18/19, but
  **gemma-4-12B was far faster on reasoning** (1–7 s vs Qwen's ~57 s); Qwen3-8B finished 23/36 overall but
  **loop-thrashes on tool-use** (2/5, 130–315 s/fixture) where `big`/e4b aced it 5/5 — i.e. the *incumbent
  huge* has a tool weakness worth a future look. Side-finding: the CHATEVAL **refusal scorer was
  false-FAILing genuine refusals** (curly-apostrophe mismatch + missing "I don't <verb>" phrasings) — fixed
  in this same change (`ChatEvalScorer.isRefusal`: apostrophe normalisation + flat-decline markers).
- **2026-07-15 (the 12B gate): gemma-4-12B PROMOTED to `big` — both June blockers cleared, live-path swept.**
  The `vision_embedder` sanitize fix (#363/#366) shipped in **tag 3.31.4** (the standing pin since 07-01), and
  the `RotatingKVCache.temporalOrder` tool-use crash **did not reproduce**: the full tool arm ran on the
  rotating cache, exit 0 (what changed upstream between the 06-24 pin and the tag is unattributed — the gate
  is empirical, re-verify on any dep bump). Ten same-morning headless CHATEVAL runs, idle GPU (raw reports:
  `macos/scratch/eval-2026-07-15-model-runs/`): **12B vs e4b** — live-path open-chat **8/8·24.9s vs
  5/8·21.6s** (e4b's fails: 3 length-band blowouts + an "M1K3:" self-label leak) · code-gen **5/5·max 57s vs
  4/5 with a 1032s melt** (code-landing-page) · reasoning **6/6 vs 3/6** · prompt-leak security **7/7 vs 4/7**
  (e4b recites its rules verbatim) · tool-use **4/5·30.9s vs 5/5·11.9s** — the one cost: **~2.6× slower tool
  turns** (12B's miss was a 125s-vs-120s ceiling nick, answer correct). Same cache geometry as e4b (rotating
  8192, no quantized KV), ~7.4GB peak (06-24 memloop). Ships with a **16GB selection floor** (the seam kept
  warm since Huge retired) + `approxDownloadMB` 6740 — existing Big users pay one ~6.7GB re-download at the
  model gate. Key context finding: the 07-14 "26.8-min greeting" was GPU **contention**, not the model (same
  fixture idle: 21.6s). Side-catch, fixed separately (PR #42): three more refusal-scorer false-FAIL phrasings.
  Watch-item: if ~31s tool turns grate in-app, the per-tier think-budget conversation reopens — with the
  live-path arm as its instrument. **Bonsai-8B evaluated same morning for `lil`: PARKED** — 2× faster than
  Qwen3-4B everywhere but recites the hardened system prompt on 5/7 leak fixtures (details in the scratch
  RESULTS.md); re-eval on a prism-ml update.
- **2026-07-16 (the Lil refresh): Qwen3-4B-Instruct-2507 PROMOTED to `lil` — Bonsai's speed without
  Bonsai's leak.** Full 44-fixture CHATEVAL (Run E, idle GPU, live path; raw report in the eval scratch
  dir): open-chat 8/8·9.7s · code-gen 5/5·9.4s · **tool-use 5/5·4.4s** (incumbent 21.0s; Bonsai 4.2s) ·
  refusal 5/5 · security **6/7 on eyeball** — its one real miss is leak-completion, the SAME fixture the
  incumbent fails the same way (the leak-passphrase "FAIL" was a scorer decline-marker miss: the answer
  denied the passphrase without reciting anything — marker-ledger candidate). The speed is architectural:
  the 2507 refresh is Qwen's NON-THINKING instruct variant — no <think> phase, reasoning answers 1.8s vs
  11.9s. Honest cost: reason-days missed (5/6; the same fixture Bonsai misses — the non-thinking trade).
  Zero adoption risk: model_type qwen3 → same Qwen3Model path, quantized KV, .json tools, ~2.1GB.
  **Toggle nuance:** the 2507 templates (Instruct AND Thinking variants) carry NO enable_thinking —
  `templateSupportsThinkingToggle` excludes "2507" so the reasoning picker doesn't become a dead control.
  Caveats: single eval run; approximateContextTokens stays 32768 (2507 is 256K-native — deliberately
  conservative, the budget layer under-promises). Existing Lil users pay one ~2.1GB re-download.

## 2026-08-12 — the front/deep split, ruled

Kev, after driving the live app over MCP (verbatim — an earlier abridgement of
this dropped the qualifier in the last sentence, which changes the reading):

> "The smaller agent is much better for these kind of tasks. Like, I'm thinking we
> were looking at LM for liquids new model for the agent as well. Like, I think we
> baselined it, but it wasn't a hit. But, like, the speed of the agent and its
> ability to tool call and give back decent answers is better than any, you know,
> deep reasoning model when it comes to just usability. **We need the deepness and
> the richness of context as well and speech from the deep model** was... you know?
> I think the smaller the model we can deploy, the more usable model wins all the
> time. And big is just an add on for deep reasoning."

★ The bolded clause is the half a summary loses. This is NOT "Big is optional" —
the deep tier's answer quality is rated and wanted; what changes is only which
brain answers WITHOUT being asked. Which is why the open question below (nothing
downloads Big any more) is a real problem rather than a tidy consequence.

So the roster is now read as a FRONT and a DEPTH tier, not a quality ladder:

| role | tier | why |
|---|---|---|
| **front** | Lil (`Qwen3-4B-Instruct-2507-4bit`) | 10.0s median vs Big's 30.5s on the same fixtures; 7.7s twice over MCP on 2026-08-12, in character, with a clean abstention. Tool-calling is what a usable assistant is made of, and it is good enough at 4B. |
| **fallback** | Mini (AFM) | instant, no download — and structurally the SLOWEST per turn (37.3s median: a fresh `LanguageModelSession` re-sends the persona every call, where the MLX tiers reuse a cached KV prefix). Fronts only when the slot cannot serve. |
| **depth** | Big (`gemma-4-12B-it-4bit`) | not retired, not resident. Reached by delegation for work that earns minutes. |

**The open consequence (Kev's call, recorded not decided):** since #117 nothing
in the product downloads Big — the recommendation never names it and
`UpgradeTarget.next` cannot offer it — so on a new install the deep tier is
present in the code and absent from the machine. Either that is intended (the
12B is legacy) or the missing piece is a depth-framed download route, not more
delegation plumbing. See `docs/NEXT_SESSION.md`.

**Kev's own next probe:** re-look at Liquid's LFM line for the front ("we
baselined it, but it wasn't a hit"). The 2026-08-08 bake-off scored LFM2.5-2.6B
36/44 against Lil's 38/44 with +870% latency — but it BEAT Lil on `reasoning`
(6/6) and `security` (5/7, winning two of the three prompt-leak fixtures the
incumbent fails), which is the standing weakness of whatever runs Lil.

★ **That latency number is under suspicion, and the suspect is our code.**
LFM2.5's mean was dragged by `grounded-Q` at 41s against its OWN `reasoning`
average of 3.2s — a 13× spread within one model, across kinds, which is a
plumbing signature rather than a speed one. Named 2026-08-13:
`MLXGemmaProvider.slidingWindow(forModelID:)` returns nil for everything except
gemma-4, and nil means "dense attention, prefix reuse works" — while the same
file records that `LFM2Model` builds `KVCacheSimple` + **`MambaCache`**. Reusing
a prefix is not a meaningful operation on a RECURRENT state, so LFM2.5 plausibly
re-prefilled persona + grounding on every question, which is exactly why the
grounded kind (the big-prompt kind) collapsed while bare reasoning did not.
Same unscoped-family-assumption shape as the sibling bug #108 fixed.

So the sequence is: confirm from ONE grounded turn's `ttft` log, scope
`prefixIsReusable` if confirmed, and only then re-run — a 36/44 scored while
paying a per-turn tax the incumbent does not pay is not like-for-like. Full
reasoning and the do-not-do warning in
`scratch/model-refresh-2026-08-08/LIL-BAKEOFF-RESULTS.md`.

<!-- Signed: Kev + claude-opus-5, 2026-08-12, Confidence 0.9 (the ruling is Kev's,
quoted; the latency figures are the 2026-08-11 eval plus two live MCP turns timed
this session; the "nothing downloads Big" consequence was found by a challenger
pass against CapabilityLadder/DeepDiveTarget and is the reason this entry names an
open question rather than closing one). Prior: Kev + claude-fable-5. -->

<!-- Review: Kev + claude-opus-4-8, 2026-06-24 (bake-off), Confidence 0.9 — gemma-4-12B verified on-device
end-to-end: loads (#363) + generates + RAM 7.4 GB, but a deterministic RotatingKVCache.temporalOrder crash on
tool-use, reproduced under both maxKVSize settings and isolated to the 12B (no-KV-sharing) geometry vs e4b's
crash-free 5/5. The decision (huge stays Qwen3-8B) follows from a hard crash on core functionality, not a
quality call. Prior: Kev + claude-opus-4-8. -->

<!-- Signed: Kev + claude-opus-4-8, 2026-06-22, Confidence 0.85 (registry + repo facts verified on-device/web;
gemma-4 no-response is model-behaviour-primary with a named parse verify-owed; the dense-vs-hybrid split is the
load-bearing lens; CHATEVAL is the named decider). Prior: Unknown. -->
<!-- Review: Kev + claude-opus-4-8, 2026-06-24, Confidence 0.85 — reconciled to building off main (revision
40c2ff06): corrected the 06-22 GatedDeltaNet diagnosis (prefill sync stall, fixed by #225 — NOT per-token CPU
dispatch), added the "What building off main unlocks" map, flipped the gemma4_unified registry status. All
findings verified against the local mlx-swift-lm/mlx-swift checkouts (commit SHAs cited). The capability
claims beyond PR #98 are marked 🔬 (reachable, verify/eval-owed), not shipped. Prior: Kev + claude-opus-4-8. -->
<!-- Review: Kev + claude-fable-5, 2026-07-15, Confidence 0.9 — the 12B promotion entry + two SUPERSEDED
notes on the (now-stale) blocked claims. Both gates verified empirically same-day: tag-source check for the
sanitize fix, crash-free full tool arm for temporalOrder. The eval matrix is ten single runs (no variance
bars) with an idle GPU; the contention finding is the instrument's own control (same fixture, 26.8min→21.6s).
Honest opens: what fixed temporalOrder upstream is unattributed — re-verify on any dep bump; 12B RAM carried
from the 06-24 memloop, not re-measured. Prior: Kev + claude-opus-4-8. -->
<!-- Review: Kev + claude-fable-5, 2026-07-16, Confidence 0.9 — the Lil 2507 promotion entry. Both
security fails eyeballed against raw answers (one shared-with-incumbent real leak, one scorer artifact);
the speed contrast is thinking-vs-non-thinking, robust to the single-run caveat. Prior: Kev +
claude-fable-5. -->
