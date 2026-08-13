# M1K3 — Roadmap

This is the living "what's next" doc — kept current, not append-only. For
architecture/build/test, see `CLAUDE.md`. For *why* a decision was made (model
swaps, phase rationale, the full session-by-session build log), see `PLAN.md` —
it's a signed historical record and stays that way; this file doesn't repeat it.

Last swept: 2026-08-03 (evening) — MERGE DAY, board back to empty. Six PRs
landed: **#95** dream-cycle truth-up + `docs/DESIGN_DOCTRINE.md` · **#96**
reduction wave 3 (deadwood) · **#97→#98** the identity/citation leak · **#99**
a markdown table could seize the window's width (#79 lead) · **#100** the MCP
`FOLLOWUPS` trailer · **#101** the Mini prompt budget. Master verified
**2359 tests / 336 suites green + Mac shell builds**. Dead remote branches
cleared (that `git push origin --delete` is NOT classifier-blocked after all —
the earlier note was wrong). Xcode Cloud fires on the six merge pushes,
unwatched.

Earlier the same day: the PROJECT DREAM CYCLE — a Tier-0/1/2 pass over the app,
brand, and docs themselves (3 scouts + the resident's corpus + a reduction
pass). Verdict and principles live in `docs/DESIGN_DOCTRINE.md`.

---

## Now

- **★ Voice latency: measured, and the intuition was wrong — 2026-08-13.** The
  voice loop had never been instrumented end-to-end. Per-generation `ttft` lines
  existed (prefill ms, decode tok/s) but a voice turn is retrieval + a grounding
  cap + an agent loop + a synthesiser, so nothing answered *how long after Kev
  stopped talking did M1K3 start talking back*. `VoiceTurnTimeline` now logs
  exactly that, per turn, on both shells:
  `voice turn: first sentence Xms · synth Yms · first audio Zms · answer Wms · N sentences`.
  **Measured live over MCP** (Lil resident, persona prefix warm, Kev's own store):

  | prompt | prefill | decode |
  |---|---|---|
  | 822 tok | 2052 ms | 84 tok @ 63 tok/s |
  | 1401 tok | 3045 ms | 175 tok @ 61 tok/s |

  Marginal cost is **1.71 ms per prompt token** on a ~646 ms fixed floor.
  ★ **Prefill dominates time-to-first-audio and decode barely registers** —
  voice speaks at the first SENTENCE (~15 tokens, ~250 ms of decode) while
  prefill is paid in full before any token exists. So the lever is FEWER PROMPT
  TOKENS, not faster decoding, which demotes speculative decoding from "the
  obvious next win" to a full-answer-time optimisation (see below).
  Shipped off that: `GroundingBudgetPolicy.spokenTokenBudget = 400` (from 1100)
  — ~1.2 s off every spoken turn, and justified twice over, because nobody reads
  seven document chunks aloud. The iOS shell had **no grounding budget provider
  at all**, so PR #101's Mini sizing never crossed to mobile; it does now.
  Kokoro's `preload()` also now runs one throwaway forward pass — it loaded the
  weights but left the Metal graph to compile on the user's first real sentence.

- **⚠️ The tool palette is a KV-cache key — changing it per mode costs seconds.**
  Measured the same day: a self-query turn ("Who are you?") withholds four corpus
  tools, which is a different `PersonaPrefixCache` key, which is a **6.2 s prefix
  rebuild** — and `PersonaPrefixCache.defaultCapacity` is 2 while three real
  palettes now exist (interactive, headless, self-query), so they evict each
  other. This is the 2026-08-09 stampede class, reopened by a third palette.
  Filed rather than fixed: raising capacity wants the measured RAM snapshot the
  file's own header demands. **Standing consequence: tune the grounding, never
  the palette** — which is a second, stronger reason for the existing
  "cut iterations, not tools" ruling. Full write-up, including the TTS-upgrade
  and background-conversation answers: `docs/VOICE_PERFORMANCE.md` (issue #121).


- **Retrieval, the warm palette, and the model's own thinking in the corpus —
  2026-08-12, found by driving the live app over MCP.** Four things, all
  measured on Kev's real store rather than reasoned about:
  ① **Recall ranked by the wrong number.** `MemoryStore.recall` gated on cosine,
  PRINTED cosine, and ORDERED by RRF — so "what does Kev do for work" put a 60%
  row above the 71% row that answered it, and "where does Kev live" put "Kev is
  using a Mac" above three Cork rows. Read as a floor problem since 2026-08-09;
  it was an ordering problem. Now ranked by similarity, with ONE guaranteed seat
  kept for the keyword lane so a rare token (a surname) can't be ranked off the
  page — the shape a challenger pass insisted on, and the tell that it's right is
  that the 2026-07-02 Golden Gate regression test passes unmodified.
  ② **The grounding head now hedges — and it is NOT enough (re-measured live).**
  Asked what he had for dinner on 3 March, M1K3 retrieved a fragment of a stored
  SCREENPLAY and narrated it before correctly saying it didn't know. The hedge
  shipped; the same question on the fixed build **still narrates the
  pomegranate**. A prompt nudge does not stop a 4B model describing what is in
  front of it. ⚠️ **And the obvious lever is measured DEAD:** with the new gate
  instrument, best-hit cosine per query on Kev's real store —
  answerable 0.497 (Cartogram) / 0.715 (Brightbeam) / 0.725 (the script itself);
  no-answer 0.361 (Ulaanbaatar) / 0.489 (dream) / nothing retrieved (dentist);
  dinner-on-3-March 0.477 with 7 of 10 chunks kept. **The bands touch: 0.497 vs
  0.489, a gap of 0.008.** Any abstain threshold that suppresses the dinner
  grounding also kills the Cartogram answer — the same shape as the 2026-07-30
  dream-cycle result where contradiction and restatement overlapped and no cosine
  bar separated them. So: no threshold, and the next idea must not be one.
  Candidates that survive the measurement: rank-aware injection (inject the
  best 2, not the best 7 — the dinner turn kept SEVEN chunks about nothing),
  or a cheap answerability judgement that is not a similarity number.
  ③ **The pre-warm warmed a phantom.** It built a 9-tool palette no call site
  ever asks for (it passed `onOpenLink` but not `deepDelegation`, while live chat
  passes both), so the ~2.1s prefix build was paid at launch AND on the first
  chat turn AND on the first agent ask. Now warms both real palettes; the
  heartbeat render is marked background so it can't take a slot either.
  ④ **`ThinkStripper` knew one dialect out of two.** The resident summariser has
  been gemma-4 since July and speaks `<|channel>thought`; the stripper only knew
  `<think>`. A call summary from 2 July was the model's raw reasoning, stored and
  retrievable for six weeks. One token table now (`ReasoningSplit`, lifted into
  M1K3Inference), plus `ModelThinkingQuarantine` — a startup sweep in the shape
  of `SelfWiringQuarantine`, because a fixed generator does not un-store a stored
  row. ⚠️ **Accepted cost, named because it is real on Kev's Mac:** quarantine is
  per ITEM, so the 2 July call lost its (perfectly good) TRANSCRIPT from
  retrieval along with its poisoned summary. That follows the SelfWiringQuarantine
  precedent and `.quarantined` is a kind, not a delete — nothing is destroyed, and
  the row is still in Documents. Worth revisiting only if chunk-level quarantine
  ever earns its complexity.
  **Instrument added, deliberately ahead of any threshold move:** the grounding
  gate's per-hit line is `.notice` now, so the next person can read what a wrong
  hit actually SCORED instead of inferring it. No floor constant was touched —
  the floors were derived against fixture sets containing only cross-domain
  negatives (there is not one near-domain negative in them), which is exactly the
  shape that fails here. Measure first.


- **Voice-mode feel — PR open 2026-08-11 (Kev's ⌘R owed).** Three live
  complaints, three fixes. ① The endpointer now LEARNS the speaker's pause
  instead of taking a third guess at one number, and both shells share
  `EndpointCadence.conversational` (they had drifted: 2.0/4.5/30 vs 2.0/3.5/20,
  from the same complaint). ② Apple's voice processing is on our mic path —
  echo cancellation + speech-triggered ducking, so music gets out of the way
  mid-sentence instead of competing. ③ A one-time realignment moves a persisted
  Big to Lil, because #117's Lil-fronts default only ever reached machines with
  no pick — Kev's own Mac woke on Big the next morning.
  **The open question is ②'s cost:** voice mode now prefers Apple Speech over
  WhisperKit, because WhisperKit's `AVAudioEngine` is built inside the package
  (`setupEngine`/`processBuffer` internal — verified) so echo cancellation cannot
  be reached from out here. That trades word accuracy for a clean channel;
  Settings → Voice mode flips it. If the transcription feel is worse, the named
  alternatives are an upstream WhisperKit `voiceProcessing` option, or ducking the
  system output device ourselves via CoreAudio while the mic is hot.
  **④ Stop now actually stops (2026-08-12, found by Kev's ear).** A `stop()`
  landing during the SILENT offline-synthesis window relied entirely on
  `stopSpeaking(at: .immediate)` cancelling that render — and under load it
  doesn't: measured, a stop 900ms in took 6.1s to unwind because the render
  finished and then played the whole utterance. Every piece of bookkeeping was
  correct throughout (one ended event, `isSpeaking` false), which is why no test
  caught it and why the test named "returns promptly" passed without ever
  asserting promptness. A render now carries the stop epoch it was claimed in and
  drops its audio if a stop landed since — covering both the synthesis window and
  a render still queued behind the gate. This is barge-in on a long answer: the
  window is exactly as long as M1K3 takes to synthesise.
- **The Heartbeat — v1 shipped 2026-08-06 (default OFF, Kev's calls owed).**
  The 2-hourly narrative pulse: deterministic digest + resident-MLX
  retelling, popover line + Settings surface. `docs/HEARTBEAT_DESIGN.md`
  carries the challenger record and the open ruling — the activity-log vs
  prove-nothing-kept double-bind (default/cap/history-length) and the
  "heartbeat" noun. ⌘R verify-owed: toggle on, live with it an afternoon,
  A/B the Big vs Lil narrative before defaulting on.
- **iOS voice-mode crash triage (#85).** Code-inspection pass done (2026-07-31,
  findings on the issue): the voice session layer is clean; ranked suspects
  are ① jetsam memory-limit exit (fits "no `.ips`" — check for `JetsamEvent`
  files, not just crash logs), ② watchdog via the synchronous
  AVAudioSession activate/deactivate on the main actor, ③ the mic-tap
  realtime-thread lock (bench item #4). **The discriminator is live:** #88's
  `MXAppExitMetric` names the exit reason on the next repro. Cheap hardening
  available regardless: make the session activate/deactivate non-blocking.
- **Phase B — iOS voice, for real.** With #82's shell shipped and #85
  instrumented, the B-A1 AVAudioSession echo spike is next — and it maps the
  same territory as suspect ② above, so run the spike WITH the crash as
  fixture one. Then B-1 STT/captions → B-2 Kokoro-vs-AVSpeech on measured
  thermals → B-3 the composed voice-mode UI.
- **Dream-cycle Tier-2 soak.** Shipped in #87 (write-time repair: corrections
  supersede, never eaten — acceptance gate 3/10 → 0/10 on-device). Watch real
  distillation traffic; the Tier-3 decision (one-shot Δ202 backfill vs nightly
  dream) is a re-measure after the soak, not a build. The ride-along landed:
  PR #94 gives corrected facts a list-level lens in MemoriesView (2026-08-01),
  so the soak is now eyeball-able, not log-only.
- **★ Mini's turn shape (#102) — the one that governs how M1K3 FEELS on the
  default brain.** Found by interviewing Mini over MCP (#101 fixed the two
  prompting bugs that interview surfaced: the grounding cap failing open on
  the 4096-token tier, and `PromptContext` telling M1K3 its name was "Mini").
  What's left is architecture, not persona. Small talk runs full retrieval,
  ~4.7 KB of grounding, all 8 tools and 3 agent iterations on a ~3B model with
  half a context window — so "Long day, I'm wrecked" came back with retrieved
  *rave-website documents*, and "tell me something interesting" **invented a
  weather forecast**. The clincher: with retrieval skipped and tools halved by
  the self-query gate, Mini **still burned its full iteration cap**. So the
  question isn't only "should this turn retrieve?" but "should this brain be
  running an agent loop at all for this turn?". ⚠️ The obvious fix (a
  small-talk gate) is close to the pre-generation intent router **rejected
  2026-06-12 as "brittle both ways"** — wants a `challenger` pass before code.
  Lean: tier-aware prompting, scaling the scaffold to what the brain can carry.
  **Also measured and rejected:** giving Mini the `voiceExemplars` (cost is not
  the reason they're withheld — they're only 187 tokens; the reason is a ~3B
  model *parrots* them as content). Evidence lives in
  `AppleFoundationModelsProvider`'s header; harness (`interview.sh`, paced 30s)
  in the session scratchpad. **Pace any AFM verify loop ~30s** — rapid turns
  exhaust `ModelManagerServices` and every answer degrades to the empty floor.
- **The reduction wave (project dream cycle, 2026-08-03).** Doctrine:
  `docs/DESIGN_DOCTRINE.md`. The measured duplication table (progress ×9,
  change-brain ×5, record-consent ×3-dialects, avatar-display ×2 identical)
  becomes staged cuts, each its own small PR, doctrine-tested:
  1. **Show-a-state-once** — model-load progress 9 → 2 (canonical + menu bar).
  2. **One promise** — a single record-call consent component; one entry point
     in Calls + the menu-bar toggle.
  3. ~~**Vocabulary collapse**~~ — **DONE, #96** (2026-08-03): the unshipped
     "LiteRT" label, the raw-enum a11y string, the wrong Agent-Log→Settings
     pointer and the dead `hasChosenVoiceKey` are all gone.
  4. **The debug door** — Advanced pane gutted to Diagnostics + Licenses;
     Embeddings/Import-weights/Status/Generation-stats behind a hidden debug
     surface; SelfTest + eval stages out of the release binary.
  5. **One thinking control** — merge General→Reasoning with voice-mode's own
     (today one explicitly ignores the other).
  6. **"Left this Mac"** — the thesis, rendered: Memory screen gains a
     permanently-empty egress list that the MCP log fills only when the port
     is on. Absorbs the Agent Log window + half the Privacy pane. Proof, not
     copy — and the site's next screenshot.

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
- **Memory distiller-quality eval.** Narrowed again by the dream-cycle work
  (Tiers 0/1 shipped 2026-07-30; MEMSTAT now measures the ingest path
  end-to-end). Still genuinely open: an AFM-judge eval scoring whether
  `MemoryDistillationCoordinator` extracts good facts from chat (no fixtures
  in `M1K3Eval` yet), and the `user.profile` vs `.memory`-graph collision
  check.
- **Golden Gate wave (macOS 27, ~Sept GA).** The standing play: ship the
  LanguageModel/PCC capability at GA (Phase 17b below is the runtime-gated
  half); Xcode 27 beta can be installed beside stable NOW (host req is
  macOS 26.4+, already met) to start on the SDK surface without touching the
  daily-driver OS. Demo/screenshot content shoots while the beta bakes.

---

## Backlog (smaller, pick off anytime)

- **Per-embedder relevance floors — DONE, PR #89 (2026-07-31).** Measured
  (deterministic hashing arm over the same MEMEVAL/ABSEP fixtures, now a
  standing CI instrument): the shared bars kept 6/22 true memory recalls on
  iOS. `EmbedderFloors` selects by fingerprint at every gate call site.
  Remaining tail: Tier-2's ≥0.90 supersede bar is still qwen-derived (fails
  safe on hashing — two live dated rows), and the mobile felt-feel pass is
  Kev's.

- **Spotlight `.memory` donation** — deliberately excluded from #29 on privacy
  grounds (a distilled fact's title *is* its body, so title-only donation is no
  mitigation). Needs 3 lifecycle hooks (supersede-deindex, forget-revive-re-donate,
  tag-UI-deindex), each red-first.
- **Companion-avatar visionOS camera fix — DONE, PR #91 (2026-07-31):** the
  #60 camera-less pattern applied via a new shared pure `WindowFit`;
  real-headset look verify-owed.
- **White-pane Code-tab render check** — long-open: the offscreen render probe
  (`scratchpad/preview-snapshot.swift`) renders a persisted artifact correctly
  (dark, styled) but Kev saw it white/unstyled in-app. Probe-clean, app-divergent,
  cause unknown. Kev's Code-tab check (splits app-artifact vs app-render
  divergence) is still owed.
- **PREFIXWARM re-measurement — DONE (2026-07-31):** lil 2.1s / big 8.5s
  (evidence `scratch/eval-2026-07-31-prefixwarm/`); the stale AppEnvironment
  comment truthed up in PR #92. The 12B launch warm is ~2.6× more load-bearing
  than the old figure suggested — background it stays.
- **`.builtin` voice-tier copy — DONE, PR #90 (2026-07-31):** platform-honest
  `#if` split, macOS bytes frozen; live once a mobile voice-tier picker exists.
- **Issue #46** — refusal-marker ledger: denial-decline phrasings the scorer
  misses. Grows one entry per new brain bake-off; low-effort, pick up opportunistically.
- **`graphify-out/` rebuild** — stale since 2026-06-14, predates the entire
  iOS/visionOS shell and the memory-bridge modules. Run the `graphify` skill's
  update when doing broad-architecture work would benefit from it.

---

## Watching / blocked upstream

- **MTP speculative decoding for Big** — **re-measured 2026-08-08 on the
  MTP-capable pin; still parked, new reason.** Upstream #415 fixed engagement
  (52% accept on a short prompt, was 0), but gemma-4-12B's sliding window is
  1024 tokens and our production prompt is 1863–2998 — every real turn is in
  the wrapped regime, where MTP runs at **0.79–0.87× baseline** and one fixture
  **diverges** despite #506's stand-down. Unparks only if our prompt fits 1024
  (a #102-shaped project) or upstream makes the wrapped regime faithful *and*
  engaging. Numbers: `scratch/mtp-spike/RESULTS-2026-08-08-rerun.md`.
- **OptiQ mixed-precision quantization** — parked. Upstream now *loads* the
  format but **generates garbage** (mlx-swift-lm issue #450, open) — worse than
  the June "no loader" state. Re-check when #450 closes; the OptiQ repo is
  incidentally the only 12B quant carrying Google's fixed chat template, which
  M1K3 now vendors directly instead (`Gemma4TemplateFix`).
- **`gemma-4-12B-it-4bit` chat template upstream** — M1K3 no longer waits:
  the canonical 2026-07-09 template is vendored and installed over the stale
  bytes at load. If mlx-community ever re-quantizes, the fix becomes a no-op by
  construction (hash-gated) — but the pinned manifest hash must then be
  re-checked against whatever they ship.

---

## Needs Kev — open calls, gathered in one place

- Brain-at-home §8 calls (naming, serving indicator, thermal etiquette,
  visionOS timing) unblock Phase A.
- Dream-cycle Tier-2 corpus-twin marker: sub-kind vs title-prefix (spec §5
  recommends sub-kind).
- App icon: Kev wants the liquid-glass mark swapped for a plain M — his eye,
  his edit (Icon Composer; the visionOS `.solidimagestack` follows).
- Store presence pass (screenshots, per-platform captures, site cross-links) —
  parked deliberately; the website content is strong, timing is the question.
  (Voice-mobile scoping call #1 was RESOLVED by #82's nav restructure — see
  the flagship section above.)
- **Dream-cycle brand calls (2026-08-03, doctrine recommends, Kev ratifies):**
  - **Mike: kill or commit.** Doctrine + the resident's own testimony say kill
    (one name; the leetspeak is the joke). Touch-points if killed: the
    Hear-a-sample line (`AppEnvironment.swift:2048` — proposed replacement:
    "I'm M1K3. I live on this Mac. Nothing you tell me leaves it."), Android's
    drawer "Call me Mike" + `M1K3 (Mike)` prompt.
  - **App Store noun:** description says "assistant", everything else says
    "companion"; the launch-package doc argued the store exception. Doctrine
    says companion everywhere, "assistant" as keyword only.
  - **Labyrinth icon family → attic** (complete unused second identity in
    `assets/app-icon/` + `assets/icons/labyrinth/`).
  - **OG image regen** — pixel face as the hero on all pages (Fox stays on
    companions.html only); `assets/brand/readme-hero.png` (07-02) + `site/og.png`
    (06-13) both predate the current product.
  - **Reading-modes ceremony** — keep all four (protected), but ask once at
    onboarding instead of a Settings-only picker.
- **"Machine", not "Mac", in M1K3's own voice — RATIFIED by Kev 2026-08-03**
  (*"M1K3 is a mechanic after all"*). Doctrine principle 3 carries the split:
  M1K3's first-person copy says *machine*; product/store/site chrome and any
  sentence about Apple's own layer ("Your Mac is blocking the mic → System
  Settings") stay *Mac*. **Not a hot edit** — the seam is
  `HostPlatform.noun` (one line), but `HostPlatformTests` pins the macOS arm
  byte-identical *because* the gemma persona is A/B-frozen and prompt-fragile.
  The pass: flip the noun → re-pin the tests → A/B both brains → sweep the
  ~6 first-person UI strings (`ContentView` 1185/1264/1272, `GreetingCard`,
  the Hear-a-sample line if Mike is killed in the same pass).

---

<!-- Review: Kev + claude-fable-5, 2026-08-03 — the project dream cycle:
     header truth-up, the reduction wave added to Now (6 staged cuts off the
     measured duplication table), dream-cycle brand calls gathered under
     Needs Kev, DESIGN_DOCTRINE.md referenced as the standing test. Confidence
     0.85 (duplication counts from a very-thorough repo scout, spot-verified;
     the staged cuts are proposals sized from those counts, not yet built). -->
<!-- Review: Kev + claude-fable-5, 2026-08-01 — housekeeping-day sweep: header
     truth-up (branch prune + the #93 rescue + #94 lens), Tier-2 soak bullet
     gains its #94 ride-along, PREFIXWARM moved to DONE with the 07-31
     numbers. Confidence 0.9 (every claim verified against live git/gh state
     this session). -->
<!-- Review: Kev + claude-fable-5, 2026-07-31 — post-merge sweep: #87/#88
     ticked off Now (merged + verified 2288/331); Now refilled with the voice
     spine (#85 findings→Phase B as one thread) + the Tier-2 soak; hashing
     floors + .builtin copy + companion camera moved to DONE with their PR
     numbers (#89/#90/#91, all green awaiting Kev).
     Confidence 0.9 (swept against live gh/git state same-session). -->
<!-- Review: Kev + claude-fable-5, 2026-07-30 — merge-day sweep: Now section
     rebuilt (stale #62-era items ticked off; voice-crash #85 + dream-cycle
     Tier 2 + MetricKit #86 are the focus), V0 tab finding closed-by-removal,
     voice scoping resolved-by-#82, Golden Gate wave named with the
     install-beta-beside-stable unlock, Kev's icon + store-presence calls
     captured. Confidence 0.85 (swept against merged PRs + issues + the
     MEMSTAT/MEMBLOCK evidence; reduction reflects Kev's realign directive). -->
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
