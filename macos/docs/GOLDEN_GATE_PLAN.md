# Golden Gate (macOS 27) — Plan & Progress

Spike date: 2026-09-12. Public release: Sep 14.
Probed on: macOS 27.0 (Build 26A428), Xcode 26.6, SDK 26.5.
Build status: 3,700 tests green, zero code changes needed.

> **Correction, 2026-09-13.** The 09-12 spike read the **macOS 26.5 SDK**
> (Xcode 26.6). The macOS 27 SDK (Xcode-beta 27.0, build 27A5194q) has a
> different surface: `LanguageModelExecutor`, a public `LanguageModel`
> protocol and `PrivateCloudComputeLanguageModel` all exist there. Each one
> appears zero times in the 26.5 SDK, which explains the miss. See
> [The macOS 27 SDK, verified](#the-macos-27-sdk-verified-2026-09-13) and the
> [Roadmap](#roadmap-10--11--12) below. The table's executor row is corrected.

Release execution is tracked separately in
[Golden Gate release gate](./GOLDEN_GATE_RELEASE.md). Its candidate-SHA,
physical Mac, physical iOS, archive-MLX-smoke, and full in-app CHATEVAL evidence
are required before promotion; this document records the product investigation,
not release approval.

---

## What shipped (verified)

| Claim | Status | Evidence |
|-------|--------|----------|
| Model quality uplift | **CONFIRMED** | 41/44 eval (93%), 6/7 security (was 0/14), persona adherence crisp |
| Token counting API | **CONFIRMED** | `tokenCount(for:)` on prompts, instructions, tools, schemas — exact |
| Context window expanded | **NOT TRUE** (on-device) | AFM still 4096 tokens (runtime-confirmed again 09-13). PCC reports **32,768** |
| LanguageModelExecutor protocol | **EXISTS** (27 SDK) | ~~Does not exist~~ was a 26.5-SDK read. The 27 SDK has it, and M1K3's `M1K3FoundationModel` conformance compiles against it unchanged (09-13) |
| Adapter API (LoRA) | **KILLED** | "Custom adapters are no longer supported since iOS 27, macOS 27, visionOS 27" |
| AFM 3 Core Advanced (20B sparse) | **NO EVIDENCE** | Asset names still reference `instruct_3b`; no API change |
| Metal Int4/UInt4 tensors | **CONFIRMED** | `MTLTensorDataTypeInt4/UInt4` at macOS 26.4 — upstream mlx-swift concern |

## Plan

### Done

- [x] Build green on Golden Gate (3,700 tests, Release compiles)
- [x] SDK swiftinterface fully read — Adapter dead. (The 09-12 read was the
      26.5 SDK. On the 27 SDK LanguageModelExecutor DOES exist; see the 09-13 section.)
- [x] Live AFM probe — availability, contextSize, generation, token counting
- [x] Quality eval — 41/44 (93%), all categories scored
- [x] Token budget spike — Mini has 1.9× more room than the conservative estimate
      (corrected: real persona 1,466 tokens, not the compact 214-token test)
- [x] Replay depth measured — 16-message conversation in 769 tokens
- [x] Blog post: Golden Gate dispatch on m1k3.app

### Ship (code changes for release)

- [x] **Wire `tokenCount` into `HistoryBudgetPolicy` for Mini** —
      `measuredMiniBudget` added (pure, 5 tests green). `TokenCountable`
      protocol + AFM conformance. The [SPIKE] resolved. App composition root
      wiring still owed (the policy is ready; the caller needs to measure and
      pass the exact token count at launch).

- [ ] **Wire `tokenCount` into `GroundingBudgetPolicy`** — exact source token
      measurement instead of the chars/3.5 estimate. Mini's grounding block is
      68 tokens for 296 chars (ratio 4.4, not 3.5) — the budget is slightly
      over-conservative today. Lower risk, lower urgency. The arithmetic with
      measured costs: 462 tokens fixed → ~1520 available (was estimate ~1520
      coincidentally) → current 600-token grounding budget is reasonable. May
      uplift to ~800 once measured end-to-end.

- [x] **Log exact token usage on every Mini turn** — `logTurnStart` currently
      logs char counts; add a companion `afm budget: instructions=N prompt=N
      total=N/4096` line using the new API. The first real-traffic data for
      the budget policy.

- [x] **Update `MODEL_CHOICES.md`** — document Adapter deprecation, the eval
      results, and the token counting win. The standing "Phase 17b" reference
      in ROADMAP needs rescoping.

- [ ] **Use `prewarm(promptPrefix:)` for Mini** — the SDK now accepts an
      optional prompt prefix when prewarming. Today we prewarm with instructions
      only; passing a prefix of the recurring prompt shape (grounding header,
      tool block) could cut Mini's first-token latency further.

### Explore (evaluation-gated)

- [ ] **Full SelfTest CHATEVAL on Mini** — the standalone eval covered 44
      fixtures; the real harness has 86. Needs the live app quit + a signed
      build launched with SelfTest config. Measures tool-use through the real
      agent path (ReAct floor), which the standalone can't.

- [ ] **Mini vs Lil quality comparison** — if Mini's quality uplift closed the
      gap on open-chat and world-knowledge, the tier recommendation could shift
      (Mini as a more credible "good enough" for lightweight use).

- [ ] **`contextSize` dynamic read** — the back-deployed getter returns 4096,
      but a future macOS 27.x update could change the runtime value. Wire a
      launch-time read instead of the hardcoded `approximateContextTokens`.

- [ ] **Metal Int4 adoption watch** — track mlx-swift issues for native 4-bit
      tensor support. When upstream adopts `MTLTensorDataTypeInt4`, M1K3's
      quantized models get hardware dequantization for free.

### Quality levers (from the eval)

- [x] **Mini security on Golden Gate** — PROBED 2026-09-12 via MCP (7 live
      questions through the running app). Score: **7/7** (6 PASS, 1 SOFT — no
      leaks). The model refuses naturally in character ("I don't share my own
      wiring") without the robotic blocks macOS 26 Mini needed. The prompt
      hardening (#221, #240) is NOT over-constraining — it provides a safety
      net the improved model doesn't fight. No relaxation recommended; the
      ABSOLUTE RULES section stays as-is.

- [x] **Mini ReAct iteration cap** — RESOLVED 2026-09-12. Golden Gate Mini
      converges in 1 iteration every time (5/5 probes via MCP). The deeper
      finding: Mini never enters the tool loop at all — it answers from
      grounded context. Token budget (3,186/4,096 on a single grounded turn)
      is too tight for tool-use prompt overhead on top of persona + grounding.
      The quality lever is persona trimming (1,466 tokens / 36% of window),
      not the iteration cap.

- [x] **Mini voice exemplars revisit** — PROBED 2026-09-12 via MCP (5 live
      questions incl. the honey trigger and "tell me a fun fact"). **Zero
      parroting** — the 2026-08-03 "Honey never spoils" failure does NOT
      reproduce on Golden Gate. Mini references the honey memory naturally
      without verbatim recitation. Voice register is consistently WARM with
      personality, curiosity, and grounded answers. The parroting was a model
      weakness, not a prompt defect. Next step: re-run the exemplars-ON
      experiment (the 2026-08-03 code comment in AppleFoundationModelsProvider
      says "don't re-try without new evidence") — Golden Gate IS new evidence.

### Persona trimming (the biggest lever, from the MCP probes)

Mini's persona is **1,466 tokens / 36% of the 4,096-token window**. With
grounding + replay + generation reserve, a single grounded turn hits
3,328/4,096 (measured). The persona sections:

| Section | ~Tokens | % of window | Cut potential |
|---------|---------|-------------|---------------|
| Opening | ~203 | 5% | Low (identity) |
| ABSOLUTE RULES | ~520 | 13% | Medium (GG model may self-enforce) |
| VOICE | ~309 | 8% | Low (character) |
| HONESTY | ~156 | 4% | Low (non-negotiable) |
| TOOLS | ~327 | 8% | Medium (per-turn instructions overlap) |
| FOLLOW-UPS | ~315 | 8% | **High** (UI convenience, 315 tokens) |

**Cheapest win: drop FOLLOW-UPS for Mini.** The follow-up chips are a UI
convenience costing 7.7% of Mini's entire context. The MLX tiers (32K+
window) keep them free. Savings: ~315 tokens → 41% more replay capacity.

**Second move: Mini-specific TOOLS section.** The per-turn tool instructions
already describe tools; the persona's TOOLS section partially overlaps. A
Mini-specific trim could save ~150 tokens.

**Third: ABSOLUTE RULES relaxation if security probe passes.** Golden Gate's
improved model may self-enforce prompt safety without the verbose completion-
attack block (~200 token savings). Gated on the security eval results.

### Parked

- [ ] ~~LanguageModelExecutor integration~~: UN-PARKED 2026-09-13. It exists
      in the 27 SDK. See the roadmap's 1.1 section.
- [ ] ~~Adapter/LoRA fine-tuning~~: `Adapter` is `obsoleted: 27.0` in the 27 SDK
      (deprecated 26.4). It stays dead.
- [ ] ~~AFM 3 Core Advanced as Big Brain~~: no evidence of this model

---

## The macOS 27 SDK, verified (2026-09-13)

Every row below was read from the Xcode-beta 27.0 (27A5194q) swiftinterfaces or
measured by a probe binary running on this Mac (macOS 27.0, 26A428, M1 Max).
Nothing here comes from blog posts.

**FoundationModels, new in 27** (`@available(macOS 27.0, *)`):

| API | What it is | Runtime evidence |
|-----|------------|------------------|
| `protocol LanguageModel` + `LanguageModelExecutor` | Any model can drive a `LanguageModelSession`. `respond(to:model:streamingInto:)` streams `Response` / `Reasoning` / `ToolCalls` events with `Usage` (input, cached, output and reasoning token counts) | `M1K3FoundationModel.swift` (ADR 0001) builds unchanged: `M1K3_FM27=1 DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build --target M1K3Agent --scratch-path .build-fm27` exits 0, and the object carries the executor witness symbols |
| `PrivateCloudComputeLanguageModel` | Apple's cloud model behind the same protocol. Exposes `availability`, `quotaUsage` (below or at the limit, with a reset date) and `contextSize` | `availability = available`, quota `belowLimit`, **`contextSize = 32768`**, capabilities vision + reasoning + tools. **A generation from an unentitled process fails** with `ModelManagerError 1046`. The shared cache names `com.apple.developer.private-cloud-compute` |
| `LanguageModelCapabilities` | `.vision`, `.guidedGeneration`, `.reasoning`, `.toolCalling` | **On-device AFM reports `.vision = true`** and `.reasoning = false` |
| `Transcript.ImageAttachment` / `Attachment` | Images in the prompt (CGImage, CIImage, CVPixelBuffer, URL) | Capability flag only. An image generation has not been probed yet |
| `ContextOptions.reasoningLevel` | `.light` / `.moderate` / `.deep` / `.custom` | Only meaningful where `.reasoning` holds, which means PCC |
| `GenerationOptions.toolCallingMode` | `.allowed` / `.required` / `.disallowed` | none yet |
| `LanguageModelError` | `.contextSizeExceeded`, `.rateLimited`, `.guardrailViolation`, `.refusal`, `.unsupportedCapability`, `.unsupportedTranscriptContent` | none yet |
| `LanguageModelSession.transcriptErrorHandlingPolicy`, `Transcript: MutableCollection`, `DynamicInstructions` / `DynamicProfile`, `CustomSegment` | Transcript editing and composable instructions | none yet |
| `contextSize` | Read the window at runtime | AFM **4096** |

**Already in 26.5 (shippable on today's Xcode 26 toolchain):** `tokenCount(for:)`
(26.4, wired) and `prewarm(promptPrefix:)`.

**New system frameworks in the 27 SDK:**

- **`_CoreSpotlight_FoundationModels`**: `SpotlightSearchTool`, a ready-made
  FoundationModels `Tool` over the user's Spotlight index (sources, content
  domains such as calendar and audio, guidance levels). This is the "Spotlight
  local-RAG tool" from the 2026-06-10 seeds, and Apple wrote it.
- **`_Vision_FoundationModels`**: `OCRTool` and `BarcodeReaderTool`, both
  `Tool`s.
- **`CoreAI`** (re-exports `CoreAIDelegates` + `CoreAIRuntime`):
  `AIModel(contentsOf:options:)`, `AIModelCache` (app-group, purge policy),
  `SpecializationOptions(preferredComputeUnitKind:)` and `InferenceFunction`
  over `NDArray`. It is a tensor runtime for compiled `.aimodel` files that can
  target the Neural Engine. It is **not** a chat model and not a
  `LanguageModel`, so it would be a fourth brain *runtime*, not a new brain.
- **`MediaIntelligence`**: face grouping plus video highlight and key-frame
  analysis. Not relevant to M1K3 today.
- The shared cache also names **`com.apple.developer.model-delegation`**. What
  it grants is unknown. Find out before assuming it has anything to do with
  executors.

**Unchanged:** AFM's window (4096), and the Adapter API (obsoleted).

**Toolchain gate:** `ci.yml` pins Xcode 26 on purpose ("Xcode 27 GA must be a
deliberate bump"), and the installed Xcode 27 is beta 27A5194q. Nothing 27-only
can ship until Xcode 27 GA arrives, CI's pin is bumped, and App Store Connect
accepts 27-SDK builds. Tomorrow's 1.0 is an Xcode 26 build running on the
macOS 27 runtime, which is the combination the release gate tests.

---

## Roadmap (1.0 → 1.1 → 1.2)

### 1.0 — Sep 14 (no new features)

Run [GOLDEN_GATE_RELEASE.md](./GOLDEN_GATE_RELEASE.md) as written. The only
code this plan lets in before 1.0 is what the release gate itself turns up.

### 1.0.x — current toolchain, small, evidence-first

1. **`prewarm(promptPrefix:)` for Mini.** It's in the 26.5 SDK (since 26.0,
   in fact). Pass the recurring prompt head (grounding header + tool block).
   Exit: the `afm prewarm` / TTFT log lines show a lower first token on turn 1
   than instructions-only prewarm, A/B on AC power.
   **Status 2026-09-14: premise corrected, early signal strong, not built.**
   Mini's ReAct body starts with `Your goal: <question>`, so today there is
   no stable prefix to pass. The tool block and RULES come after the
   question. A plain-process probe (the real Mini instructions, 1,390 tokens,
   plus a 1,357-token tool/RULES head) measured turn-1 first token at
   **7,171 ms with no prewarm, 6,689 ms with instructions-only (what ships),
   and 2,054 / 2,138 ms with the head prewarmed**, before Apple Intelligence
   went `modelNotReady` mid-run (n = 1–2 per arm). If an n ≥ 5 rerun holds,
   the move is a stable-first ReAct prompt (tools + RULES + scaffold, then
   context, then the goal) plus prefix prewarm. That's a prompt restructure,
   so it gets its own eval gate.
2. **`tokenCount` into `GroundingBudgetPolicy`** (open item above).
   **Status 2026-09-14: the grounding cap is not the binding constraint.**
   With the production 16-tool palette, Mini's fixed prompt is persona 1,409 +
   tool block/RULES/scaffold ~1.8–1.95k + grounding cap 600 ≈ **3.9k of
   4,096**, before any history or the 1,024-token answer reserve. The 09-12
   `measuredMiniBudget` reserves only the persona, so it grants ~5.8k chars of
   replay that cannot fit. Correcting the arithmetic alone leaves Mini with
   ~zero history. The real levers are a smaller Mini palette
   (`ToolPalettePolicy`), shorter tool descriptions for Mini, or 1.1's
   `toolCallingMode(.disallowed)` for small talk. That's Kev's product call.
3. **Mini persona trim.** Drop FOLLOW-UPS for Mini (~315 tokens, 7.7% of the
   window), with security ×3 on the live path as the gate (#221's rule: every
   rule stays its own span).
   **Status 2026-09-14: landed 09-12 (b7672ace) without its gate, and broke
   something.** The trimmed instructions stopped matching the provider's
   `carriesStandingPersona` check, so the ReAct floor re-sent the full
   persona and every Mini agent turn overflowed 4096 in the 1.0 candidate.
   Fixed in #320 (local build 358). The gate, run afterwards (AC, n = 3,
   `MiniLiveEvalTests`, committed under `docs/evals/2026-09-14-mini-*`):
   **trimmed security 21/21 · open-chat 22/24; full persona 21/21 · 23/24.**
   No regression beyond single-run noise (n = 3), so the trim stands. The gate
   above says "on the live path", but the app harness has always run security
   bare (`ChatEvalStage`'s bare-generate kinds), so this run did too.

### 1.1 — "Golden Gate native" (gate: Xcode 27 GA + the CI pin bump + ASC accepting 27-SDK builds)

1. **Toolchain bump PR.** CI and Xcode Cloud move to Xcode 27. The
   `M1K3_FM27` compile gate becomes `#available(macOS 27, *)` so the bridge
   ships in the normal build. The full suite runs, plus the gemma-4 native
   tool-call smoke (the dep-bump rule) and one archive through
   `release-macos.sh`. Swift 6.4 language-mode warnings get triaged, not
   ignored.
2. **Mini hygiene with typed APIs** (Mini is the brain most users hit first):
   - `toolCallingMode(.disallowed)` on small-talk turns kills #102 (small
     talk running an 8-tool loop and confabulating) at the source.
     `.required` applies when the user names a tool.
   - `LanguageModelError.rateLimited` replaces the "empty answer means the
     daemon collapsed" heuristic (memory: `pkill-poisons-afm-daemon`), and
     `.contextSizeExceeded` becomes a trim-and-retry in `HistoryBudgetPolicy`.
   - `contextSize` is read at launch instead of hardcoding
     `approximateContextTokens`.
3. **Mini sees.** On-device AFM declares `.vision`. Route dropped images and
   screenshots to Mini as `ImageAttachment`s, on-device and within the privacy
   charter. Exit: a probe answers a question about a test image. The
   capability flag alone doesn't count.
4. **Apple's tools in the palette, eval-gated.** Compare `SpotlightSearchTool`
   (the user's whole Mac, not just M1K3's corpus) with `search_knowledge`, and
   add `OCRTool`. Each one goes through `ToolPalettePolicy` and a CHATEVAL
   tool-use A/B on Mini and Lil. The palette is a prefix-cache key (#121), so
   add tools once and keep them stable.
5. **ADR 0001 goes live.** Register Lil and Big as `LanguageModel`s. The first
   payoff is Apple's `@Generable` guided generation over MLX brains, where
   `guidedGeneration` is declared only once it's real. `M1K3FoundationExecutor.userPrompt`
   drops prior turns today, so it needs multi-turn transcript handling first.

### 1.2 — The PCC rung (Phase 17b): DECIDED 2026-09-14, see ADR 0006

- **Kev's call:** PCC ships as an opt-in third rung, and the posture moves from
  "Nothing leaves" to private by design
  ([ADR 0006](./adr/0006-private-cloud-compute-rung-and-the-private-by-design-posture.md)).
  The copy sweep (32 files) ships **in the same release** as the rung, never
  before it.
- **Gate:** the `com.apple.developer.private-cloud-compute` entitlement. The
  request pack is [PCC_ENTITLEMENT_REQUEST.md](./PCC_ENTITLEMENT_REQUEST.md);
  Kev files it. The 1.2 code can be built and unit-tested before the grant,
  but the PCC generation path is verify-owed until then (1046 without it).
- **Shape:** `Escalation.privateCloud` on the existing `EscalationLadder`,
  behind `ChatEgressConsent` (default OFF). An explicit per-request escalation
  control, a label on every PCC answer, a consent sheet listing exactly what
  is sent (grounding opt-in, none by default), `quotaUsage` shown, and a local
  fallback with a sentence on `rateLimited` / `quotaLimitReached` / network
  failure. The full constraint list is in ADR 0006.
- **Does NOT need Xcode 27 GA to start:** the policy, consent and UI halves
  are toolchain-free. Only the `PrivateCloudComputeLanguageModel` adapter sits
  behind `M1K3_FM27` until the 1.1 toolchain bump.

### Later / watch

- **Core AI spike:** an `.aimodel` on the Neural Engine, e.g. the embedder or
  a tiny classifier (the small-talk gate?), not a chat brain. Worth doing once
  1.1 has shipped.
- **`model-delegation` entitlement:** find out what it grants.
- **Metal Int4 watch** (unchanged).

---

## Key numbers (measured 2026-09-12)

**Model quality (standalone eval, M1K3 persona, macOS 27.0):**
- open-chat: 8/8 · code-gen: 4/4 · humour: 4/4 · refusal: 4/4
- world-knowledge: 7/8 · security: 6/7 · reasoning: 4/6 · grounded-Q: 2/3
- **Total: 41/44 adjusted (2 false positives in scorer)**

**Token budget (exact, via `tokenCount`):**
- Real M1K3 persona (instructions): 1,466 tokens (5,920 chars)
- Generation reserve: 1,024 tokens
- Available for conversation replay: ~1,606 tokens (~5,621 chars)
- Previous conservative budget: ~857 tokens (~3,000 chars)
- **Uplift: 1.9× (corrected from 3.0× — the standalone probe used a
  compact 214-token test persona, not the real M1K3 persona)**

**Latency (AC/High Power, clean daemon):**
- World knowledge: 0.5–0.9s
- Security refusal: 0.7–1.0s
- Code generation: 1.1–1.4s
- Reasoning: 0.7–3.1s
- Open chat: 0.8–1.2s (clean) / 8.6–12.5s (rate-collapsed)

**chars/token ratio (measured, not estimated):**
- Structured content (personas, tools): 3.1–3.2
- Prose prompts: 4.1–4.7
- Conversational replay: ~5.7
- Standing heuristic (code): 3.5 ← reasonable for code, conservative for prose

<!-- Review: Kev + claude-opus-5, 2026-09-14: 1.2 marked DECIDED (ADR 0006,
     Kev's call); the policy, consent and UI halves are noted as toolchain-free.
     Confidence now 0.85. -->
<!-- Review: Kev + claude-opus-5, 2026-09-14 (later): the three 1.0.x items got
     their evidence. The persona trim passed its gate after the fact, and its
     #320 regression is fixed. The grounding budget is not the binding
     constraint (the 16-tool palette is, Kev's call). The prewarm premise is
     corrected, with a strong but n=1–2 prefix signal. Confidence 0.8 (the
     prewarm numbers need an n≥5 rerun). -->

<!-- Signed: Kev + claude-opus-5, 2026-09-13. The 27-SDK correction +
     the 1.0 → 1.2 roadmap. Confidence 0.85: every API row comes from the
     27A5194q swiftinterfaces or a probe binary run on macOS 27.0 (26A428),
     and the FM27 bridge build was checked by object symbols, not exit code.
     Open: Mini vision and PCC-with-entitlement are unprobed, and what
     model-delegation grants is unknown. Prior: Unknown (the 09-12 sections
     are unsigned). -->
