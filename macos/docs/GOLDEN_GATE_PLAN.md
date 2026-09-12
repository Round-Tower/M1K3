# Golden Gate (macOS 27) — Plan & Progress

Spike date: 2026-09-12. Public release: Sep 14.
Probed on: macOS 27.0 (Build 26A428), Xcode 26.6, SDK 26.5.
Build status: 3,700 tests green, zero code changes needed.

---

## What shipped (verified)

| Claim | Status | Evidence |
|-------|--------|----------|
| Model quality uplift | **CONFIRMED** | 41/44 eval (93%), 6/7 security (was 0/14), persona adherence crisp |
| Token counting API | **CONFIRMED** | `tokenCount(for:)` on prompts, instructions, tools, schemas — exact |
| Context window expanded | **NOT TRUE** | Still 4096 tokens (back-deployed getter, runtime-confirmed) |
| LanguageModelExecutor protocol | **DOES NOT EXIST** | Full swiftinterface read — no custom executor surface |
| Adapter API (LoRA) | **KILLED** | "Custom adapters are no longer supported since iOS 27, macOS 27, visionOS 27" |
| AFM 3 Core Advanced (20B sparse) | **NO EVIDENCE** | Asset names still reference `instruct_3b`; no API change |
| Metal Int4/UInt4 tensors | **CONFIRMED** | `MTLTensorDataTypeInt4/UInt4` at macOS 26.4 — upstream mlx-swift concern |

## Plan

### Done

- [x] Build green on Golden Gate (3,700 tests, Release compiles)
- [x] SDK swiftinterface fully read — no LanguageModelExecutor, Adapter dead
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

- [ ] ~~LanguageModelExecutor integration~~ — does not exist in the SDK
- [ ] ~~Adapter/LoRA fine-tuning~~ — API removed on macOS 27
- [ ] ~~AFM 3 Core Advanced as Big Brain~~ — no evidence of this model

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
