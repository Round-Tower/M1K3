# M1K3 — Roadmap

This is the living "what's next" doc — kept current, not append-only. For
architecture/build/test, see `CLAUDE.md`. For *why* a decision was made (model
swaps, phase rationale, the full session-by-session build log), see `PLAN.md` —
it's a signed historical record and stays that way; this file doesn't repeat it.

Last swept: 2026-07-19, against `.claude/project-memory.md`, `PLAN.md`, open
PRs/issues, and the current branch.

---

## Now

- **`fix/vision-review-nits` (current branch, uncommitted):** `ContentView.swift`
  bottom-chrome refactor to a `safeAreaInset` (so the transcript scrolls under
  the bar, matching the toolbar's material) + a top scrim overlay, plus a
  `ChatSession+Conversations.swift` fix — review nits off PR #62. Finish + commit.
- **Verify-owed: PR #62 (vision)** — Big now sees via `VLMModelFactory` +
  image-attachment chat. Commit message names a "live-path CHATEVAL A/B gate
  running on-device" — read that back before calling vision done.
- **MTP speculative-decoding spike (#61) — PARKED, no action.** `Gemma4Unified`
  is missing the MTP-aware cache override upstream (confirmed absent on
  `mlx-swift-lm` `main`). Re-check only on the next `mlx-swift-lm` bump.

---

## Next — the two flagship initiatives

Both are past the spike stage — architecture and feasibility are proven, what's
left is building.

### 1. Voice on iOS + the Vision Pro flagship
Spike scaffolding, results, and Kev's open calls: `scratch/voice-mobile/PLAN-DRAFT.md`.

- **Shipped:** K0 (MLX-Kokoro feasibility) ✅ · K1 (on-device A/B, Kev's ear
  passed it) ✅ → **#58 merged** (Kokoro's ONNX backend replaced with pure MLX —
  the visionOS unlock) · V0 (visionOS sim spike) ✅ → its dark-avatar finding
  fixed in **#60** (camera-less `GeometryReader3D` framing — visionOS's eyes
  *are* the camera).
- **V0's tab-ornament finding: CLOSED BY REMOVAL** (PR #82, 2026-07-29) — the
  mobile nav restructure retired the tab shell entirely (chat is the app;
  Memories/Documents/Settings are pushes), so the dark-squares ornament and its
  planned `.sidebarAdaptable` fix no longer exist.
- **Scoping resolved by the same restructure:** "voice-forward, not voice-only"
  — voice is a full-screen cover over the retained chat shell (setup/downloads/
  TCC/consent stay visual), shipped as v1 in #82. Remaining Phase B/D work:
  - **Phase B (iOS voice):** B-A1 AVAudioSession echo spike (incl. interruption/
    route negative paths — this is genuinely unbuilt today, zero hits repo-wide)
    → B-1 STT + karaoke captions, push-to-talk → B-2 Kokoro-vs-AVSpeech decided
    on *measured* iOS thermals, not vibes → B-3 voice-mode UI composing the
    Mac's existing pieces.
  - **Phase D (visionOS flagship):** voice-forward view over the retained shell,
    volumetric avatar, TTS per Phase B's pick.
- **Landmines already named** (don't rediscover — see PLAN-DRAFT.md): self-echo
  (no AEC anywhere — v1 is push-to-talk); Apple Speech's silent server-fallback
  is a privacy landmine on a listening surface (assert on-device, fail loud);
  thermals need a measured 10-minute burn, not a demo.

### 2. Brain-at-home
Spec, security audit, and Kev's open calls: `scratch/brain-at-home/SPEC.md`.

- **Spec complete + security-hardened:** phone uses the Mac as a pure
  `InferenceProvider` over a *new*, default-OFF TLS-PSK listener — the MCP
  server's loopback pin is never touched, tool calls are answered phone-side
  only (never re-opens the corpus over LAN), QR-carried 32-byte PSK for mutual
  auth. 12 security findings, 4 blocking, all folded into the spec.
- **Blocked on Kev's §8 calls:** naming, serving indicator, thermal etiquette,
  visionOS timing.
- **Then Phase A spikes:** TLS-PSK echo (incl. negative paths + an
  unreachable-relay case), SSE streaming client (repo has zero streaming-HTTP
  client code today — a real spike), dnssd/NWBrowser round-trip. Prior-art
  reference: `gemba`'s `BonjourBrowser.swift` — but its "same LAN = trusted,
  no auth" model is the anti-pattern to avoid, not copy.

---

## Then

- **Knows-me LoRA — data pass.** The voice LoRA trained clean but was PARKED:
  2 of 4 pre-registered gates failed (a softened security refusal; a confident
  factual confabulation — the exact "sounds right, is wrong" trap the
  honest_uncertainty examples were meant to prevent). The fix is DATA, not
  knobs: audit `anti_injection` seeds for any conditional refusal, rebalance
  world_fact vs uncertainty examples, target the confident-precision failure
  mode specifically. Then retrain → A/B against the kept iter-100 checkpoint →
  run the Swift CHATEVAL `security` regression suite (never reached in the
  parked run — it's the rigorous gate this needs before it's a real candidate).
- **Age-gating follow-up PR.** #31 shipped only the pure `AgeBand`/
  `AgeAppropriateness` policy core. The `DeclaredAgeRange` request flow +
  entitlement + persona-clause injection + web-tool gate wiring was deliberately
  held until Beta App Review cleared — **it has (2026-07-18)** — so this is
  unblocked. Re-verify the Declared Age Range API specifics against current
  Apple docs before building (named low-confidence in PLAN.md item 19 — macOS
  availability / band granularity / decline semantics all need a fresh check).
- **Phase 17b — PCC network rung.** Prerequisite (Phase 17a, the dedicated
  chat-egress consent key, separate from the web-search toggle) is confirmed
  **shipped** (`ChatEgressConsent.networkAllowed`, default-OFF, its own key,
  tested). What's left — the `PrivateCloudComputeLanguageModel` executor lane +
  the calm opt-in consent UX + the escalation control — is genuinely gated on
  a **macOS 27 runtime**, not just the SDK, so it can't start until that beta
  lands (~autumn, per the WWDC26 wave). Nothing to do here yet but watch for it.
- **Memory distiller-quality eval.** Traced from an old "Phase 3 memory" item —
  turns out most of it (consolidation/recency/contradiction) already shipped via
  the temporal memory graph's supersession mechanism (`MemoryStore.supersededBy`
  + `MemoryGraphEval` scoring recall-after-correction) and was just never
  checked off. What's genuinely still open: an AFM-judge eval scoring whether
  the auto-`MemoryDistillationCoordinator` extracts good facts from chat (no
  fixtures exist in `M1K3Eval` for this yet), and confirming `user.profile`
  facts vs `.memory`-graph profile facts don't collide (the distiller extracts
  profile-grade facts into both stores — unverified whether that's handled).

---

## Backlog (smaller, pick off anytime)

- **Per-embedder relevance floors (the "hashing/iOS floors" gap).**
  `GroundingGate`'s citation/memory/KEYEVAL thresholds were all measured
  against the MLX/Qwen3 embedder. `HashingEmbeddingService` — Mac's offline
  fallback, and **the only embedder iOS/visionOS has** — shares those same
  numbers unmeasured; its bag-of-words cosine distribution isn't remotely the
  same shape. Documented as a caveat in `GroundingGate`'s own header, upgrade
  path named there (per-embedder floors / a hashing-arm KEYEVAL run) but never
  executed. Matters more now than when it was first logged — iOS actually ships.

- **Spotlight `.memory` donation** — deliberately excluded from #29 on privacy
  grounds (a distilled fact's title *is* its body, so title-only donation is no
  mitigation). Needs 3 lifecycle hooks (supersede-deindex, forget-revive-re-donate,
  tag-UI-deindex), each red-first.
- **Companion-avatar visionOS camera fix** — `CompanionAvatarView` needs the
  same camera-less `GeometryReader3D` pattern #60 applied to the main `AvatarView`.
- **White-pane Code-tab render check** — long-open: the offscreen render probe
  (`scratchpad/preview-snapshot.swift`) renders a persisted artifact correctly
  (dark, styled) but Kev saw it white/unstyled in-app. Probe-clean, app-divergent,
  cause unknown. Kev's Code-tab check (splits app-artifact vs app-render
  divergence) is still owed.
- **PREFIXWARM re-measurement** — stale since both the Lil (2507) and Big (12B)
  tier reshuffles; the cached warm-latency figures predate the current brains.
- **`.builtin` voice-tier copy** — "macOS's built-in speech" string, logged as
  a Phase B (iOS voice) item, not yet touched.
- **Issue #46** — refusal-marker ledger: denial-decline phrasings the scorer
  misses. Grows one entry per new brain bake-off; low-effort, pick up opportunistically.
- **`graphify-out/` rebuild** — stale since 2026-06-14, predates the entire
  iOS/visionOS shell and the memory-bridge modules. Run the `graphify` skill's
  update when doing broad-architecture work would benefit from it.

---

## Watching / blocked upstream

- **MTP speculative decoding for Big** — parked on `Gemma4Unified` missing the
  MTP-aware `callAsFunction(_:cache:state:)` override in `mlx-swift-lm`
  (confirmed absent on `main`, 2026-07-19). Instrument (`M1K3_SELFTEST_MTP`) is
  ready — re-run on the next dep bump.
- **OptiQ mixed-precision quantization** — parked, no Swift loader exists for
  the format (targets Python `mlx-lm` only). Re-check if upstream adds one.

---

## Needs Kev — open calls, gathered in one place

- Voice-mobile call #1 (scoping confirm, above) unblocks Phase B.
- Brain-at-home §8 calls (naming, serving indicator, thermal etiquette,
  visionOS timing) unblock Phase A.

---

<!-- Signed: Kev + claude-sonnet-5, 2026-07-19, Confidence 0.9 (synthesized from
     a full read of CLAUDE.md + all 811 lines of PLAN.md + the last ~15
     project-memory.md session blocks + scratch/voice-mobile + scratch/brain-at-home
     + live git/gh state; Phase 17a's shipped status verified directly against
     ChatEgressConsent.swift source, not assumed from the plan text. The two
     items originally flagged as too-thin-to-judge ("hashing/iOS floors" and the
     pre-06-13 Phase 3 memory item) were traced back through the archived memory
     files and cross-checked against MemoryStore.swift/MemoryGraphEval.swift/
     GroundingGate — one is real un-fixed debt (hashing floors, moved to
     Backlog), one was mostly already shipped via supersession (dropped) with a
     genuinely-open remainder (distiller-quality eval, moved to Then). Prior:
     Kev + claude-sonnet-5 (this file, first pass).-->
