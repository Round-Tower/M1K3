# M1K3 — Mac-Native MVP

> **For "what's next," see `ROADMAP.md`.** This file is the historical build
> log / decision record — append-only, signed, kept exactly as written. It
> answers *why* a decision was made; it's no longer where current work is tracked.

## Context

M1K3 today exists as a Python desktop CLI + MCP servers and a Kotlin Multiplatform mobile app (Android shipping, iOS a shell). **There is no Mac-native app.** This plan builds one: a native SwiftUI macOS app that is M1K3's first-class desktop surface — local, private, on-device AI with live voice, a knowledge graph, document memory, an embedded agent, and an MCP server so Claude (and other agents) can pull from it.

The strategic unlock from exploration: we are **not** building this from scratch. Two prior internal projects (a knowledge server and a call pipeline, both private) contain production, eval-gated **Swift** IP for almost every requirement. The MVP is mostly *lift, generalise, and reskin behind a native shell* — not greenfield.

**Key decisions (from Kev, 2026-06-06):**
- **LLM runtime:** keep options open — build **both** an MLX-Swift (Gemma 4) and a **LiteRT-LM (Gemma 4)** backend behind one provider protocol, so we can compare support/capability. **Apple Foundation Models** handles cheap/basic turns. Embeddings stay on MLX-Swift (already proven in the prior knowledge-server project).
- **TTS:** native `AVSpeechSynthesizer` now, behind a protocol; swap in Kokoro post-MVP.
- **Target:** **macOS 26 Tahoe only** → real SwiftUI Liquid Glass + on-device Foundation Models.
- **Avatar:** 3D via **RealityKit/SceneKit**.
- **Call transcription + log (NEW):** M1K3 records/transcribes calls with a searchable, summarised log — exactly like the prior call-pipeline project. North star is **one model for all complex work** (ASR + reasoning + summary). Transcription sits behind a **provider protocol** (the prior call pipeline already has one), WhisperKit/AppleSpeech is the reliable default, and a `GemmaAudioTranscriber` is the spike toward the single-model goal — promote it when it wins on latency/accuracy. *(Superseded in part — see the Gemma 4 update below.)*

---

## Status reconciliation — 2026-06-22 (model review)

The "Update —" log below is an append-only historical record (signed; not rewritten). This block
is the **current truth** where the log has drifted:

- **LiteRT-LM backend → DROPPED, never built.** The 2026-06-06 "build both MLX *and* LiteRT" decision
  resolved in MLX's favour. There is no `LiteRTGemmaProvider` in the tree and no scratch spike. The
  inference layer is **MLX-Swift + Apple Foundation Models** only. Treat LiteRT references below as
  historical context, not roadmap.
- **CMUdict TTS swap → SUPERSEDED by misaki.** The recurring "CMUdict dict swap (proper TTS fix)"
  carry-forward is obsolete: the misaki Apache-2.0 G2P dictionary shipped (PR #85, commit f00f5882),
  replacing the espeak GPL path. Only re-open if a concrete gap over misaki is identified.
- **Phase 16 (on-device LoRA) → SPIKED, not "next".** The lil-4B QLoRA spike ran to completion
  (results in `scratch/lora-spike/`). Remaining work is narrow: fuse → point lil's brain at the fused
  model → A/B with voice exemplars removed from the prompt.
- **Phase 17 (prompt-hardening v2) → largely SHIPPED.** Prompt + enforcement landed (#41 hardened
  prompt, #69 citation-noise abstain; `M1K3Persona`/`CanaryGuard`/`CitationFooter` live). Remaining
  sub-items: the self-query router and knowledge-index segregation.
- **Phase 21 (model & inference upgrade) → PLANNED.** Research complete (2026-06-22): OptiQ
  mixed-precision swap is the quick win (PLE bug fix + reasoning lift, same families); Phi-4 Mini /
  SmolLM3 / Granite 4.1 are eval-gated candidates; Gemma 4 12B + Qwen3.6 MoE blocked on upstream
  mlx-swift-lm arch registration. Full plan at `.claude/plans/composed-skipping-floyd.md`.
  - **STATUS 2026-06-22 (verify, additive — see project-memory):** OptiQ swap ATTEMPTED on-device and
    REVERTED (#91 closed). `mlx-optiq` is **incompatible with mlx-swift-lm 3.31.3** — no Swift OptiQ loader
    (the format targets Python `mlx-lm`): Qwen3.5 OptiQ → token-soup, gemma-4 OptiQ → hard load failure
    (`k_proj.weight not found`). 3.31.3 is the version ceiling, so **OptiQ is PARKED until upstream adds it.**
    Separately found the base Qwen3.5 tiers use **GatedDeltaNet** (per-timestep recurrent scan) → CPU-heavy
    on Huge (9B). Net: **Part B (Phi-4 Mini / SmolLM3 / a DENSE-attention model) is now the path, esp. for
    Huge** — two reasons (OptiQ-incompat + GatedDeltaNet perf). All tiers reverted to working uniform 4-bit.
  - **STATUS 2026-06-24 (additive — supersedes the OptiQ/12B framing in the Phase 21 body below):** Phase 21
    moved since the 06-22 plan, and **Layer B is the live edge, not Layer A.** Shipped: dense Qwen3 tiers
    (lil→`Qwen3-4B-4bit`, huge→`Qwen3-8B-4bit`, #94 — on-device verified incl. native tool exec) + gemma-4
    native tool-calling (#98 — built off the mlx-swift-lm `main` revision, `.gemma4` dialect). **Layer A
    (OptiQ "quick win, do first") is DEAD — do NOT re-attempt:** there is still no Swift OptiQ loader even
    off `main` (re-confirmed #98), so the "do first" framing below is superseded. **gemma-4-12B as `huge`
    → REJECTED on-device (#100):** the `vision_embedder` sanitize gap closed so 12B now LOADS + RAM-fits
    (7.4 GB peak), but it deterministically CRASHES on first tool-use (`RotatingKVCache.temporalOrder`, the
    12B no-KV-sharing geometry) under both `maxKVSize` settings — an upstream mlx-swift-lm bug, unfixable
    from M1K3. **`huge` stays Qwen3-8B.** So the "12B/MoE blocked on arch registration" lines below are
    stale (12B is registered + loads; the tool-use crash is what blocks it). The genuine open question is
    Layer B's CHATEVAL bake-off — where `huge` Qwen3-8B loop-thrashes tools (2/5 vs `big`/e4b's 5/5) — not
    a quant swap.
    <!-- Signed: Kev + claude-opus-4-8, 2026-06-24, Confidence 0.9 (claims PR-traceable: #94/#98 merged,
         #100 open carrying the on-device verdict; OptiQ-has-no-Swift-loader and the 12B temporalOrder
         tool-use crash were both verified on-device across the 06-22→06-24 arc). Prior: Kev +
         claude-opus-4-6 (the STATUS 2026-06-22 note above). -->
  - **STATUS 2026-07-15 (additive — supersedes the 06-24 12B rejection):** **gemma-4-12B is `big` now.**
    Both 06-24 blockers cleared on the standing tag pin (3.31.4): the `vision_embedder` sanitize fix
    shipped in the tag, and the `RotatingKVCache.temporalOrder` tool-use crash **did not reproduce**
    (full tool arm on the rotating cache, exit 0 — what fixed it upstream is unattributed; re-verify on
    any dep bump). Promotion decided on a ten-run same-morning CHATEVAL (idle GPU; raw data
    `macos/scratch/eval-2026-07-15-model-runs/`): 12B vs e4b — live-path open-chat 8/8 vs 5/8 · code-gen
    5/5 vs 4/5 (e4b melted 17 min on one fixture) · reasoning 6/6 vs 3/6 · prompt-leak 7/7 vs 4/7 · the
    one cost ~2.6× slower tool turns (30.9s vs 11.9s median). Ships with a 16GB selection floor +
    restore-time easing (`BrainTier.selectableOrEased`). Note `huge` itself retired 2026-07-02 — the
    06-24 "huge stays Qwen3-8B" line is moot, the slot no longer exists; the 12B question was re-answered
    for BIG. Full matrix + decision record: `docs/MODEL_CHOICES.md` (2026-07-15 entry).
    <!-- Signed: Kev + claude-fable-5, 2026-07-15, Confidence 0.9 (both gates verified empirically
         same-day — tag-source check + crash-free full tool arm; eval is ten single runs, no variance
         bars; 12B RAM carried from the 06-24 memloop). Prior: Kev + claude-opus-4-8 (the 06-24 note). -->

---

## Update — 2026-06-06: Gemma 4 shipped (changes the north star from "someday" to "spike now")

**Gemma 4 12B released 2026-06-03** (post-cutoff; web-verified). It is encoder-free multimodal with **native audio** — built-in **speech recognition *and* speaker diarization** — Apache 2.0, on-device. The **edge variants E2B (2B eff.) / E4B (4B eff.)** carry native audio with an encoder **50% smaller than Gemma 3n** and a **40ms frame tuned for low-latency ASR**, sized for phone/laptop memory. Both runtimes M1K3 bet on now support it: **MLX-Swift** (`VincentGourbin/gemma-4-swift-mlx`) and **LiteRT-LM** (`litert-community/gemma-4-12B-it-litert-lm`, text+audio now).

**What this revises in this plan:**
- **"Gemma 4 doesn't exist / single model for ASR is not real yet" → false.** It exists and does ASR + diarization on-device. The inline claims below (and the Risks section) are corrected accordingly.
- **"Diarization stays a separate engine regardless" → no longer a given.** Gemma 4 diarizes natively. This could collapse the P7 calls stack (WhisperKit + FluidAudio + summary LLM) toward **one model** — *pending a benchmark of its diarization quality*.
- **The single-model goal is a P7 play, not P6 (corrected after the spike, 2026-06-06).** Reading the real `gemma-4-swift-mlx` source: Gemma 4 audio is **batch, file-based, ≤30s, via a low-level multimodal path — no streaming API**. So it is **NOT viable for P6 live dictation** (WhisperKit stays on the mic button); it fits **P7 batch call transcription**, where one Gemma 4 E4B could transcribe + (prompt-)diarize + summarise a ≤30s window, potentially shrinking the P7 stack. Diarization quality is the unverified deciding metric. See `scratch/gemma4-audio-spike/SPIKE.md`.

**What it does NOT change:** P6 ships **today on WhisperKit + Apple Speech** (committed) — reliable, proven streaming. Gemma 4 audio enters via the `TranscriptionProvider` seam as `GemmaAudioTranscriber` (`isAvailable=false` until it wins a benchmark). **Risk to respect:** days-old; community/v1 Swift audio runtimes; streaming-partial API unproven vs WhisperKit's mature one; unifying concentrates risk in one model. **So: spike + benchmark E4B (latency / accuracy / diarization) before swapping — target E4B, not 12B.** (Spike scaffolding: `scratch/gemma4-audio-spike/`.)

Naming note: the wired MLX *generation* model is `gemma-3-1b-qat-4bit` today; references to "Gemma 4" in the inference tier below are the **upgrade target**, now real.

---

## Update — 2026-06-10: Tool calling shipped (prompt-ReAct) → next: NATIVE tool calling per backend

**Shipped (`feat/agent-tool-calls`, 2026-06-09/10):** every chat turn now runs the `LocalAgent`
ReAct loop with real tools — `web_search` (DuckDuckGo, IA → lite fallback), `fetch_page`
(readable-text extraction), `datetime`, `system_status`, `search_knowledge` — behind a privacy
toggle (web tools not injected when off), with live activity labels, a deterministic
`Web sources:` block, unified-logging diagnostics, and a fallback that synthesises from
gathered observations when the model fumbles the conclusion format. Verified end-to-end
on-device (Boston weather → real forecast links + sources).

**The lesson from running it on two brains:** tool-calling reliability is **per-model dialect**.
AFM (Mini) follows the ReAct text protocol; Gemma-3n (Big) announces tools in prose
("I need to search the web") without emitting `ACTION:` — it was trained on its own native
tool-call format, not ours. Mitigations shipped (format reminder, scaffolding-strip,
repeat-guard, implicit-conclusion, observation-rescue fallback) make ReAct a *workable floor*
on any model — but the ceiling is teaching each runtime its own dialect.

**The native path is real on both wired runtimes (verified in source, 2026-06-10):**
- **MLX:** our pinned `mlx-swift-lm` (2.30.6) ships the *whole* native tool-calling stack, not
  just the input half. **Input:** `ChatSession(model, instructions:, tools: [ToolSpec])` injects
  JSON tool specs via the model's chat template. **Output (the surprise — already built, NOT ours):**
  `MLXLMCommon/Tool/` provides `ToolCallProcessor` (streaming detector), a `GemmaFunctionParser`
  for Gemma's `<start_function_call>call:name{…}<end_function_call>` dialect (+ json/lfm2/xml/glm4/
  kimiK2/minimaxM2 parsers), `ToolCallFormat.infer(from: modelType)` (auto-selects `gemma`), and a
  `Generation` enum whose streaming loop emits `.toolCall(ToolCall)` **inline** alongside `.chunk(text)`.
  So the "output half is ours to build, per model family" framing was wrong: at our current pin the
  library parses Gemma tool-calls into structured `ToolCall`s for us. **No version bump needed — the
  2.x/3.x WhisperKit/swift-transformers clash stays unarmed.** What's left is wiring, not parsing
  (see 12c, revised). *Source-verified probe, 2026-06-10 (continued session).*
- **AFM:** the macOS 26 FoundationModels framework has a native `Tool` protocol —
  `LanguageModelSession` can call Swift tools directly.

<!-- Signed: Kev + claude-opus-4-8, 2026-06-10, Confidence 0.9, Prior: Unknown.
     Source-probe correction: mlx-swift-lm 2.30.6 (git-tag-confirmed on disk) ships the full
     native tool-call OUTPUT stack (ToolCallProcessor + GemmaFunctionParser + Generation.toolCall),
     not just the ChatSession(tools:) input half. 12c is therefore wiring, not parser-building, and
     needs no version bump. Confidence 0.9: API surface read directly from the checkout; the one
     unverified link is whether Gemma-3n-E4B emits the call:name{…} format at runtime (that's 12d). -->


**Why it matters for the product:** M1K3 must work on **any device, agnostic of memory/compute**
— that's what the Mini/Lil/Big brain tiers are for. Tool calling has to scale the same way:
**native dialect where the runtime supports it, prompt-ReAct as the universal fallback** for
runtimes/models with no tool support (and as the proven baseline). One `AgentTool` definition,
three projections: FoundationModels `Tool` (AFM), `ToolSpec` chat-template JSON (MLX),
ReAct text list (floor).

**Design sketch (Phase 12):** a capability refinement on the inference seam —
`protocol ToolCallingProvider: InferenceProvider { func generate(prompt:, tools: [ToolDefinition])
async throws -> ToolTurn }` where `ToolTurn` is `.text(String)` or `.toolCalls([ParsedToolCall])`.
`LocalAgent` detects the capability: native loop (structured calls, no text parsing) when the
active provider conforms, today's ReAct loop otherwise. Same `AgentTool` execution, same
activity/logging/citation pipeline either way — the loop semantics (repeat-guard, iteration cap,
observation rescue) are dialect-independent and stay shared.

---

## Update — 2026-06-12: MCP polish shipped (5 test-report fixes) → async `ask_m1k3` is the next ceiling

**Shipped (TDD, 849 tests / 150 suites green, app builds):** the five findings from the
2026-06-11 live MCP test loop —
- **`ask_m1k3` deadline** (`AsyncTimeout.swift` — `withTimeout`): a runaway/slow generation no
  longer wedges the single-flight lock for minutes. Races the ask against a 120s deadline in a
  task group; on expiry it **cancels the generation** (propagates via the response stream's
  `onTermination` → `turnTask.cancel()` → `LocalAgent`'s per-iteration `checkCancellation`), the
  lock releases, and the caller gets an honest "took too long, try again."
- **`get_voice_status` exposes `answering`** — an in-flight ask is now visible (was reporting
  `in_conversation:false` mid-ask).
- **`get_document`**: explicit "indexed by title only" note for chunkless items (no more bare
  header); **6000-char window + `offset` paging** with a resume footer (was an unbounded firehose).
- **`ask_m1k3` Sources**: deduped + relevance-ranked in `HeadlessAsk` (presentation-only; the
  shared `GroundingGate` is untouched).

**Correction to the record:** the project-memory note "mcp swift-sdk Server processes requests
SERIALLY (0.12.1)" is **inaccurate**. `Server.swift:235` dispatches each request in its own task
("separate task to avoid blocking the receive loop") and `LocalMCPHTTPServer` is one task per
connection with actor reentrancy across the `handleRequest` await — so requests **interleave**.
The `answering` field is genuinely live-pollable mid-ask.

**Next (deferred — the async ceiling for long answers):** the deadline is a *backstop*; it cancels
**legitimately-long** answers at 120s. Two principled upgrades, in scope order:
1. **Async job model (fire-and-forget + poll)** — `ask_m1k3` spawns a detached `Task`, returns a
   ticket immediately (`{"ask_id", "status":"thinking"}`); a new `get_ask_result(id)` tool polls →
   `thinking` / grounded answer / `failed`. The single-flight lock lives on **the job**, not the
   HTTP request, so long answers **complete** instead of being cancelled and no connection is held
   for minutes. Same pattern `speak`'s fire-and-forget already uses. **Cost: two-call ergonomics**
   for the visiting agent — don't pay it pre-emptively; build only if 120s actually bites at ⌘R.
   Interim mitigation: bump the deadline to ~180s.
2. **Streaming transport + MCP progress notifications** — the *one-call-with-liveness* answer. The
   SDK already supports it (`ProgressNotification`, `progressToken` in `CallTool._meta`,
   `Tools.swift:366`), but pushing notifications needs an **open back-channel**; our
   `StatelessHTTPServerTransport` is `Connection: close`, one request per connection
   (`LocalMCPHTTPServer.swift:100`) — nothing to push down. Requires an SSE/streamable-HTTP
   transport. Largest scope; revisit if/when multi-client v2 lands (it needs the same plumbing).

**Empty-answer arc (live test, 2026-06-12):** the small brain (Lil/Qwen3.5-2B) returned
fast-but-empty (`emptyAnswer`) even on trivial asks. Traced to TWO compounding bugs:
- **SHIPPED — the floor:** `HeadlessAsk` no longer throws on an empty turn; it degrades to an honest
  message (`emptyAnswerMessage(didReason:)`) so a visiting agent never sees a bare "Error:
  emptyAnswer". The mechanism is `ReasoningSplit` correctly reducing a think-with-no-conclusion
  stream to "" — common on the 2B, rare on the 9B (same pipeline, weaker model).
- **DEFERRED — the root:** the empty-conclusion fallback (`AgentRAGResponder.streamFallback`) calls
  the **bare** `provider.generateStreaming`, which has no thinking parameter and so uses the
  provider's construction-time `thinkingEnabled: true` (`AppEnvironment.swift:276`) — re-opening
  Qwen's pre-opened `<think>` (`MLXGemmaProvider.swift:243`) **regardless of the turn's fast-mode**.
  So a fast turn's rescue path re-thinks (defeating fast-mode) AND a weak model thinking-without-
  answering manufactures the very empty the fallback exists to prevent. Fix: thread `thinkingEnabled`
  into the fallback generation (the bare `generateStreaming` seam can't carry it today — needs a
  thinking-aware streaming entry, or a no-think provider for the ask path). Touches shared streaming;
  verify-by-launch.

**Also carried from the test loop:** CitationValidator is ALL-CAPS-only (mixed-case titles pass
unvalidated — `HeadlessAskTests` comment); multi-client MCP (Stateful-per-session v2);
`GroundingGate.chunkThreshold` per-query normalisation (the off-topic-but-above-0.62 citation noise
this polish only *presentation*-fixed, not retrieval-fixed).

## Update — 2026-06-13: PR #20 MERGED to master + access-readiness pass (the repo goes invitation-only)

**The convergence the whole branch was building toward landed.** `feat/polish-setlist`
(55 commits, +76k/−15.7k, 235 files — the entire arc since the last master merge:
privacy/sandbox hardening, companions, in-app MCP, memory architecture, voice-first,
embeddings swap, persona) is **merged to master** (merge commit `fba01c5f`, 2026-06-13).
CI green; pr-reviewer verdict MERGE-READY, no blockers.

**Worked P0→P5 one by one (an "access-readiness" sprint — prepping the repo to be shared
invitation-only):**
- **P0 — privacy hygiene (`1a8318f8`):** the repo was tracking **private runtime data** — the
  personal `databases/m1k3_conversations.duckdb(.wal)`, `.m1k3_session.json`, and generated
  test reports (which embed absolute paths). Untracked all 14 (kept on disk) + sealed
  `.gitignore`. Anonymized `/Users/kevinmurphy` across 10 tracked docs → `$M1K3_ROOT`/`$HOME`
  via `scripts/sweep_hardcoded_paths.sh`; two FUNCTIONAL files got real (not placeholder) fixes:
  `.mcp.json` `PYTHONPATH` → `"."` (cwd is repo root — the absolute path was leaky AND unneeded),
  `tests/python/test_tts_content_parsing.py` derives root from `__file__`.
- **P1 — CI de-flake (`c301acc1`):** `AsyncTimeoutTests` "throws TimeoutError, fast" flaked
  (deadline 0.1s, op 10s, but a secondary wall-clock guard demanded `elapsed < 2s`; CI jitter hit
  2.81s — same branch alternated pass/fail). The `#expect(throws:)` already proves the deadline
  fired; the timing line only guards "didn't block 10s". Bound 2s → **5s** (half the op; ~50×
  deadline headroom). Green.
- **P2 — access/legal (`5d1b70df`):** committed the proprietary **LICENSE** + **ACCESS.md** +
  **ACCESS_AGREEMENT.md** (the README claimed "invitation-only" but the enforcing terms were
  untracked); reconciled stray `package.json` license fields (root ISC, unified-suite MIT →
  `"SEE LICENSE IN LICENSE"` + `private:true`).
- **P3 — launch artifacts (`73604bc7` + `fc283cfd`):** `marketing/` growth plan, `assets/`
  (app-icon + labyrinth icons), `make site`; Quaternius (CC0) credit for the Gecko/Inkfish/Colobus
  companions the site ships.
- **P4 — persona exemplar-bleed (`1a57eaa0`):** the 4B parroted the `voiceExemplars` verbatim,
  leaking the literal `USER:` label into greetings — because they were formatted as `USER:/M1K3:`
  chat turns (a pattern the weak model *continues*). Reframed as quoted illustrations
  (`- Asked X: <M1K3 line>`, no turn scaffolding) + a "never print a speaker label" guard; tests
  pinned in lockstep. Behavioural no-bleed is verify-by-feel at ⌘R.
- **P5 — merge** (above).

**Decisions / gotchas (do NOT rediscover):**
- **History scrub DEFERRED to a dedicated post-merge op (Kev's call).** The conversation DB is gone
  from HEAD but still in **git history** — and it was introduced way back in **master's** history
  (`075ce65b`), so a complete scrub is a full-repo `git filter-repo` rewrite of master + ~9 local /
  ~15 remote branches (incl. the unpushed `fix/gemma-embeddings`), then force-push. Doing it mid-sprint
  would orphan in-flight work; the plan is to scrub AFTER #20 is merged (✅) AND `fix/gemma-embeddings`
  lands, then re-clone. **This is the one real privacy item still owed before any invite.**
- **`sweep_hardcoded_paths.sh` used bash-4 `mapfile`** → "command not found" on stock macOS (bash 3.2).
  Rewrote to a `while-read` loop. (Pattern: any committed `.sh` must run on /bin/bash 3.2.)
- **The `.gitignore` global `*.png` trap struck again** — `git add assets/` would have silently dropped
  all 19 icon PNGs. Added `!assets/**/*.png`. (Same family as the `site/**` and `.claude/skills`
  re-include traps; always `git diff --cached --name-only | grep png` after staging image assets.)
- **Merging to master is permission-gated** — the harness blocks `gh pr merge` to the default branch
  without explicit user authorization (correct guardrail; do not work around it with a raw `git push`).

**Carry-forward (P4 tail — still owed, blocked on hardware / Xcode-closed / data tasks):**
- threshold re-tune (`GroundingGate.chunkThreshold`/`memoryThreshold` are bge-era provisionals — owed an
  ABSEP/MEMEVAL re-measure on the new Qwen3 embedder) · file-length extractions
  (`KnowledgeStore+Search.swift` at 511 lines, AppEnvironment, AvatarView — need Xcode-closed xcodegen) ·
  `MLXGemmaProvider→MLXBrainProvider` rename (misnomer; loads Qwen too) · notifications quick-win ·
  CMUdict dict swap (proper TTS fix) · Phase 3 memory (consolidation/recency/contradiction) ·
  malformed citation leak on Lil-4B (`§3 * 10 = 30`) · Mini agent-loop timeout profiling · idle-fan/GPU.
- **Launch infra (Kev's):** point `m1k3.app` at a host, deploy `site/`, 301 the alts; signed `.dmg`
  (blocks Homebrew cask); MCP registry submissions; demo video.

<!-- Signed: Kev + claude-opus-4-8, 2026-06-13, Confidence 0.9 — P0–P5 access-readiness sprint;
     PR #20 merged to master (fba01c5f), CI green, pr-reviewer MERGE-READY; all 7 session commits
     pushed + on master. History scrub correctly deferred (full-repo rewrite, would orphan in-flight
     work). Persona no-bleed is verify-by-feel at ⌘R. Prior: Kev + claude-fable-5 (this file). -->

## Update — 2026-06-14: WWDC26 `LanguageModel` adoption SHIPPED → forward plan (evals enclave · network rungs · FM-on-device)

**Shipped (`feat/wwdc26-languagemodel-bridge`, PR #28, 9 commits, 1101 tests green, app builds):**
the M1K3-side adoption of Apple's WWDC26 `LanguageModel` protocol as a **conformance bridge, not a
rebuild** (see **`docs/adr/0001`**). M1K3 had independently built the same shapes a year early; the
work makes that interop real without losing the tuned MLX path or the `ThinkStreamGate`.
- **`M1K3LanguageModel`** (pure): mirror of Apple's surface + `EscalationLadder` (consent-gated
  routing) + `BrainCatalogue`.
- **`M1K3ModelExecutor`** / **`M1K3Model`** (M1K3Agent): the real-provider executor over
  `ToolTurnSession` + the live gate (reasoning→`.reasoning`, answer→`.response`), lazily-cached
  session (multi-turn KV reuse), and the `LanguageModelDescribing` conformance.
- **`M1K3FoundationModel`** (FM27-gated): the production conformance to Apple's REAL protocol —
  **type-checked + compiled against the macOS 27 SDK** (Xcode 27 beta), **inert on stable 26.5**.
- **Live auto-routing** (Path 1): opt-in `brain.autoRoute` Settings toggle → `M1K3BrainRouter` picks
  the brain per turn. **Policy fix from on-device testing:** the DEFAULT local brain is now M1K3's
  own tuned MLX (stronger at open chat than AFM); Apple-on-device is opt-in (`preferAppleOnDevice`).

**The honest open edges (none block launch — Tahoe ships on what's above):**

### Edge A — Network rungs reachable (PCC · Claude/Gemini) — *biggest spread in cost*
Today `BrainRoute.privateCloud/.thirdParty` resolve to the floor (no backends/escalation UI; the
ladder gates them correctly). Three separable pieces:
- **PCC — small, real:** `PrivateCloudComputeLanguageModel` **already conforms** in the macOS 27 SDK.
  Not "build a backend" — wire the existing Apple rung + consent UX; gated on the Xcode-27 build
  (Edge B). Fits the ethos (Apple-attested, stateless).
- **Claude/Gemini — large, product-decision-first:** M1K3 has **zero cloud provider**. Each needs an
  API-client `ToolCallingProvider`, Keychain key management, streaming + tool-call translation, and a
  **dedicated egress-consent flow** (chat→third-party-cloud is a far bigger privacy step than a web
  search; it must NOT reuse the web-search toggle). This is the "Share-to-Claude escalation" seed —
  the deliberate, consented escape hatch from "nothing leaves." Decide *whether/how loud* before eng.
- **Escalation UI (both):** a per-message "go deeper / ask X" control that sets `userEscalation`
  (today always `.none`). Small–medium.

### Edge B — Exercise the 2026 conformance on-device — *gated on a macOS 27 RUNTIME, not just the SDK*
The conformance is `@available(macOS 27)`: compiling under Xcode 27 ≠ running it. On Tahoe (26.4) the
FM path is unavailable at runtime. Steps: (1) compile the **whole app** under Xcode 27 + `-DM1K3_FM27`
(risk = heavy deps/MLX under Swift 6.3 — the downloaded **Metal Toolchain** is for this; `M1K3Agent`
already builds under the beta); (2) wire a FoundationModels response path
(`LanguageModelSession(model: M1K3FoundationModel(...))`) alongside the existing one; (3) **run it —
needs macOS 27 on a separate volume / VM / second Mac, never the launch box.** Not launch-critical;
goes live when macOS 27 does (~autumn). An Xcode-27-built app still runs on Tahoe with the FM path
gated off.

### Edge C — Model evals in a Swift enclave (Phase 14) — *highest leverage, no beta/OS/cloud, START HERE*
Turns the routing policy from *by-feel* into *data-driven*, and directly answers the quality gap Kev
hit by hand ("AFM weaker at open chat" → the floor-default we just shipped, **proven with numbers**).

**Hard constraint (do not design around it):** MLX brains need the **app-bundle metallib to init the
GPU**, and AFM needs app entitlements — so a *bare* `swift run`/`swift test` CANNOT run the real
models (the same wall 12c/MEMEVAL/ABSEP hit). The model-running half MUST ride the existing
**headless-selftest** mechanism (signed Debug build + `open -n --env … "$APP"` → OUT file), exactly
like `M1K3_SELFTEST_MEMEVAL`/`ABSEP`. The "enclave" is a **SelfTest stage + a pure scoring package**,
not a standalone CLI.

**Shape (TDD; reuse the MEMEVAL/ABSEP pattern):**
- **`M1K3Eval` package (pure, plain `swift test`):** `EvalFixture` (prompt + task-kind +
  expectations), the fixture set, `EvalScorer` (heuristics: refusal, format/`<think>`-leak, length
  band, latency, citation-validity), `EvalReport` (a markdown table). All deterministic + unit-tested
  off-device.
- **`M1K3_SELFTEST_CHATEVAL=1` SelfTest stage:** runs each fixture × each brain (via the real
  `ToolTurnSession` / `BrainRoute`), captures output + latency, feeds the pure `EvalScorer`, writes
  the report to `M1K3_SELFTEST_OUT`. Same headless harness as the threshold runs (set
  `M1K3_SELFTEST_MODEL` per brain so the gen stage uses a cached model).
- **Fixture kinds:** open-chat · grounded-Q (with a seeded doc) · multi-step reasoning · tool-use
  (does it call `search_knowledge`?) · refusal/safety. ~5–8 per kind to start.

**Phasing (cheap → rich):**
1. **P1 — side-by-side + latency (human eyeball, ~one sitting):** run the fixtures × brains, dump
   outputs next to each other + tokens/latency. Immediately gives the AFM-vs-Lil numbers. *Verify:*
   a report you can read at a glance that confirms (or refutes) "floor beats AFM at chat."
2. **P2 — heuristic auto-scores:** the `EvalScorer` metrics above → a pass/score column per fixture.
   *Verify:* the policy default is justified by an aggregate score, not a feel.
3. **P3 — LLM-as-judge (optional):** a strong brain (or AFM under a neutral judge prompt, NOT the
   persona) scores open-chat quality pairwise. *Verify:* judge agreement with hand ranking on a
   held-out set before trusting it.

**Composes with the ladder:** eval results feed back as the *evidence* for `EscalationLadder` policy
(default brain, per-task routing later — e.g. route grounded-Q to a fast brain, open-chat to the
strong one). The `BrainRoute`/`M1K3Model` seams are the clean injection point; no new model wiring.

### Edge D — AFM-native tool-calling spike (Phase 15) — *NEXT SESSION, off the evals findings*
The evals enclave (Phase 14) shipped and immediately earned its keep: it proved the **mini** brain
(Apple Foundation Models) calls tools **0/5** through M1K3's production path (the prompt-ReAct floor in
`LocalAgent`) but **5/5** when handed Apple's **native** `FoundationModels.Tool`s via
`LanguageModelSession(tools:)`. So AFM *can* tool-call — the ReAct floor is just the wrong harness for
it. (Caveat the latency-band check then caught: a native "pass" took **337s** on an open-ended query —
AFM auto-loops to context-overflow when a tool's output doesn't resolve the query. Selection ≠
task-completion.)

**Why it's worth a spike (not tier-polish):** this is the **Apple-native tool-calling layer**, and the
whole Apple-model trajectory rides it — WWDC26's rebuilt AFM (native tools + vision), PCC, and the
macOS-27 `LanguageModel` bridge already shipped (Phase 13) are the *same bet*. Strategically coherent
with the offline/Apple-aligned ethos; "time before launch" removes the pressure. (Challenger's
double-bind — "don't polish the weak tier" — dissolves once it's framed as infra, not mini-polish.)

**The approach — challenger's THIRD PATH, not an Apple-driven loop:** conform
`AppleFoundationModelsProvider` to `ToolCallingProvider` via **`@Generable` structured output** — the
model emits a structured `{tool, query}` / `{final_answer}`, `continueToolTurn` returns `.toolCalls`,
and **`LocalAgent` keeps the loop** (iteration cap, repeat-guard, citation validation, reasoning
stream — all the machinery already trusted; same dialect-adapter pattern as `MLXToolCalling.swift`). A
parse-failure falls through to `.text` + the existing fallback, *not* a 7-minute overflow. Strictly
less code than letting Apple drive (no re-plumbing grounding/citations — they live in
`AgentRAGResponder` pre-agent + `ChatSession` post-stream, NOT in LocalAgent, so they survive). Only if
AFM provably *won't* emit parseable structured calls via prompting does the Apple-driven loop earn its
seat — test the cheap path first.

**Success criterion = the one unknown, tested on the HARD case:** does AFM reliably emit a parseable
structured tool-request, *and survive non-resolving / empty / multi-step tool results* (the case the
eval's terminal stubs dodged)? Spike with `web_search` returning links-needing-follow-up and
`lookup_fact` returning empty. If it melts there, that's the real constraint — found cheaply.

**Shape (TDD where pure, verify-by-launch where it needs AFM):** (1) pure `@Generable` tool-request
type + a `structured-output → ToolTurn` parser (TDD, off-device — the cheap part that de-risks the
unknown); (2) the `ToolCallingProvider` conformance behind a flag (default OFF — launch routing
unchanged); (3) live validation via the `M1K3_SELFTEST_CHATEVAL` harness with non-terminal stubs +
the latency band. **Launch routing stays agentic → lil+ regardless** — the spike informs post-launch /
WWDC26, and the evals harness is the durable asset that **re-weighs every future Apple model as it
ships** (no rebuild — just re-run). New branch: `feat/afm-native-tools-spike`.

### Edge E — On-device fine-tuning (LoRA): lil now, AFM adapters later (Phase 16) — *unlocked by the evals harness*

Background — why voice goes in the weights but memory never does: [`docs/lora-vs-qlora-and-memory.md`](docs/lora-vs-qlora-and-memory.md).

The evals enclave (Phase 14) turns fine-tuning from vibes into a measurable loop: train an
adapter, run `CHATEVAL`, read the **before/after delta** in the matrix. That is the unlock — a LoRA
without a way to score it is just fiddling. M1K3's own AI principle is evaluation-driven development;
this is it, applied to weights.

**Two targets, NOT the same project:**

- **① lil-4B via MLX (`mlx_lm.lora`) — START HERE (the muscle run).** `mlx-community/Qwen3.5-4B-4bit`,
  QLoRA on this M1 Max (64GB — trivial overnight). Fully observable, every knob ours, can't brick on
  an OS update. lil already tool-calls 5/5, so the win is NOT tool-selection — it is **internalising
  the M1K3 persona/voice into the weights** so the voice exemplars can be **dropped from every
  prompt**. `M1K3Persona` literally flags the cost: *"the persona is prefilled on every turn, so every
  sentence is a TTFT tax… voice lands in the exemplars."* Bake the Cork-villain voice into lil ⇒ (a)
  **lower TTFT** (shorter system turn on every single turn), (b) **more consistent voice**, (c) kills
  the documented **exemplar-bleed** bug (the 4B parroting `USER:/M1K3:`). Measurable: CHATEVAL
  open-chat persona checks + no-think-leak + a no-bleed check, **A/B'd with exemplars REMOVED from the
  prompt** (the whole point). Deploy path: `mlx_lm.lora` → `mlx_lm.fuse` → quantise → point lil's
  brain at the fused model id (mlx-swift-lm loads it as any model; adapter-load is the alt if supported).

- **② AFM adapter via Apple's Foundation Models adapter toolkit — LATER (the strategic bet).** Apple
  ships a Python toolkit to train **rank-32 LoRA adapters** for the on-device base, exported as an
  `.fmadapter`, deployed via `SystemLanguageModel(adapter:)`. This is the one path that could directly
  fix the **Phase-15 finding** (mini's weak structured-output tool-*selection* — a behavioural prior, the
  exact thing a LoRA moves). Strategically the Apple-aligned bet the whole trajectory rides (WWDC26 AFM
  + PCC). **But brittle:** adapters are **version-locked to a specific AFM build** — an OS update can
  invalidate one (retrain), the toolkit is heavier, and it is novel ground. **Do ① first to learn the
  loop on hardware we own; earn the right to ② where the payoff lives but the ground is treacherous.**

**The real work is DATA, not GPU hours** (training is an hour or two; the craft is the dataset). Two
non-negotiables, both eval-discipline: (1) **hold the CHATEVAL fixtures OUT of training** — train on
your test set and the delta is a lie (leakage); (2) guard **catastrophic forgetting** — a small-model
LoRA can sharpen one behaviour and lobotomise general chat, so keep a held-out "did it stay smart?"
check. The rule is the same as TDD: the eval you train against stops being an eval. Scaffold +
leakage-safe data strategy + the `mlx_lm.lora` config + the base-vs-adapter A/B live in
`scratch/lora-spike/`.

**New phases:** *13 — LanguageModel bridge (✅ shipped).* *14 — Evals enclave (Edge C, ✅ shipped —
`M1K3Eval` package + `M1K3_SELFTEST_CHATEVAL` stage; file-config harness; latency band).* *15 — AFM
tool-calling spike (Edge D, ✅ spiked on `feat/afm-native-tools-spike` / PR #30 — structured path is
safe + parseable but selection-weak; agentic stays lil+).* *16 — On-device LoRA (Edge E, NEXT —
`feat/lil-lora-spike`: lil persona-internalisation first, AFM adapters later).* Edges A/B tracked, not
yet phased (product decision / macOS-27 runtime).

**Phase 15 verdict (2026-06-15, `feat/afm-native-tools-spike`):** The third path WORKS and is SAFE
but is NOT competitive enough to route agentic work to AFM. The structured `@Generable` path
(`AppleFoundationModelsProvider: ToolCallingProvider`, one decision per turn under LocalAgent's cap):
**✅ emits parseable structured calls; ✅ never melts** (worst on-device case 93s = cap×~30s on a
non-resolving stub, vs the Apple-driven loop's 337s overflow — our owning the loop is the structural
fix, proven twice); **⚠️ but selection is weak & steering-resistant** (spike 1–2/5 vs Apple-driven
5/5 on the same tools — the gap is structured-output framing vs native-Tool framing, not the
descriptions) **and slow per-call** (~20–30s vs MLX ~6s). The tension: structured-output buys loop
control at the cost of selection; native-Tool framing buys selection at the cost of loop control — an
agent needs both. **Decision: launch routing stays agentic → lil+ (4B); mini stays the fast
chat/lookup floor.** Conformance ships behind a default-OFF flag (routing unchanged); the evals
harness now measures all three AFM paths behind env flags, so WWDC26's rebuilt AFM re-weighs by
re-running — no rebuild. Full findings: `scratch/afm-native-spike-2026-06-15/FINDINGS.md`.

<!-- Signed: Kev + claude-opus-4-8, 2026-06-14, Confidence 0.9 — WWDC26 LanguageModel adoption shipped
     (PR #28, ADR 0001, 1101 green, production conformance compiles vs the real macOS 27 SDK). Forward
     plan: evals enclave (Phase 14) is the START-HERE — cheapest, no beta, makes routing data-driven;
     the headless-selftest constraint (MLX needs the app bundle) is the load-bearing design fact. PCC
     is a real SDK rung; Claude/Gemini is a product decision before eng; FM-on-device needs a macOS-27
     runtime. Prior: Kev + claude-opus-4-8 (this file). -->

## Architecture

A new SwiftUI app `M1K3.app` (macOS 26), composed of focused local SwiftPM packages. Business logic lives in testable packages (TDD); the app target is a thin shell. Proven files are **vendored** from the prior internal projects into M1K3 packages (not cross-repo path deps — the prior server's core drags in Hummingbird and other server scaffolding we don't need), each carrying a MurphySig review documenting the port.

```
m1k3/macos/                         ← NEW (sibling to app/iosApp)
├── M1K3.xcodeproj                  ← app shell, macOS 26, SwiftUI Liquid Glass
├── Packages/
│   ├── M1K3Inference/              ← provider protocol + 3 backends
│   ├── M1K3Knowledge/              ← embeddings + semantic store + graph + docs
│   ├── M1K3Voice/                  ← transcription protocol + TTS protocol
│   ├── M1K3Calls/                  ← call session model, log, diarization, summary (← prior call pipeline)
│   ├── M1K3Agent/                  ← ReAct loop + tools
│   ├── M1K3MCP/                    ← MCP server exposing the knowledge graph
│   └── M1K3Avatar/                 ← RealityKit emotion-driven avatar
└── M1K3App/                        ← SwiftUI views, chat UI, glass styling
```

### The pluggable inference layer (the crux)

Unify on **the prior call-pipeline's `InferenceProvider`** (cleaner than the prior knowledge-server's `InferenceService` for swap/benchmark):

```swift
public protocol InferenceProvider: Sendable {
    var name: String { get }
    var isAvailable: Bool { get }
    func generate(prompt: String) async throws -> String
    func generateStreaming(prompt: String) -> AsyncStream<String>
}
```

Backends (all conform; router picks by task + availability):
- **`AppleFoundationModelsProvider`** — lift from the prior call-pipeline's `AppleFoundationModelsProvider` (private sources). Cheap/basic turns, `LanguageModelSession` streaming. macOS 26 native.
- **`MLXGemmaProvider`** — Gemma 4 generation via `MLXLLM`/`MLXLMCommon` from `mlx-swift-lm` (same package family the prior knowledge-server uses for `MLXEmbedders`). Truly in-process, Metal.
- **`LiteRTGemmaProvider`** — Gemma 4 via LiteRT-LM. **Greenfield, highest risk** (no Swift IP, C++ engine). MVP approach: spike in `m1k3/macos/scratch/litert/` first (C-bridge or local sidecar), promote to a real provider only once it generates. Until then it reports `isAvailable = false` and the router skips it — nothing else blocks on it.
- A `RuntimeBenchmark` harness drives the same prompt set through MLX vs LiteRT vs AFM to capture the comparison Kev wants (tokens/sec, latency, quality).

### Knowledge core (lift from the prior knowledge-server, near-verbatim)

- **Embeddings:** `MLXEmbeddingService.swift` (+ `EmbeddingService`, `EmbeddingWorker`) — `MLXEmbedders`, Metal GPU, `nomic-embed-text-v1.5` (bge_small fallback). API: `embed/embedBatch/isAvailable`.
- **Semantic store / KG:** `SemanticStore.swift`, `SemanticStore+Documents.swift`, `SemanticModels.swift`, `SemanticMigrator.swift`, `VectorMath.swift`, `RRFFusion.swift` — GRDB SQLite, FTS5 + vector cosine, Reciprocal Rank Fusion hybrid search. `KnowledgeGraphBuilder.swift` → nodes/edges.
- **Documents:** `DocumentChunker.swift` (heading-aware), `PDFTextExtractor.swift` (PDFKit), `DocumentStore.swift` (SHA256 dedupe), `CitationValidator.swift` (strips hallucinated cites).
- **RAG prompt:** `ChatPromptBuilder.swift` + `ChatRAGRetriever.swift` — documents-first prompt structuring, provider-agnostic, feeds whichever `InferenceProvider` is active.

### Voice — transcription behind a provider protocol

Reuse **the prior call-pipeline's `TranscriptionProvider` + `TranscriptionRouter`** (internal call-pipeline sources, private) rather than the prior knowledge-server's single engine — the call-pipeline's is already pluggable and gives us the swap/compare seam Kev wants:

- **`WhisperKitProvider`** (default, reliable) — live streaming, isolated in `M1K3WhisperKit`. Plus `AppleSpeechTranscriber` (on-device `SFSpeechRecognizer`, the day-one path) in `M1K3Voice`; `TranscriptionRouter` selects. **✅ Shipped 2026-06-06 (Phase 6).**
- **`GemmaAudioTranscriber`** (spike → the single-model north star) — **Gemma 4 E4B** native audio via **MLX-Swift** (`gemma-4-swift-mlx`) or **LiteRT-LM**. Same `TranscriptionProvider` seam, so it drops in once it beats WhisperKit on a benchmark. Scaffolded in `scratch/gemma4-audio-spike/`, `isAvailable=false` until proven — nothing blocks on it.
- **TTS:** new `SpeechProvider` protocol → `AVSpeechProvider` (wrap the prior knowledge-server's `SpeechSynthesizer.swift`) for MVP; `KokoroSpeechProvider` (bridge to m1k3 Python TTS) post-MVP. Avatar lip-sync off TTS amplitude/word callbacks.

### Call transcription & log (lift the prior call-pipeline's call subsystem whole)

M1K3 records and logs calls with searchable, summarised history — the prior call pipeline already *is* this system. Lift near-verbatim into `M1K3Calls`:

- **Data model:** `CallSession`, `TranscriptSegment`, `QuickSummary`/`CallSummary`, `KeyMoment`, `ReasoningStep`, `SpeakerSegment`/`SpeakerProfile` (internal call-pipeline model/protocol sources, private).
- **Persistence:** `SQLiteCallPersistence` + `EncryptedCallPersistence` (AES-256-GCM, Keychain key) — privacy-by-default, matches the M1K3 ethos.
- **Diarization (who-said-what):** `DiarizationRouter` → `FluidDiarizationProvider` (CoreML/ANE) + stereo fallback + `DiarizationAligner`. *Revised 2026-06-06: Gemma 4 diarizes natively, so the dedicated engine is no longer a given — if the E4B spike's diarization quality holds, this whole sub-stack could fold into the one model. Lift the prior call-pipeline's diarization for the MVP, but benchmark Gemma 4 before committing to maintain it.*
- **Summarisation:** `SummarizationPipeline` two-stage — Tier 1 quick summary via **Apple Foundation Models** (<1s), Tier 2 deep analysis (action items, risk flags) via **Gemma 4** through our `InferenceProvider`. This is the "single model for complex work" payoff: Gemma 4 does the reasoning/summary; AFM does the cheap first pass.
- **UI:** `SessionHistoryView`, `SessionDetailView`, `TranscriptView` (speaker-grouped ticker), `SummaryView`, `AgentReasoningView` — reskinned in Liquid Glass.
- **Knowledge integration (the M1K3 twist):** each finished call becomes a node in the **knowledge graph** and its transcript flows into the **semantic store** as documents/observations — so calls are searchable via RAG, the local agent's tools, and the MCP server. This is what makes it M1K3 and not just the prior call pipeline on Mac.

### Local agent + tools

Generalise the prior call-pipeline's domain ReAct agent loop into `LocalAgent` (Thought→Action→Observation, `maxIterations` default 5). Reuse the `AgentTool` protocol verbatim:

```swift
public protocol AgentTool: Sendable {
    var name: String { get }
    var description: String { get }
    var parameters: [ToolParameter] { get }
    func execute(input: [String: String]) async throws -> ToolResult
}
```

MVP tools: `SearchKnowledgeTool`, `QueryGraphTool`, `GetDocumentTool`, `ListDocumentsTool` (all thin wrappers over `M1K3Knowledge`).

*Update 2026-06-10:* shipped and wired into EVERY chat turn via `AgentRAGResponder`
(retrieve-first grounding preserved, fallback to plain RAG). Tool set grew a self-contained
`M1K3AgentTools` target: `WebSearchTool` (DDG), `FetchPageTool`, `DateTimeTool`,
`SystemStatusTool` — web tools behind a Settings privacy toggle. Tool-call *dialect* is
prompt-ReAct today; native per-backend dialects are Phase 12 (see the 2026-06-10 update).

### MCP server (so Claude can pull from M1K3)

New `M1K3MCP` package using the official **`modelcontextprotocol/swift-sdk`**, stdio transport. Exposes the same knowledge-tools as MCP tools/resources: `search_knowledge`, `query_graph`, `get_document`, `list_documents`. Registers into Claude Desktop/Code via config. (The prior knowledge-server's existing `/v1/graph`, `/v1/documents`, `/v1/search` HTTP routes are the behavioural reference for what each tool returns.)

### Avatar

`M1K3Avatar` — RealityKit `RealityView` hosting one USDZ avatar (convert a model from the THREE.js `web-avatar` set to USDZ). Driven by an `EmotionState` enum (port the `ToolEmotionMap` concept), with idle/breathing/blink + amplitude-driven mouth movement from the TTS stream. SceneKit fallback if RealityKit blendshape control is fiddly.

### UI / Liquid Glass

SwiftUI, macOS 26, native `.glassEffect` / `GlassEffectContainer` for the real Liquid Glass look (replaces the Android `GlassmorphicModifier` — same design language, native API). Chat view: streaming message bubbles, a transcript ticker during voice input, the avatar as a persistent companion pane, a document drawer, and a settings pane to pick the active inference runtime (AFM / MLX / LiteRT) for live comparison.

---

## Build phases (each TDD: red → green → refactor; sign significant decisions with MurphySig)

0. **Scaffold** — Xcode project (macOS 26), empty packages, CI build green. Add deps: `mlx-swift-lm`, `GRDB.swift`, `WhisperKit`, `swift-sdk`.
1. **Knowledge core** — vendor + test embeddings, semantic store, hybrid search, KG builder. *Verify:* ingest text → embed → hybrid-search returns it.
2. **Inference layer** — `InferenceProvider` + `AppleFoundationModelsProvider` + `MLXGemmaProvider` + router. *Verify:* same prompt streams from both; router falls back.
3. **LiteRT spike** — prove Gemma 4 generation via LiteRT-LM in `scratch/`; promote to `LiteRTGemmaProvider` if viable; run `RuntimeBenchmark`. *Verify:* benchmark table MLX vs LiteRT vs AFM.
4. **Documents** — PDF/text import, chunk, embed, store; citation validation. *Verify:* drop a PDF → ask about it → grounded answer with valid citations.
5. **Chat UI + Liquid Glass** — streaming chat, runtime picker, glass styling. *Verify:* end-to-end RAG chat in the app.
6. **Transcription layer** — ✅ **shipped 2026-06-06.** `TranscriptionProvider` + `TranscriptionRouter` + `AppleSpeechTranscriber` (M1K3Voice) + `WhisperKitProvider` (M1K3WhisperKit) + mic toggle/ticker, auto-send on stop. *Verify (by launch):* speak → ticker → auto-sends → answer.
7. **Call log** — lift `M1K3Calls` (session model, encrypted SQLite, diarization, two-stage summary, history UI); wire calls → knowledge graph. *Verify:* record a 2-party call → live diarized transcript → AFM quick + Gemma deep summary → logged, searchable, and answerable via RAG.
8. **TTS** — `AVSpeechProvider` behind protocol; spoken responses. *Verify:* answer is spoken.
9. **Avatar** — RealityKit avatar, emotion states, amplitude lip-sync. *Verify:* avatar emotes + mouths the TTS.
10. **Agent + MCP** — `LocalAgent` ReAct loop with tools (incl. calls/knowledge); `M1K3MCP` stdio server. *Verify:* agent answers a multi-step question using tools; Claude Code connects to the MCP server and pulls knowledge + call data.
11. **GemmaAudio spike** (parallel, non-blocking; **investigated 2026-06-06** — see `scratch/gemma4-audio-spike/SPIKE.md`). Finding: Gemma 4 audio is **batch ≤30s, no streaming** → a **P7** tool, **not** the P6 mic button. Next: benchmark **Gemma 4 E4B batch** transcription + prompt-diarization vs WhisperKit+FluidAudio on a ≤30s clip; if WER + diarization DER hold, re-plan **Phase 7** around one model (challenger pass first). Prototype in an ISOLATED package (version-conflict risk with our pinned mlx-swift-lm). *Verify:* batch benchmark table — WER, diarization DER, transcribe+summarise-in-one-pass.
12. **Native tool calling per backend** (the multi-model play — see the 2026-06-10 update). One `AgentTool` definition, projected into each runtime's native dialect; prompt-ReAct stays as the universal floor so M1K3 keeps working on any model on any device.
    - **12a — seam:** ✅ **shipped 2026-06-10.** `ToolCallingProvider: InferenceProvider` with `supportsToolCalls` (RUNTIME capability, not just type) + `continueToolTurn(messages: [ToolMessage], tools: [ToolDefinition]) → ToolTurn`. Types: `ToolDefinition`/`ToolParameterDefinition`, `ParsedToolCall` (args `[String: JSONValue]`, typed wire), `ToolTurn` (.text/.toolCalls), `ToolMessage` (.user/.assistant/.toolResult). `LocalAgent.run()` dispatches native-vs-ReAct; the two loops live in `LocalAgent+Native.swift` / `LocalAgent+ReAct.swift` and SHARE the dispatch core (repeat-guard, unknown-tool steering, cap, trace, events) in `LocalAgent.swift`. 13 new tests (no model — fakes). **Challenger-driven design changes from the original sketch:** (1) a typed `[ToolMessage]` transcript, NOT a `prompt: String` — feeding native tool-results back as prose is off-distribution and would churn the seam in 12c (the array maps straight onto mlx's `UserInput(chat:)`); (2) typed `JSONValue` args, flattened to String only at the `AgentTool.execute` edge; (3) `supportsToolCalls` runtime flag defuses the `infer != "gemma"` silent-`.json` trap — a wrapper whose model can't parse reports false → ReAct floor. ReAct path byte-identical (all prior tests green).
    - **12b — AFM adapter:** FoundationModels `Tool` protocol bridge for Mini (likely the cleanest: the framework executes Swift tools natively).
    - **12c — MLX adapter (revised 2026-06-10 after source probe — much smaller than planned):** the
      version question is ANSWERED — our pin **2.30.6 already ships the Gemma output parser** (`ToolCallProcessor`
      + `GemmaFunctionParser`, emitting `.toolCall(ToolCall)` inline from the `Generation` stream). **No bump,
      no WhisperKit clash.** So 12c is no longer "build + test a parser"; it's wiring: (1) map our `AgentTool`
      → mlx `ToolSpec` (the `Tool<Input,Output>` init builds the JSON-schema); (2) point `MLXGemmaProvider` at
      the generation path that yields the `Generation` enum (not the text-collapsing `ChatSession.respond`) so
      we *see* `.toolCall`; (3) set/infer `toolCallFormat = .gemma`; (4) surface `.toolCall` as our `ToolTurn.toolCalls`
      back into the shared `LocalAgent` loop. The parser is the library's; the tests we owe are on the *mapping*.
      **Gotcha (spike-caught):** `ToolCallFormat.infer` matches `model_type == "gemma"` *exactly* — Gemma-3/3n
      fall through to `.json` and silently never parse. Step (3) must set `toolCallFormat = .gemma` **explicitly**,
      not rely on infer. Compile-proven against the pin in `scratch/mlx-toolcall/` (the whole API surface builds);
      the runtime `.toolCall`-fires check is verify-by-launch in the app (MLX needs the app-bundle metallib — a bare
      `swift run`/`swift test` can't init the GPU), which also makes it the natural home for the 12d emission check.
      ✅ **shipped 2026-06-10.** `MLXToolCalling.swift`: pure `MLXToolMapping` (ToolDefinition→ToolSpec, ToolMessage→
      Chat.Message incl. native call-echo, library `ToolCall`→`ParsedToolCall`, `MLXLMCommon.JSONValue`→ours) + the
      `MLXGemmaProvider: ToolCallingProvider` conformance (`continueToolTurn` drives `ModelContainer.generate` →
      `Generation` stream, collecting `.chunk`/`.toolCall`). **Multi-model from day one (Kev's "all brain types"):**
      `resolveToolCallFormat` keys the dialect off the model FAMILY — Gemma→`.gemma`, Qwen/Llama→`.json` — and
      `supportsToolCalls` is true only for recognised families (unknown → ReAct floor). Capability forwarded through
      `SwappableInferenceProvider` + `RuntimeInferenceProvider` so the native loop actually fires in-app for the
      selected MLX brain. 15 new tests on the pure mappers + façade forwarding; `continueToolTurn` (real model) stays
      verify-by-launch. The 12d emission check (does Gemma-3n/Qwen actually emit the format on-device) rides ⌘R.
    - **12d — benchmark:** same tool-task set through native vs ReAct per brain tier (call-format compliance rate, latency, wasted iterations) — promote native per-backend only where it wins, exactly like the transcription seam.
    - *Verify:* Big (Gemma) calls `web_search` natively on the weather question with zero format coaching; Mini does the same via FoundationModels tools; a no-tool-support model still answers via ReAct.
13. **WWDC26 `LanguageModel` bridge** — ✅ **shipped 2026-06-14** (PR #28, ADR 0001; see the 2026-06-14 update). Mirror surface + `EscalationLadder` + `BrainCatalogue` (pure); `M1K3ModelExecutor`/`M1K3Model` (real-provider executor over `ToolTurnSession` + the live gate, KV-reuse cache); `M1K3FoundationModel` (FM27-gated production conformance, compiles vs the real macOS 27 SDK); live opt-in auto-routing with the floor-default policy. *Verify (shipped):* 1101 green; conformance compiles under Xcode 27; auto-route picks the floor by default, Apple-on-device when opted in (`log stream … category == "route"`).
14. **Evals enclave** (Edge C) — ✅ **shipped 2026-06-15** (`feat/evals-enclave`, 6 commits). Pure `M1K3Eval` package (`ChatEvalFixtures` across 5 task-kinds · `ChatEvalScorer` heuristics incl. the latency band · `ChatEvalReport` cross-brain matrix; 27 tests TDD off-device) + the `M1K3_SELFTEST_CHATEVAL=1` headless stage (tool-use via `LocalAgent` — AFM ReAct + MLX native + AFM-native A/B). **File-config harness** (`.m1k3-selftest.json`, one-shot) sidesteps the `open --env` LaunchServices flake. *Verified live:* mini = good chat (6/6), agentically unsafe (selects tools then thrashes); lil = the agentic driver (5/5 native). The AFM-vs-floor gap, proven — and it justifies the ladder's agentic→lil+ routing.
15. **AFM-native tool-calling spike** (Edge D, **✅ SPIKED** — `feat/afm-native-tools-spike`, PR #30) — conformed `AppleFoundationModelsProvider` to `ToolCallingProvider` via `@Generable` structured output so `LocalAgent` keeps the loop (challenger's third path, not an Apple-driven loop). Pure parser TDD'd off-device (11 tests); conformance behind a default-OFF flag (launch routing unchanged); live-validated via the `M1K3_SELFTEST_CHATEVAL` harness with non-terminal stubs (web→links, lookup→empty) + the latency band. **Success criterion MET:** parseable calls ✅ + survives non-resolving results with no melt ✅ (≤93s capped vs 337s Apple-driven overflow); **but** selection weak (1–2/5 vs 5/5) + slow per-call (~20–30s) → **agentic stays lil+; mini = chat/lookup floor.** Full verdict in the Phase-15 block above + `scratch/afm-native-spike-2026-06-15/FINDINGS.md`.

16. **On-device LoRA fine-tuning** (Edge E, **NEXT** — `feat/lil-lora-spike`) — evaluation-driven fine-tuning, unlocked by the Phase-14 harness (train → CHATEVAL → read the delta). **First target: internalise the M1K3 persona/voice into lil-4B** (`mlx_lm.lora` QLoRA on the 64GB M1 Max) so the voice exemplars drop from every prompt → lower TTFT + consistent voice + no exemplar-bleed; A/B'd with exemplars removed. **Later: AFM `.fmadapter`** (Apple's rank-32 toolkit) to attack the Phase-15 selection finding — strategic but version-locked/brittle, so lil first to learn the loop. Non-negotiables: fixtures held OUT of training (no leakage) + a catastrophic-forgetting guard. Scaffold + data strategy: `scratch/lora-spike/`. (Full context in the Edge E block above.)

17. **Prompt hardening v2 + self-query routing** (security/abstention, **banked** — `docs/prompt-hardening-v2.md`) — a leak-vector session pulled the v1 prompt verbatim, recited internal QA docs as answers, and dodged abstention. **Prompt-side (ships independently):** adopt the hardened `ABSOLUTE RULES` block (instruction-hierarchy + anti-framing) / explicit self-query rule / passphrase-never-emit / abstention into `M1K3Persona.corePrompt` — keeping the user profile DYNAMIC (don't bake an identity). **Code-side (prompt can't do alone):** (1) self-query router — short-circuit retrieval on self-referential questions; (2) segregate the index — internal QA/diagnostic notes OUT of the retrievable corpus; (3) relevance threshold + de-weight `remember` writes. `CanaryGuard` already enforces the passphrase rule at the harness (defense in depth). **Make the 5 leak vectors a CHATEVAL `security` regression suite** — it doubles as the Phase-16 LoRA forgetting guard (a voice LoRA that softens a refusal is a fail). Layering: voice→weights, policy→prompt, enforcement→harness.

18. **Menu-bar app + launch at login** (always-resident, **✅ shipped 2026-06-16** — `feat/menubar-launch-at-login`) — Kev's "Mac Bar Icon App + Launch on Startup so it's always running for us and other users." New pure **`M1K3Launch`** package: `LoginItemManaging` seam + `LoginItemStatus` mirror of `SMAppService.Status` + the `@Observable LaunchAtLogin` reconcile policy (idempotent enable/disable so a stale toggle never throws "already registered"; failures surface as `lastError`; `requiresApproval` exposed for the System-Settings prompt path) — **9 tests TDD'd off-device** against a fake. `SMAppServiceLoginItem` wraps the system `ServiceManagement` framework (no third-party dep; registers the MAIN app — no helper bundle), verify-by-launch. App layer: a `MenuBarExtra("M1K3", systemImage: "brain")` scene whose presence alone keeps the process resident after the window closes (no `LSUIElement`, no custom termination policy — Dock icon kept), with Open M1K3 / Settings… / Launch-at-Login toggle / Quit; a `WindowGroup(id: "main")` so the menu can re-open a closed window; a "Startup" section in `SettingsView`. *Verified:* 1154 green; app builds; menu-bar icon confirmed live on relaunch. The login-item toggle's real registration + the menu interaction are verify-by-Kev (SMAppService needs the installed/signed bundle). **Extended same session:** (1) **pixel brand glyph** — `MenuBarGlyph` renders a template NSImage from a pixel grid; the default **"M" replicates `site/favicon.svg`** exactly (5×5 phosphor mark), with a **pixel-face A/B** selectable via a Settings picker (`menuBar.glyphStyle`); both captured live and compared. (2) **Menu-bar-only mode** — pure `StartupVisibility` policy (TDD, 2 tests) → app maps it to `NSApp.setActivationPolicy(.accessory)` (via an `AppDelegate` in `applicationWillFinishLaunching`, set before the first window so no Dock-icon flash) + `WindowGroup.defaultLaunchBehavior(.suppressed)`, so a launch-at-login start is **quiet** (no focus-stealing window); opt-in toggle (default OFF), live Dock-icon flip on change. 14 launch tests green. Remaining follow-up: a 7×7 face if the 5×5 reads too sparse (Kev's taste call).

18b. **Rich menu-bar popover + state-reflective glyph** (**✅ shipped 2026-06-16**, same branch) — drawing on CartogramMac's bar craft, the dropdown became a `.menuBarExtraStyle(.window)` glass popover: an inline **Ask M1K3** (grounded answer with no main window, "Continue in chat →" escalation), a live header (brain · runtime · activity dot), and quick toggles (voice ⌘⇧V / web / MCP). The Ask reuses the proven `MCPHostController.askBrain` pattern via a new **`MenuBarAsk`** controller (dedicated responder off `env.provider` façade · single-flight · 120s `withTimeout` · shared `CanaryGuard.fromLocalConfig`). The glyph is now **state-reflective**: pure `AvatarActivity.glyphTreatment(isRecording:)` (M1K3Avatar) → calm idle / pulsing accent thinking / red recording / glow speaking, rendered by `MenuBarLabel` (TimelineView pulse, steady colour the fallback). **TDD:** `GlyphTreatment` (6) + `MenuBarAskState`/driver + `CanaryGuard.fromLocalConfig` (7) — 13 pure tests; controller/label/popover are verify-by-launch. Dedup'd the canary key to one `CanaryGuard.localConfigKey`. *Verified:* 1172 green; app builds; pixel-M live in the bar (idle). The popover interaction + glyph animation are verify-by-Kev (click the M; terminal lacks accessibility to auto-open it).

19. **Privacy-preserving age-adaptive behaviour** (**ROADMAP / seed 2026-06-19** — Kev's thought off the App Store privacy pass) — adapt M1K3's behaviour to the user's life-stage **without ever collecting a birthdate or any PII**, using Apple's 2025 **Declared Age Range API** (parent-gated via Family Sharing/Screen Time; returns a *coarse band*, not an age). The band feeds two layers, mirroring the Phase-17 doctrine (**policy→prompt for tone, enforcement→code for safety**):
    - **Prompt layer (tone/posture):** inject an age-appropriateness clause into the DYNAMIC part of `M1K3Persona.corePrompt` (same dynamic-profile seam Phase 17 keeps open — never bake an identity into the weights/persona). A minor band → gentler register, steer away from mature topics; adult/absent → unchanged.
    - **Code layer (hard safety):** a real gate on the web-search / fetch tools and unrestricted generation for minor bands — defense-in-depth like `CanaryGuard`, because the prompt alone is not a safety boundary. Reuses the existing web/tool toggle plumbing.
    - **TDD core:** a pure `AgeAppropriatenessPolicy` (band → `{ webSearchAllowed, generationPosture, promptClause }`), mirroring `GlyphTreatment`/`StartupVisibility` — fully unit-testable off-device; the API request flow + a Family-Sharing minor account are verify-by-Kev.
    - **Non-negotiables (the brand is the point):** ZERO PII — the band is ephemeral (fed to the prompt, persisted at most as a coarse local enum, never transmitted), preserving the "collects nothing" `PrivacyInfo.xcprivacy` we just shipped. It is age-**assurance**, not age-**verification**: **declining must not degrade the adult experience** (privacy-respecting means an undeclared band defaults to full capability — we never demand proof of adulthood). Could double as a CHATEVAL `age-posture` fixture set (web-gated-for-minor, tone-shift), riding the Phase-14 harness.
    - **⚠️ Verify before building (confidence ~0.7 on Apple specifics — anti-confabulation):** the exact Declared Age Range API surface, **macOS availability** (it may be iOS-first), the band granularity, and the decline/absent semantics all need confirming against the current Apple docs + SDK. This is a real feature, not this submission — the App Store age *rating* questionnaire (metadata) is the only age item required to ship.
    - *Verify (when built):* request flow returns a band on a Family-Sharing minor account → web tools gated + register softens; adult/declined account → behaviour identical to today; `PrivacyInfo.xcprivacy` still declares zero collection.

20. **Cool Head — thermal/power-aware "Prudent Compute"** (**SPIKED 2026-06-20** — `feat/cool-head`, PR #73; **WIRED 2026-06-21** — `feat/prudent-compute`) — M1K3 respects the machine it runs on: under thermal/power pressure it caps **effort**, not intelligence. **Challenger-reframed from the original "delegate the brain down a tier when hot" idea, which was rejected:** routing routes across *reach* (on-device/cloud), NOT tier — there is no `min(userRequested, ceiling)` seam; a brain swap is a full `selectBrain` model reload that **dumps the KV + persona-prefix caches** (partly defeating the thermal goal it was invoked for); and auto-demoting the proud MLX brain to the weaker AFM breaks the *"Lil is who I am"* identity (the product deliberately doesn't auto-pick AFM — `EscalationLadder`). So the lever is the cheap, coherent, mid-conversation-safe one: cap **`LocalAgent.maxIterations`** (already a plain `Int`) + pause background work + an honest defer at `.critical`.
    - **Pure `CoolHeadPolicy`** (`M1K3LanguageModel`, zero deps, GPU-free, 10 tests): `target(thermal:lowPower:)` → `.full`/`.eased`/`.minimal` (critical→minimal, serious or low-power→eased); `next(state,target,minRecoveryTurns)` with **mandatory HYSTERESIS** — degrade immediately, recover only after a *sustained* relief streak, a pressure blip resets the streak (the challenger's #1 risk was per-turn thrash under a bouncing `thermalState`); effort knobs (`maxIterations` cap that never raises the caller's base, background-work gate, defer-heavy-gen).
    - **Signal B (measured tok/s) DEFERRED** — it's MLX-only, log-only (OSLog, not a readable value), a warm/cold baseline swamp, and it targets *dev-process* GPU contention (overlapping `M1K3_SELFTEST` runs), NOT a real-user condition. `ProcessInfo.thermalState` + `isLowPowerModeEnabled` (already used at `AvatarChatBackground.swift:36`) cover the genuine "laptop on the knees" case. Fast-follow only if on-device logs prove thermal-alone misses real-user contention.
    - **WIRED 2026-06-21 (`feat/prudent-compute`):** `applyCoolHeadIfEnabled()` reads the two `ProcessInfo` signals per send and threads `CoolHeadState` through `CoolHeadPolicy.next` (hysteresis) into a process-wide `Mutex<CoolHeadState>`; `AgentRAGResponder.maxIterationsProvider` (an opaque `@Sendable () -> Int` — M1K3Chat must NOT link M1K3LanguageModel, so the enum→Int map lives app-side) reads the level **live** per turn and applies the agent-loop cap. Behind its own opt-in (`coolHeadEaseKey`, default OFF → byte-identical). **Never swaps the brain** (the per-send `applyAutoRouteIfEnabled` site + `selectBrain`-is-a-full-reload were the decisive evidence; re-adjudicated via a design panel this session — B rejected again). 2 new responder tests (consulted-per-turn proves live, not snapshotted; lower cap runs strictly fewer iterations).
    - **Companion lever — RAM ceiling (`BrainTier.capped`, NEW 2026-06-21):** this DOES add a `min(tier, recommended(forPhysicalMemoryGB:))` seam — but keyed on **machine capability (physical memory), NOT heat**, so it's consistent with the thermal rejection above (thermal→effort; capability→ceiling). Lower-only (never raises — raising = a silent multi-GB download, #81's honesty rule); makes the opt-in auto-route machine-aware (it was flooring at Lil on big Macs AND keeping a too-heavy Big on small Macs — Big has no hard floor). Manual selection stays sovereign. `BrainTier: Comparable` by explicit weight; 12 tests.
    - **Two CoolHeadPolicy knobs still UNWIRED — named follow-ups (own small PRs):** (1) `defersHeavyGeneration(.minimal)` — at `.critical`, surface ONE honest line (`"running light to keep your Mac cool · still fully local"`) and offer Mini as a one-tap USER choice instead of starting the heavy decode (cleaner once #81's toolbar brain-switch lands; `.critical` is rare/brief). (2) `allowsBackgroundWork` — pause constellation-polling/re-embed under heat (per-site judgement: deferring `reindexIfEmbedderChanged` at launch could leave stale embeddings degrading retrieval until cool — not a blind one-liner). The shipped Settings copy ("trims M1K3's effort") is honest about the iteration-cap that IS wired and does not promise either.
    - *Origin:* the session's own eval gotcha — lil latency degraded 5× (61s→300s) under sustained load; the lesson ("respect the machine") became the feature. *Verify (verify-by-launch, owed — a HOT machine, not manufacturable in a unit test):* force `.serious`/`.critical` (a stress load) → iterations cap; a brief blip does NOT flip effort; the user's chosen brain is unchanged throughout. Plus: auto-route ON → the pick is sized to this Mac.
    - **ADDENDUM 2026-07-13 (additive — supersedes "behind its own opt-in" above): Prudent Compute is now ALWAYS-ON.** Kev's call in the Settings-reduction pass (`feat/settings-panes`, Rubin's "you couldn't decide, so you asked the user" challenge): the `coolHeadEaseKey` toggle + default-OFF gate were removed; `applyCoolHeadIfEnabled()` → `applyCoolHead()` (unconditional). Rationale: the feature never swaps the brain and is byte-identical at `.full`, so the toggle was fear, not choice. Same pass also cut "Prefer Apple on-device" (auto-route always passes `false` — anyone wanting Apple picks Mini) and the menu-bar glyph picker (pixel-M ships as THE glyph). **Knob-status correction (review-caught):** removing the shared gate also wired BOTH knobs above for everyone — `defersHeavyGeneration` (deliberate) AND `allowsBackgroundWork` (side effect, kept as intended behaviour): launch reindex/embedder-warm/Spotlight-sync now defer under serious heat OR Low Power Mode for all users. The stranding gap that came with it (battery-saver toggles fire the power-state notification, not the thermal one the recovery observer watched) is closed by a second observer on `NSProcessInfoPowerStateDidChange` — deferred work recovers the moment Low Power Mode lifts.

21. **Model & Inference Upgrade** (**PLANNED 2026-06-22** — research + plan complete, implementation next session) — the brain tiers were pinned in the Gemma 4 era (2026-06-13, mlx-swift-lm 3.31.3). Since then: **OptiQ mixed-precision quantization** landed on HuggingFace (per-layer sensitivity analysis → same disk size, meaningfully better reasoning); new small-model families emerged (Phi-4 Mini, SmolLM3, Granite 4.1); and the MLX framework added speculative decoding + Gemma 4 MTP drafters. Three layers:
    - **Layer A — OptiQ variant swap (quick win, do first):** swap the 3 MLX model IDs from uniform 4-bit to their OptiQ mixed-precision equivalents. Fixes the **known PLE (Per-Layer Embedding) corruption bug** in stock Gemma 4 4-bit quants (GSM8K 24→56% on E4B); Qwen3.5 sees 2.3x GSM8K lift. Same families, same tool-call dialects, same think-tag behaviour → same `supportsQuantizedKVCache` / `resolveToolCallFormat` / `templatePreOpensThink` family detection (substring matching preserved). One small PR: `BrainTier.swift` model IDs + download sizes, `BrainTierTests` + `MLXGemmaProviderTests` pinned assertions. Existing users re-download ~same-size weights on next launch. Pre-flight: verify the 3 OptiQ repo IDs exist on HuggingFace.
    - **Layer B — New model candidate evaluation (eval-gated, no production change until proven):** run CHATEVAL harness against: **(B1) Phi-4 Mini 3.8B** (`mlx-community/Phi-4-mini-instruct-4bit`, ~2.5 GB — lil contender: 89% GSM8K, native fn-call, 128K ctx; `.json` tool-call already handled; KV-quant support unknown → investigate `attentionWithCacheUpdate` routing); **(B2) SmolLM3 3B** (budget dark horse: smallest footprint ~2 GB, Apache 2.0, dual-mode reasoning; tool-call dialect + mlx-swift-lm arch support unknown → check before eval); **(B3) Granite 4.1 8B** (big contender: 87% HumanEval, strong tool-call + RAG; tool-call dialect needs verification); **(B4) Qwen3.6-35B-A3B MoE** (huge ceiling-raiser: 35B total / 3B active; **BLOCKED** on MoE arch support in mlx-swift-lm). Eval via temporary `MLXGemmaProvider(modelID:)` in the self-test harness — no hidden tiers in the user-facing `BrainTier` enum. Compare `grounded-Q` + `open-chat` scores (tool-use, persona, citation, latency) on an IDLE machine, serialised (per the 2026-06-20 thermal-contention lesson).
    - **Layer C — Framework-level improvements (track upstream, act when unblocked):** **(C1) Speculative decoding** — already in mlx-swift-lm 3.31.3 but unwired; 74% tok/s improvement on 27B models, smaller gains on 4B–9B; needs investigation on drafter model availability per family (MTP drafters are Gemma-specific — Qwen may need a separate small drafter or skip spec-decode). **(C2) OptiQ per-layer KV cache** — current: uniform 8-bit KV for Qwen families (`kvBits=8, kvGroupSize=64`); OptiQ's per-layer precision gives +62% decode tok/s at 64K context — blocked on `GenerateParameters` exposing per-layer kvBits upstream. **(C3) Gemma 4 quantized KV** — `Gemma4Text` calls `cache.update(keys:values:)` directly (fatalError on QuantizedKVCache at 3.31.3); once upstream fixes it, add "gemma-4" to the `supportsQuantizedKVCache` allowlist for Big-tier memory/speed win. **(C4) WWDC26 rebuilt AFM** — macOS 27's on-device model adds vision + better tool-calling + the `fm` CLI → re-eval Mini for agentic capability (Phase-15 found mini 0/5 on ReAct tool-use; rebuilt model may graduate it).
    - **Upstream blockers:** Gemma 4 12B (`gemma4_unified` arch registration → Big tier upgrade to trimodal 12B) · Qwen3.6 MoE (arch support → Huge tier ceiling-raiser) · Gemma 4 KV quant (`Gemma4Text` → `attentionWithCacheUpdate`) · per-layer KV config (`GenerateParameters` per-layer kvBits) — all tracked at ml-explore/mlx-swift-lm releases/PRs.
    - *Verify:* `swift test` green (pinned assertions updated); on-device ⌘R each tier downloads OptiQ and generates correctly; CHATEVAL `grounded-Q` + `open-chat` scores compared pre/post-OptiQ (citation rate, tool-use rate, latency); family detection returns same values for OptiQ IDs (substring matching).

<!-- Signed: Kev + claude-opus-4-6, 2026-06-22, Confidence 0.85, Prior: Kev + claude-opus-4-8 (this file).
     Context: Research session — cross-referenced HuggingFace model landscape + MLX framework state
     against M1K3's BrainTier/MLXGemmaProvider/MLXToolCalling implementation. The OptiQ PLE bug fix is
     the high-confidence quick win (same families, proven quant improvement); new-model candidates are
     eval-gated (no production change without CHATEVAL proof); upstream blockers are named and tracked.
     The 0.85 confidence reflects: OptiQ variant existence on HF is research-sourced (web search), not
     locally verified (pre-flight check is the first implementation step). -->

---

### STATUS 2026-06-30 — third-party codebase review triaged (CODEBASE_REVIEW_2026-06-30.md)

A non-Claude tool ("opencode/big-pickle") produced a 16-finding firehose review of `macos/` +
the legacy Python MCP server (`docs/CODEBASE_REVIEW_2026-06-30.md`). A recoup session
adversarially verified the highest-confidence findings against current source before acting —
several didn't survive contact with the live codebase:

- **Actioned (shipped this session):** CQ-3 (NSLock/Mutex inconsistency) — unified
  `SwappableInferenceProvider` + `SwappableSpeechProvider` on `Synchronization.Mutex`, dropping
  `@unchecked Sendable`; mechanical, existing test coverage carried through unchanged.
- **REFUTED — claim was already stale by the time it was reviewed:** S-3 ("`.mcp.json` points to
  Python") — `.mcp.json` was fixed to point at the in-app HTTP server *earlier the same day*
  (commits `1eead79d`/`45ed9722`), before this review doc was even written. Corrected two
  downstream-stale doc references (root `CLAUDE.md`, `README.md`) that still claimed
  `mcp_unified_server.py` "remains live."
- **REFUTED — dead code, not a live bug:** CQ-1 (`ProviderRouter` generate/generateStreaming
  fall-through asymmetry) and CQ-4 (its dead `anyAvailable` store) — `ProviderRouter` is never
  constructed in `M1K3App/`; production routes through `RuntimeInferenceProvider`'s single-active-
  backend model instead. Left unfixed; **open decision for Kev:** delete `ProviderRouter` (dead) or
  wire it in as the real selection mechanism — polishing it in place fixes nothing live either way.
  - **RESOLVED 2026-07-01 — DELETED.** Kev's call: delete. Its availability-ordered fall-through
    semantics contradict the explicit single-brain product model (`RuntimeInferenceProvider` is the
    real selector), so wiring it would have meant re-architecting `selectBrain`/`RuntimeSelectionBox`
    for no user benefit. Removed `ProviderRouter.swift` + `ProviderRouterTests.swift` + the now-orphaned
    `InferenceError.noProviderAvailable` case (~−205 LOC); CQ-1 and CQ-4 evaporate with it. `swift test
    --filter M1K3InferenceTests` green (120 tests).
- **CONFIRMED but NOT a same-session fix:** CQ-8 (MCP timeout) — the claim's "120s" framing was
  wrong (the real binding ceiling on the MCP surface is the tighter 50s `IntelligenceMCPTools`
  timeout, not `MCPHostController`'s 120s, which only gates the Siri/Shortcuts App Intent path).
  The underlying problem is real and already worked around (verify thinking models in-app, not over
  MCP). A poll-based fix needs a new client-visible MCP tool surface + a job registry — a protocol
  decision, not a patch. **Demonstrated live this session:** an `ask_m1k3` call during dogfooding hit
  exactly this 50s ceiling.
- **CONFIRMED but inert/low-priority:** P-1 (duplicate `generate_response` methods in
  `simple_ai_engine.py`, actually ~8 duplicated methods not 1) and P-2 (`mcp_unified_server.py`
  blocks on `sd.wait()`) — both real, but `mcp_unified_server.py` is no longer the live MCP path
  (see S-3) and `simple_ai_engine.py` is only reachable from the archived `_legacy/` CLI tree.
- **Also fixed (separately tracked, not from this review):** the already-scoped
  `voice-priority-inversion` hang risk (auto-memory) — `StreamingPlaybackSession.complete()` called
  `player.stop()` synchronously from whatever QoS context triggered it (including a user-initiated
  stop on a high-QoS caller); deferred to a `.utility`-priority `Task`. The companion `isSpeaking()`
  MainActor-hop (`EffectfulSpeechProvider.swift:142`) and the 33ms `StreamingPlaybackSession.tick()`
  poll loop are both real but verify-by-launch-only (no automated threading regression coverage) —
  left as a named follow-up rather than guessed at blind.
- **Not yet triaged:** S-1/S-2/S-4/S-5 (structural — AppEnvironment/ChatSession size, 22-target
  proliferation, dual-database architecture) and T-1/T-3 (UI test coverage) remain open in the
  original doc for a future pass.

<!-- Signed: Kev + claude-sonnet-5, 2026-06-30, Confidence 0.85, Prior: Kev + opencode/big-pickle
     (CODEBASE_REVIEW_2026-06-30.md), Kev + claude-opus-4-8 (this file).
     Context: verified-review pass (7 parallel adversarial-verify agents) over the third-party
     review's highest-confidence findings before acting on any of them. Two findings flipped from
     "high confidence bug" to "dead code" on contact with the actual call graph (CQ-1/CQ-4); one
     flipped from "needs fixing" to "already fixed earlier today" (S-3); one was demonstrated live
     during MCP dogfooding (CQ-8). The lesson: verify a third-party review's claims against current
     source before fixing — confidence scores in the source doc reflect a deep read, not a
     verified one. -->

---

## Files to reuse (vendor + MurphySig review)

| Capability | Source (read-only IP) |
|---|---|
| Inference protocol, AFM provider, ReAct loop, AgentTool | internal call-pipeline project sources (private) |
| Embeddings (MLX) | internal knowledge-server project sources (private) |
| Semantic store + hybrid search + KG | internal knowledge-server project sources (private) |
| Documents + RAG prompt | internal knowledge-server project sources (private) |
| Transcription (pluggable) | internal call-pipeline project sources (private) |
| Call log: model + persistence | internal call-pipeline project sources (private) |
| Call log: diarization + summary + UI | internal call-pipeline project sources (private) |
| TTS seed | internal knowledge-server project sources (private) |
| Avatar model + emotion mapping | `m1k3/src/web-avatar/` (GLB→USDZ), `m1k3/app/.../avatar/ToolEmotionMap.kt` (concept) |

**Provenance:** vendored files keep their original MurphySig and gain a review block documenting the macOS port. New files get `Signed: Kev + claude-opus-4-8, 2026-06-06, Prior: Unknown` per the no-fabrication rule.

---

## Risks / open items

- **LiteRT on macOS/Swift is unproven** — no official Swift bindings; the C++ LiteRT-LM engine likely needs a C-shim or sidecar. De-risked by phasing it as a spike behind the protocol (MLX is the reliable Gemma path; LiteRT can fail without blocking the MVP).
- **mlx-swift-lm LLM generation** — ✅ *de-risked at compile level* (2026-06-06). `MLXLLM` (`ChatSession` + `LLMModelFactory`) is wired in `MLXGemmaProvider` (default Gemma 3 1B QAT-4bit) and the app builds with it linked. ⏳ remaining: **first on-device generation** (download + stream). **Gemma 4 now exists** (shipped 2026-06-03 — see the Gemma 4 update at the top); the wired generation model is still `gemma-3-1b-qat-4bit`, with **Gemma 4 E4B as the upgrade target** (and the unification candidate for ASR + diarization + summary). **Two gotchas locked in:** (1) embeddings default to `.bge_small` not nomic — MLXEmbedders' nomic loader has a weight-key mismatch (the prior knowledge-server's lesson); (2) `xcodebuild` needs `xcodebuild -downloadComponent MetalToolchain` once (`swift build` doesn't). The MLX backends live in one isolated **`M1K3MLX`** target (both embedder + provider), not the originally-sketched `M1K3Embeddings`.
- **"Single model" for ASR — now real, pending benchmark (revised 2026-06-06).** Gemma 4 E2B/E4B do native audio ASR **+ diarization** on-device via MLX-Swift or LiteRT. The MVP still **ships on WhisperKit + Apple Speech** (proven, low-latency streaming today); Gemma 4 E4B is a **tracked spike behind the `TranscriptionProvider` seam**, not an MVP dependency. Promote it only if it beats WhisperKit on latency/accuracy (and its diarization holds for P7). Risk if we unify: one model gates ASR, chat, and calls — benchmark before betting the stack.
- **Tool-call dialect is per-model (learned on-device 2026-06-10).** Prompt-ReAct works as the floor everywhere but compliance varies (AFM follows it; Gemma-3n announces tools in prose — mitigated with format reminders + observation-rescue fallback). Native dialects (Phase 12) raise the ceiling. **Update (source probe, 2026-06-10):** for MLX the per-backend *parsing* surface we feared owning is **already in `mlx-swift-lm` 2.30.6** (`ToolCallProcessor` + `GemmaFunctionParser` + 6 other dialects, emitting structured `.toolCall`) — so 12c is wiring, not parsing, and needs no version bump. The remaining empirical risk is **12d only**: whether Gemma-3n-E4B actually *emits* the `call:name{…}` format on-device (a runtime benchmark). The seam keeps ReAct as the fallback so no model is ever locked out. Benchmark before promoting, same doctrine as transcription.
- **RAG grounding relevance — ✅ SHIPPED 2026-06-10 (`feat/ttft-reasoning-retrieval`).** `GroundingGate` filters retrieve-first injection on vector cosine similarity (NOT rrfScore — rank fusion carries no absolute relevance); `searchHybrid` backfills similarity onto fused hits. Nothing topical → nothing injected, and the prompt tells the model its documents are NOT in context and to call `search_knowledge` (now full hybrid search; the hits it retrieves flow into sources + the citation allow-list via `ToolSourceCollector`). Thresholds (`GroundingGate.chunkThreshold`, 0.45 starting point for bge-small) are logged per-hit (category `responder`) — **tune on real queries at ⌘R, then update the constants.**
- **macOS 26-only** narrows the test surface to Tahoe machines — acceptable for a personal MVP, revisit before any wider release.
- **Call recording legal/consent** — recording calls has consent obligations; the app must make recording explicit and consented (one of M1K3's privacy principles). Surface a clear recording indicator + consent gate.
- **Placement** — assumes `m1k3/macos/`. If you'd rather it be its own repo, that's a one-line change to the scaffold.
- **Citation noise on conversational/identity turns — TRACKED 2026-06-17 (live repro via the new Ask App Intent).** A "who are you / hello" banter turn attached irrelevant academic citations (Chinchilla / chain-of-thought / self-consistency) in the Sources footer. NOT an App-Intent bug — the intent faithfully surfaces a pre-existing core behaviour, so it hits every ask surface (MCP `ask_m1k3`, menu-bar Ask, the Ask intent) identically → **fix once in the core, all benefit.** Two colliding causes: (1) the persona self-query/identity "don't search docs" rule is prompt-only + unenforced (`AgentRAGResponder.swift:435/452`); (2) the grounding gate is promiscuous — `HeadlessAsk` even documents off-topic-but-above-threshold chunks riding into the footer ("F4"). Preferred levers (NOT a pre-gen router — team already rejected that as brittle): a post-hoc "were these sources actually referenced?" abstain-from-citing check in `HeadlessAsk`, and/or a tighter grounding threshold for short/identity queries. Needs its own eval + a challenger pass (taste- and grounding-sensitive). Park: do AFTER the App Intents PR lands.

## Verification (end-to-end)

1. Launch `M1K3.app`. Drop in a PDF → it ingests + embeds.
2. Speak a question about the PDF → WhisperKit transcribes → RAG retrieves → active runtime (AFM/MLX/LiteRT, selectable) streams a grounded, citation-valid answer → AVSpeech speaks it → avatar emotes + lip-syncs.
3. Record a 2-party call → live diarized transcript ticker → on end, AFM quick summary + Gemma 4 deep analysis (action items/risk flags) → call appears in history, searchable, and answerable in chat via RAG.
4. Ask a multi-step question → `LocalAgent` runs the ReAct loop using `SearchKnowledgeTool`/`QueryGraphTool` (incl. call data).
5. From Claude Code, connect to the `M1K3MCP` stdio server → call `search_knowledge` → confirm it returns documents **and** logged calls from M1K3's graph.
6. Open the runtime picker, run `RuntimeBenchmark` → review the MLX vs LiteRT vs AFM comparison (and Whisper vs Gemma-audio if the spike landed).
7. `swift test` green across all packages; no new warnings.

## Update — 2026-07-08: Phase 17 — the egress seam + the PCC rung (Edge A phased; challenger-shaped)

**Context:** First external TestFlight submission went to Beta App Review this morning. Kev's product
call: PCC ships **off by default but easily opt-in-able**. Proposed sequencing (escalation UI first,
PCC wiring behind the FM27 gate) was challenger-tested; two findings flipped the order — adopted here.

**The challenger findings that shaped this (both verified in source):**
1. **The "hard egress gate" is soft today.** `LadderContext.networkAllowed` is sourced from the
   web-search toggle, which **defaults ON** (`AppEnvironment+ChatHistory.swift:64` — its own TODO
   calls it "a provisional proxy only"). Wire a runnable network rung against that and chat egress is
   governed by a toggle most users left on to search the web. The dedicated egress-consent key is not
   polish — it is the prerequisite.
2. **No dead controls reach Tahoe externals.** On macOS 26 the `.privateCloud` rung resolves
   `?? local` (`EscalationLadder.swift:80`); an escalation control shipped before its rung either
   hides for months or silently returns the local answer — and a gated-but-present egress path in the
   externals binary is a privacy-label liability (our own SECURITY.md ranks data-egress above RCE).

### Phase 17a — the dedicated egress-consent key (NOW; Tahoe-safe; ships to externals)
- Replace the web-search proxy as the ladder's `networkAllowed` source with a dedicated,
  **default-OFF** chat-egress consent key (closes the in-source TODO at
  `AppEnvironment+ChatHistory.swift:60-63`). Web search keeps its own toggle; the two consents are
  different categories and never share a switch again.
- Pure policy + persistence; unit-testable off-device; strengthens the shipped "nothing leaves"
  promise rather than spending it. **This lands before any network backend exists**, so flipping it
  changes nothing user-visible yet — it is the wall built before the door.

### Phase 17b — PCC executor + escalation control + consent UX (macOS-27 branch, M1K3_FM27; NOT in Tahoe externals builds)
- **Executor lane:** `PrivateCloudComputeLanguageModel` already conforms in the macOS 27 SDK, but
  selection ≠ execution — everything downstream is `BrainTier`-shaped; PCC needs its own
  `LanguageModelSession(model:)` lane. New work, honest scope (challenger: "an order of magnitude
  more than wiring").
- **The consent UX (Kev's "easily opt-in-able", challenger-tempered):** off by default, easy to turn
  on, but **NOT struggle-triggered** — egress is a category boundary the earned-moment/struggle
  pattern was never tested against, and a frustration moment is the wrong time to weigh privacy.
  Surface: a calm, discoverable invitation (Settings + a non-frustration in-flow moment, e.g. the
  brain picker's "when you want more" context) with a one-look explainer of exactly what leaves
  (the prompt, attested, stateless) and what stays (documents, memories, history). Per-request
  escalation stays explicit on top of the 17a gate; a no parks it (terminal-dismissal doctrine holds).
- **The escalation control ("go deeper") ships WITH the reachable rung, never before it** — 27-only,
  same branch, so no dead control and no label mismatch ever reaches a Tahoe external.
- **Honest target:** "wired and beta-smoked on non-launch hardware; GM runtime verify-owed" — NOT
  "live day-one." Betas drift (the Xcode-Cloud float lesson); re-verify at GM is the plan, not the
  failure case.
- **Pre-flight:** App Privacy nutrition label reviewed for PCC egress BEFORE the rung is runnable in
  any externals-reachable build (Apple-attested ≠ non-disclosable). PCC rides the Small Business
  Program (<2M downloads — free rung; ladder stays on-device → PCC → BYO-key).

### Held
- **Claude/Gemini rung:** product decision (whether / how loud) before any engineering. 17a's key is
  deliberately its prerequisite too — one gate, every network rung behind it.

**Sequencing rationale in one line:** build the wall (17a, now), then the door with the porch light
(17b, on 27), and only then decide who else gets a key (held).

<!-- Signed: Kev + claude-fable-5, 2026-07-08, Confidence 0.85 — Edge A phased after a challenger
     pass whose two blocking findings (default-ON egress proxy at AppEnvironment+ChatHistory.swift:64;
     dead-control/privacy-label risk on Tahoe) were verified in source and folded; the struggle-trigger
     rejection for egress consent is a doctrine boundary call (earned-moments stay local), Kev's
     "easily opt-in-able" preserved via the calm-surface shape. Unproven: PCC executor scope is
     estimated from the SDK surface, not built; GM drift risk named not sized. Prior: Kev +
     claude-opus-4-8 (this file, Edge A analysis 2026-06-14). -->
