# M1K3 — Roadmap

This is the living "what's next" doc — kept current, not append-only. For
architecture/build/test, see `CLAUDE.md`. For *why* a decision was made (model
swaps, phase rationale, the full session-by-session build log), see `PLAN.md` —
it's a signed historical record and stays that way; this file doesn't repeat it.

Last swept: 2026-09-02 — the **iOS TestFlight lane** opened (mobile bundle
IDs unified onto the universal `app.m1k3` record, privacy manifest +
entitlements + Bonjour key on the mobile targets, a CI guard pinning them) and
the **iOS parity ladder** written down — flagship §1. Before that —

2026-08-20 — the **M brand mark** shipped (PR #142; app icon
reduced from the M1K3 wordmark to the single pixel-M, both platforms) and the
**live wallpaper** greenlit as the Golden Gate flagship (Kev: *"the live
wallpaper definitely is next — do whatever you need to deliver it"*); prior art
found in Cartogram-Mac's `Wallpaper/` module (in-app `DesktopWindow` at desktop
level, occlusion-idle). See the flagship section. Before that —

2026-08-03 (evening) — MERGE DAY, board back to empty. Six PRs
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

- **★ The context senses are BUILT (2026-09-01) — verify-by-launch owed.**
  `battery_status` + `calendar_peek` + `current_location` shipped under the
  context-tools charter (docs/CONTEXT_TOOLS_PLAN.md — Kev's rulings: coarse
  grid-cell location by default with a precise opt-up toggle; calendar shows
  titles + times). Per-sense default-OFF toggles in Settings → Privacy →
  Context; interactive-chat-only via ContextSenseHook; sensitive pair is
  `.localSensitive` + distillation-tainted. **Owed on the next ⌘R:** the
  first-use TCC dance for Calendars and Location (toggle → ask → grant/deny →
  the pane's auto-revert), a live `calendar_peek` answer ("what's my day
  look like?"), and a coarse + precise location read. Note each toggle flip
  changes the palette = one cold persona-prefix rebuild on the next turn
  (the documented trade; capacity question tracked below).

- **★ Android model eval harness (Python, over adb) — Kev, 2026-08-22: "best model
  for the hardware, compute — evaled."** The 9a day found two bugs nobody could see
  by feel (an SVE2 CPU-variant producing broken logits; a 0.8B thinking for 171s then
  answering nothing) and one judgement we can't settle by feel (is Lil or Mini the
  right default on 7GB? is thinking ever worth it below Big?). Shape, proven this
  session: `tools/eval/android/` — fixtures (the Mac's `ChatEvalStage` kinds: open-chat
  / tool-use / grounded-Q / security / instruction-following) pushed to a device with
  `adb`, driven through the app (a SelfTest-style one-shot intent, NOT UI taps), verdicts
  read off `logcat` (`MaCore generate: done`, `Native chat done`, tool ids, chars,
  ms), scored by `scorecard.py` like the Mac's. Matrix = models (Qwen3.5 0.8B/2B,
  Gemma 4 E2B, LFM2.5, whatever's next) × CPU variant (armv8.6_1 vs armv9.x — the
  SVE2 bug must be a fixture) × thinking on/off × device. Models MAY diverge from
  Apple (Kev: "Apple doesn't need to match Android"). First run answers: the
  Mini-vs-Lil default, dynamic thinking, and the small-talk tool over-trigger
  (0.8B calls `get_battery_level` on "what can you help with?"; tool answers render
  `tool_id: result` instead of prose). Blocked on nothing; one focused session.

- **★ The perf lever list (2026-08-16 — read the instruments BEFORE picking):**
  - **Turn-phase instrument is armed but UNFED** — every `turn phases:` line so
    far is from test runs. The next real conversation writes the first honest
    pre-gen data (`rg 'turn phases:'` on `app.m1k3:responder`); it names the
    next lever (this is what the 177s-hole hunt needed).
  - **`prewarmed=true` verify** — needs a real Mini-fronted turn (`afm turn:`).
  - **Gemma batch tool-calling A/B** — #131's parallel execution stays latent
    until the prompt nudge is measured. EVAL-GATED (app closed; gemma is
    prompt-fragile — A/B before shipping, standing rule).
  - **Mini iteration cap** (#102's remainder) — wants the instrument's data first.
  - **G2P dictionary RAM** — 197k small `[Int]` arrays; a flat token-buffer
    layout would cut footprint meaningfully. Load already 1.33s→0.27s (#135).
  - **Eval-vs-production divergence, structural fix** — ChatEvalStage's live arm
    should hold the SAME façade production uses (how the #117 persona-dedup hole
    hid: eval had the bare provider, production the wrapper — see
    `facade-capability-forwarding` auto-memory).
- **G2P/voice ear verdicts (Kev):** house pronunciations (Kokoro, Ardmore) are
  one-line IPA tweaks in `HouseLexicon.swift`; letter-to-sound guesses are
  verify-by-ear by design. M1K3 speaks as **Mike** (ruling committed 2026-08-16).
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
  **Then the big one landed the same day (PR #122, A/B-gated):** goal-last +
  `ConversationTailCache` — the conversation used to re-prefill from scratch
  every turn (reuse pinned at exactly the 1786-token persona, measured); now
  the end-of-turn cache seeds the next turn and the eval log reads
  `prefilling 17–23 tok, seed=conversation` per turn. The append-only
  one-session design was challenger-killed first (gemma's sliding window,
  transcript divergence) — the whole story is `docs/VOICE_PERFORMANCE.md` §2a.
  **Remaining owed: the first HUMAN voice-turn reading** (`voice turn:` +
  `seed=conversation` lines from a real multi-turn chat on a build ≥ #122).

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
- **The Heartbeat — v1 shipped 2026-08-06; PROMOTED to a sidebar destination
  with the interaction timeline 2026-08-19 (default OFF, Kev's calls owed).**
  The 2-hourly narrative pulse: deterministic digest + resident-MLX
  retelling. `HeartbeatScreen` is now the canonical surface — pulses and
  visiting-agent MCP calls foldered into per-client visits
  (`InteractionTimeline`, pure/TDD'd; client identity captured from the MCP
  initialize into the opt-in Agent Log, `client_name` v2 migration;
  `mcpLogRevision` makes agent comms live). Window retired; idle card is a
  teaser into the destination. `docs/HEARTBEAT_DESIGN.md` carries the
  challenger record and the open ruling — the activity-log vs
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

## Next — the flagship initiatives

Both voice-on-iOS and Brain-at-home are past the spike stage — architecture and
feasibility are proven, what's left is building.

### 0. The M1K3 screensaver — the Golden Gate "my machine is alive" flagship (2026-08-20)
Kev greenlit a live-presence surface; `challenger` pressure-tested the obvious
shape (an always-on **desktop wallpaper**, porting Cartogram-Mac's `DesktopWindow`)
and **Kev chose the screensaver instead** on its recommendation.

- **Why not the always-on desktop wallpaper** (challenger, grounded in source):
  ① occlusion-idle barely fires — a desktop-level window reads `.visible` if any
  sliver shows (menu-bar gap, Dock, notch), so it only idles inside a full-screen
  Space (when you can't see it anyway); and the rain's `TimelineView` is
  `paused: lowPower` only — **no occlusion-pause seam exists** (`InferencePhosphorView.swift:94`),
  so a straight port is a permanent 30fps GPU loop per screen. ② the "2D pixel
  face" **is RealityKit** (`AvatarView` FaceGrid, 30fps) — same always-on cost as
  the "3D" avatar; only the bare rain Canvas is cheap. ③ the heartbeat line is
  composed from **remembered-fact titles** (`HeartbeatComposer.swift:37`) and
  own-output renders verbatim — a user-content leak onto the most-screenshotted
  surface (the privacy double-bind: screenshotted × readable × data-minimalism → pick two).
- **Why the screensaver wins:** runs only when idle (cost-free — idle = no battery
  worry), most cinematic recording context, macOS owns the lifecycle (no occlusion
  problem), and it rarely lands in a work screenshot so the privacy bind dissolves.
  The "can't read live state" limit is FALSE for us — it can poll M1K3's own
  **loopback MCP** (`127.0.0.1:4242` `get_status`, recent activity) + read
  `heartbeat.sqlite`, both already served. Story: *"what M1K3 got up to while you
  were away."*
- **Guardrails carried from the pass:** v1 self-contained visual (pixel-rain +
  the new **M mark** + black gradient) that always works with zero data; the live
  layer (status + latest heartbeat) degrades gracefully if the loopback port is
  closed or the `legacyScreenSaver` sandbox blocks it (⚠️ **unverified** — sandbox
  may block cross-container `heartbeat.sqlite` reads and/or outbound localhost;
  spike the mechanism first). Freeze-detect / static-idle-mark if the resident
  brain is stalled. Default surface, install to `~/Library/Screen Savers/`.
- **The other two shapes, recorded not chosen:** the always-on desktop wallpaper
  (needs occlusion→full-Space pause seam + glyph-only + energy proof — deferred,
  maybe never); a "Present/Ambient" in-app full-screen mode (cheap, live, opt-in
  "watch M1K3 think" — a possible later companion to the screensaver).

### 1. iOS — to TestFlight, then parity: the ladder (opened 2026-09-02)

**Where it stands.** The iOS/visionOS shell (`M1K3iOSApp/`, 19 files, ~3k lines,
`AppCore` as its own composition root) is real: streaming grounded chat with
tools + history + reading modes + markdown, voice mode (Apple Speech STT +
AVSpeech TTS over the shared `VoiceLoopController`), the pixel face + the five
3D companions, a Mini/Lil brain picker with download progress, Documents +
Memories, the Brain at Home client (QR pairing, PR #152), MetricKit collection.
It links 14 of the Mac's 26 package products, and the library graph is
genuinely portable (one `import AppKit` in all of `Sources/`, seven
`#if os(macOS)`). What it never had was a lane to TestFlight — and **no build
has run on hardware since the July harness** (Mini + Lil verified on an
iPhone 17 Pro then; the shell since, only compile-green in CI).

**Phase 0 — the lane.** In PR (2026-09-02): the mobile bundle IDs unified onto
the universal `app.m1k3` record (the developer portal registers it UNIVERSAL;
the ASC record already carries IOS + VISION_OS 1.0.0 drafts — the `.ios`/
`.visionos` suffixes had nowhere to upload), `PrivacyInfo.xcprivacy` on the
mobile targets, `M1K3iOS.entitlements` (increased memory limit — what Lil on
a phone stands on), `NSBonjourServices` for Brain at Home browsing, an
Info.plist per target, and `tools/ci/check_store_targets.py` pinning all of
it. **After merge:** one `PATCH` adds an `Archive — iOS` action to the
existing `Release` workflow (`docs/XCODE_CLOUD_RELEASE.md` §3) → the next
master push mints build N for Mac AND iOS → TestFlight Internal → Kev's
iPhone 17 Pro. **Exit:** an IOS build reading VALID in ASC, installed via
TestFlight, and the on-device smoke the shell has never had — a Mini turn,
Lil download + turn under the entitlement (read `os_proc_available_memory()`
and tune `MLXMemoryBudget`'s 4 GB), a voice round-trip, the Brain at Home
ceremony with Bonjour declared.

**Phase 1 — the cheap parity (Mac-only by linkage, not by nature).** Each is
a package that already builds for iOS plus a thin `AppCore+` adapter, in the
order the Mac's soul shows through:
- **Heartbeat** — `M1K3Heartbeat` (pure) + `HeartbeatScreen`/`IdleCard`/
  settings section; the engine in `AppEnvironment+Heartbeat.swift` has one
  AppKit touch (`NSApp.isActive` gating the pulse notification — `UIApplication`
  state on iOS), the rest is portable.
- **Context senses** — `battery_status` needs a `UIDevice` provider (the Mac's
  is IOKit-guarded and returns nil on iOS); `calendar_peek` +
  `current_location` reuse the EventKit/CoreLocation adapters from
  `AppEnvironment+ContextSenses.swift`, plus the Privacy toggles and usage
  strings. Same charter: coarse by default, precise opt-up, default-OFF.
- **Settings IA parity** — M1K3 / You / Privacy / General / Advanced (the
  2026-09-01 reduction) over today's single Form, same footer copy.
- **The wake carousel** for the Lil download wait — `WakeSetupCarousel` is
  SwiftUI over `WakeSetupFlow` (M1K3Inference, pure); the cards apply as-is.
- **Memory export** (OKF, ADR 0003) via `fileExporter`; **long-think
  notifications** (`TurnNotificationPolicy` is pure, `UNUserNotificationCenter`
  is the same API); **Spotlight** donation (CoreSpotlight, titles only).
- **The constellation** — `M1K3MemoryViz` holds the one AppKit import
  (NSColor in the palette/view); a UIColor branch unlocks the companion
  option on mobile.
**Exit:** the Settings tabs read the same on both platforms and every consent
toggle exists on iOS with the same copy.

**Phase 2 — voice parity (the port doc's Phase B).** Kokoro TTS (pure MLX
since #58) vs AVSpeech decided on a **measured 10-minute thermal burn**;
WhisperKit vs Apple Speech (assert on-device recognition, fail loud on the
silent server fallback); sentence-streamed auto-speak in chat
(`AppEnvironment+AutoSpeak`) + karaoke follow; interruption/route negatives;
the `UIBackgroundModes: audio` call (only if voice must survive backgrounding —
today the shell exits voice on background, deliberately). The #85 voice-mode
crash triage reads `MXAppExitMetric` from the MetricKit store already
collecting on the phone.

**Phase 3 — the iOS-native soul (Phase C).** App Intents/Shortcuts
(`M1K3App/Intents/`, five small portable files over the shared
`AppEnvironment+Intelligence` core), a Lock Screen/Home widget carrying the
last heartbeat pulse, a Live Activity for long thinks and weight downloads, a
Control Center "Ask M1K3" control, a Share extension for drop-a-doc (the O5
card the Mac still owes too). This is where the phone stops being a port and
becomes the menu-bar app's sibling.

**Phase 4 — the store pack** — one universal record, so the SAME session as
the Mac's MAS pack: screenshots (6.9"/6.5" iPhone, 13" iPad),
`fastlane/metadata_ios/` (copy drafted in `marketing/ios-launch/`), review
notes (Mini's instant no-download path for the reviewer, on-demand weights,
local-network + camera-for-QR explained), privacy label "Data Not Collected",
4+, external TestFlight → Beta App Review. Budget one rejection round.

**Phase 5 — Vision Pro (Phase D).** A visionOS archive action (the target is
already `app.m1k3`) plus its own entitlements file — the increased-memory-limit
entitlement is wired to `M1K3iOS` only today, a conscious carry-forward, and the
store-targets guard does not pin entitlements; the volumetric avatar + walkable constellation flagship.
Hardware-owed. What's already banked from the July spikes, so nobody
re-runs them:
- K0 (MLX-Kokoro feasibility) ✅ · K1 (on-device A/B, Kev's ear passed it) ✅
  → **#58 merged** · V0 (visionOS sim spike) ✅ → its dark-avatar finding fixed
  in **#60** (camera-less `GeometryReader3D` framing — visionOS's eyes *are*
  the camera). V0's tab-ornament finding CLOSED BY REMOVAL (PR #82 retired the
  tab shell; chat is the app, the rest are pushes).
- Scoping: "voice-forward, not voice-only" — voice is a full-screen cover over
  the retained chat shell (setup/downloads/TCC/consent stay visual), v1 in #82.
- Landmines named in `scratch/voice-mobile/PLAN-DRAFT.md`: self-echo (no AEC
  anywhere — v1 is push-to-talk); Apple Speech's silent server fallback is a
  privacy landmine on a listening surface; thermals need a measured burn.

**Not ported, by design (the Mac-shaped half):** the in-app MCP server (no
desktop agents dial into a phone — Brain at Home is the phone's way of being
served), the Brain at Home *server*, the screensaver, the menu bar, the notch
HUD, scripts/hands (no `NSUserUnixTask` on iOS), launch-at-login, call
recording's far-end capture (ScreenCaptureKit). **Parity means parity of soul
— chat, voice, memory, companions, senses, heartbeat — not a window-for-window
copy.** Each Mac-shaped surface either gets an iOS-shaped sibling in Phase 3
or nothing, on purpose.

### 2. Brain-at-home — **Mac side SHIPPED 2026-08-19; iPhone/iPad client BUILT 2026-08-24** (`docs/BRAIN_AT_HOME_SPEC.md`)
- **Phase A spikes all PASS** (`scratch/brain-at-home/spikes/RESULTS.md`) with
  one spec-impacting finding: TLS 1.3 external-PSK doesn't handshake on
  Network.framework — the mechanism is **TLS 1.2 pinned + ECDHE_PSK 0xD001**
  (PSK mutual auth WITH forward secrecy). §8a defaults adopted (plan-approval
  veto pass, 2026-08-19).
- **Mac server live behind Settings → Privacy → Brain at Home** (default OFF):
  `M1K3BrainServe` module (pairing state machine + scope + listener, TDD'd
  incl. real loopback TLS-PSK negative paths), QR pairing with the on-Mac
  Approve + separate candidate-only pairing listener, Bonjour advertise,
  429/preemption etiquette, and — **Kev's ruling** — the SCOPED LAN `/mcp`
  route (read/ask allowlist, its own default-OFF toggle).
- **Phase C (iOS/visionOS client) — BUILT 2026-08-24.** New `M1K3BrainLink`
  module (MCP-free; the shared TLS-PSK wire moved there): the QR
  `PairingPayload` as ONE compose/parse type — **now carrying the Mac's LAN
  `hosts=`** (the 08-19 QR had no address at all; a first-time device had
  nothing to dial, since Bonjour only advertises once a device is paired) —
  client HTTP/SSE codecs pinned against the server's own frames, the
  `NWConnection` transport, the pairing ceremony (pair → poll-health-until-
  Approve), `HomeBrainProvider` (the Mac's brain in the mobile inference
  slot; refusals speak etiquette copy), and the device store (defaults +
  Keychain). Shell: in-app QR scanner (iOS) / paste path (Simulator +
  visionOS), the "Home" brain row, the Brain at Home Settings section with
  live health + Forget. Loopback tests drive the production client against
  the real listener (health, SSE, 429, 503, wrong-key, pair).
  **Hardware-owed (Kev + iPad): the real ceremony** — QR scan, Approve,
  Local Network dialog, a streamed answer, Tailscale-unreachable.
- **Next:** Android client (Conscrypt PSKKeyManager, or the cert-pin
  fallback). Follow-ups: canary→Keychain migration; LAN-MCP client-name
  stamping (the paired device name is the natural stamp); N2/N3 escalation
  UI now that a real client exists.

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
- ~~App icon: swap the liquid-glass wordmark for a plain M~~ — **DONE, PR #142
  (2026-08-20).** The **M brand mark** — the leading pixel-M lifted exactly from
  the wordmark (5×7, 17 cells), kept monochrome, glass-composited on the black
  gradient. Both platforms ride the identical mark (visionOS `.solidimagestack`
  regenerated from the same source); verified in the compiled bundle. Source of
  truth + generator + brand sheet in `tools/icons/brand/`. Downstream still open:
  make the M focal on the **website** + a content pass reflecting Brain at Home /
  heartbeat / rain / feedback (its own session). The OG-image brand call below
  now resolves to the M, not the pixel face.
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
