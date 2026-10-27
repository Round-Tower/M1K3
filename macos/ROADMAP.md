# M1K3 — Roadmap

This is the living "what's next" doc — kept current, not append-only. For
architecture/build/test, see `CLAUDE.md`. For *why* a decision was made (model
swaps, phase rationale, the full session-by-session build log), see `PLAN.md` —
it's a signed historical record and stays that way; this file doesn't repeat it.
The macOS 27 wave's release plan (1.0 → 1.1 → 1.2) lived in
`docs/GOLDEN_GATE_PLAN.md`, retired once 1.0 shipped (#562; git history keeps it).

Last swept: 2026-10-26 — **1.2.1 is the current release** (tag
`release-1.2.1-20261023-e4ce9115`, local build 540 via `release-local.sh`; What's New
and promo text in 12 locales, #668). 1.2.0 was tagged 10-21 (#657), 1.1.1 on 10-20
(#649), 1.1.0 on 10-19; Mac 1.0.0 went live 2026-10-11 on build 453. iPhone & iPad App Store links
went into the README, site, `llms.txt` and `install.txt` on 10-22 (#663). ⚠️ This
sweep could not read `itunes.apple.com/lookup?id=6780230835` (blocked from the
session), so which build each storefront serves is unverified: read the lookup
before quoting it. Lil is Qwen3.5-4B with a 1,024-token thought cap (#643); Big is
gemma-4-12B; Mini is AFM. The tagline is "Your AI. Your devices. Private by design."
(#664). The 1.0 review-weeks record (09-17 → 10-11) lives in git history before
this sweep.

---

## Now — after 1.2.1: inference speed, voice, distribution

### Inference: the cross-turn cache (#687, #690, #691 — landed 10-25 → 10-26)

- **Tail checkpoint** (#687): a turn seeds from where the last one left off.
- **Block eviction** (#690, `HistoryWindow.Budget.evictionBlockTurns`: 6 Mac MLX, 4 spoken Big,
  1 Mini / pocket / mobile; `-historyEvictionBlock N`).
- **Caller-marked stable prefix** (#691): past the window the tail hits 14/21 on both
  brains (sliding 0/21); Big extend median 4.8 s where sliding paid 10–12 s, Lil 1.8 s;
  peaks unchanged (Lil 4.73 GB, Big 9.19 GB). Curves in `docs/evals/2026-10-26-chatcurve-*`.
- **Next:** plain-route tail (phase 2, `runSeededPlainTurn`); a recall probe past a block
  boundary; #621 warm reorder; kvBits / prefillStep / clearCache A/Bs. Branches in flight:
  `perf/grounding-budget-arm`, `perf/inference-instrument` (local; no branch on origin).

### Voice

- Mac voice processing + spoken barge-in **on by default** (#682, #640); sources are no
  longer read aloud (#678). NameRepair + SoundContext wired in voice mode (#618, shadow
  verdict); Big's spoken replay holds ~4 exchanges with evicted-turn traces (#625, #630).
- Owed: Bluetooth-headset check under voice processing (see § 1.0.1 below).

### Routing: the search head (#713, open for Kev)

- `SearchRouter` reads whether a turn needs the web, over the router's one sentence vector, and only
  vetoes a web read the picker named (`ToolDispatch.searchCorrected`): it never adds a search, and an
  explicit web ask or a question about now never reaches it. From #680 ("tell me the history of
  Dublin" web-searched, 30.8 s to the first chunk). Off on both shells (`toolSearchHead`;
  `-toolSearchHead YES` on the Mac) and shipped as an untrained stub that never vetoes.
- Measured 2026-10-26 (`docs/evals/2026-10-26-search-head.md`):
  - The teacher pass ran on the plan's fallback labeller (gemini-4-argon; Clef-flash's loader was
    refused) and confirmed 820 labels.
  - The trained head misses the gate. Held out, 3/12 stable lines read local and the #680 Dublin line
    reads web, so the stub stays shipped.
  - The paired Lil arm vetoed nothing (113 → 114/126). The #680 fixtures search through the picker,
    the dispatch route the veto covers.
- Owed: Kev's threshold ruling. 0.165 keeps 90/93 must-search turns in CV; the #680 lines flip only from
  0.65, where CV keeps 50/93. Or a stronger base than the NLEmbedding vector, then Big's arm.

### Distribution and growth

- **Measure:** `ranks.py` (daily rank per term × storefront × platform, #673), `metrics.py`
  (reach from sales reports, the Analytics API and GitHub, no telemetry, #653).
- **Store:** Russian + en-GB keywords (#666), Arabic ar-SA (#667), ASO keyword swap (#674),
  the ratings ask after one liked answer or ten turns (#665).
- **In-app event:** Offline AI Flight Club, Nov 3 → Dec 1 (#669); Halloween in the Lair ends Nov 1.
- **Site:** Terms of Service (#641), TAAFT badge (#632), the new tagline (#664).

### Process

- Xcode Cloud builds only `release*` tags (#635, after the 10-15 compute-hours outage);
  `release-local.sh` ships when the hours are spent (#660).
- Review gates: delta re-review after an approval (#686), the claims check on paths and
  flags named in a diff (#685, `ci/claims-check`), `pr_watch` verdict fixes (#688, #689).
- Open: #692 (root CLAUDE.md, docs-only). The claims check and delta re-review landed as #685 and #686.

### Next picks

- **#303** Lil "What can you do?" 2/3 answers close on the decline line — needs
  an in-app eval gate before any prompt change.
- **Mini's weak kinds on the scoreboard** (`site/brains.json`, 10-06): sycophancy 2/6,
  instruction-following 9/18, vision 1/16 — each wants an eval gate before a prompt change.
- **Local-only branches** to push or retire (Kev's call): `fix/doc-question-skips-lookup`,
  `spike/moe-big-audition` (4 commits), `feat/eval-harness`, `backup/face-reveal-5e8e8485`.
  All are in `~/Development/m1k3-branch-backup-2026-10-26/all-local-branches.bundle`.

### Monetization — the 90-day plan (#369)

Three tiers: **Free** (full M1K3 — the promise), **Pro** (cosmetic: avatars,
voices, companion skins — never gates intelligence), **Teams** (Custom App via
ASC, stripped to business, org knowledge graph, managed deployment). The rule:
Pro never gates intelligence, memory, or privacy. Kev's 90 days: LinkedIn,
the first Teams customer, the move from engineer to honest founder.

### 1.0.1 — verify-owed list (device evidence first, then fixes)

- iOS `.fitWhole` framing on a real phone (#312); the gecko is small —
  `CompanionFraming.fit(headroom:)` is the one knob.
- Bluetooth-headset voice test on the Mac (memory `mac-bluetooth-vpio-starves-mic`).
- Constellation window ideal frame + a richer demo seed for the held plate.
- WhisperKit 0.18 → 1.1: probe-first, post-launch only. **Probed 2026-10-07** with swift-transformers
  1.3.4 (the Gemma tokenizer fix): builds, `swift test` green, one region-isolation fix. Owed before
  landing: voice launch check, gemma-4 tool-call smoke, Kev's call on timing vs the store submission.

### Standing 1.0.x items (their status lived in `docs/GOLDEN_GATE_PLAN.md` § 1.0.x, now in git history)

- **Prefix prewarm: n ≥ 5 in-app rerun owed** (turn-1 2.7 s vs 5.8 s at n = 2).
- **The Mini palette call (Kev):** 16-tool palette puts ~3.9k of Mini's 4,096
  in the fixed prompt. Levers: smaller palette, shorter descriptions, or
  `toolCallingMode(.disallowed)` for small talk (available since the September bundle).
- Mini's invented user threads; the verbatim-recital hardening (#111).

---

## Next — the releases

### v1.1.0 — SHIPPED (tagged 2026-10-19, `release-1.1.0-20261019-29fbc135`; 1.1.1 followed 10-20, #649; `docs/GEMMA_1_1_PLAN.md`), What's New in #524

Marketing version 1.1.0 on every surface (`VERSIONING.md`), bumped in #561 the day 1.0.0
went live; Xcode Cloud mints the build. What rides in it, user-facing:

- **Lil is Qwen3.5-4B and it sees** (#501, #517): image attachments on Lil, the
  VLM load path, weights pinned at `32f3e8ec`; one more ~3 GB download, the
  retired Lil freed from Settings. The Reasoning picker is back for Lil.
- **Lil's tool turns**: exact-seed checkpoints (#509, ~60 prefill tokens a step,
  not ~2,585) and the orphan-`</parameter>` repair (#511) — tool-use 19/20 at
  5.9 s at tier.
- **Big no longer re-reads its prompt every step**: the Gemma tokenizer fix
  (swift-transformers 1.3.4, #499) and the display-sleep stall hold (#498).
- **Calls**: one unreadable call no longer blanks the call list (#507).
- **Search index**: MLX-embedding users re-index once after the update (#503's
  mlx-swift 0.32.3 / mlx-swift-lm 3.32.3 tag pair).
- **Content Controls on DMG builds + the adult band's copy** (#518, #519, #520);
  MCP works on DMG builds on macOS 27 (#518).
- Not user-facing but riding: every tier can dispatch read-only tools behind
  flags (#510), the eval harness sees (#497, #502), App Store creative assets
  (#506), the README hero (#505).

- **Landed since (2026-10-09 → 10-11):** the voice-mode window backdrop (#525), Mini
  sees + Lil polish (#526), the honest strings (#527), Remember this photo (#523), the
  router on every tier (#542), re-run onboarding (#544), EmbeddingGemma 2 as the one
  embedder (#547), one thinking decision per turn (#555), and Kev's TestFlight list
  (#561): MCP Server + Brain at Home panes, auditions and weight import retired (a
  one-time folder delete), the avatar as backdrop or off, no thinking rain, titles that
  never think, VoiceOver state announcements, Halloween in the Lair (Oct 24 – Nov 1).

The Gemma plan's triage of what stays out
(Stream C port, the caption-memory slice, Stream E, E2B, the cross-turn checkpoint,
the display-off A/B) is in `docs/GEMMA_1_1_PLAN.md` § 5.

### The September Golden Gate bundle (then called "1.1.0") — MERGED 2026-09-16, riding under 1.0.0 (was `docs/GOLDEN_GATE_PLAN.md`, now in git history)

On master, not on the store (see the header). Toolchain bump to Xcode 27 GA
(#362), typed AFM errors, CI guards, and **Private Cloud Compute is merged**
(the planned 1.2 rung landed early — the policy, send path, consent sheet, Mac
shell, FM27 adapter and entitlement are all on master). Since then: 5 App
Intents (#366), AFM vision + file-as-context (#367).

**Still open from 1.1's original list:**
- `toolCallingMode(.disallowed)` for Mini small talk (#102) — the API is
  available now; needs a Mini eval gate before shipping.
- Apple's `SpotlightSearchTool` / `OCRTool` behind a `ToolPalettePolicy` A/B.
- ADR 0001: Lil and Big registered as `LanguageModel`s.
- Teams: the org switch + fleet-wide-lock (#350 policy-key forced-value read).

### iOS — the parity ladder (opened 2026-09-02): where it stands

- **Phase 0, the lane — DONE.** One universal `app.m1k3` record, privacy
  manifest + entitlements + Bonjour key on the mobile targets, the
  store-targets guard (#182); ITMS-90474 orientations (#191); builds 358–361
  VALID; the iOS lane on a real phone for plates (#256).
- **Phase 2, voice — LANDED 09-03/09-04** (#194/#199–#205: sentence streaming,
  karaoke, pauses for calls, Kokoro as a Settings pick with Built-in the
  default, the VPIO silent-source fix; the double-tap race #301 → #331).
  Still deciding Kokoro-as-default: a measured 10-minute thermal burn with Lil
  resident. Still owed: WhisperKit vs Apple Speech on the phone (assert
  on-device recognition, fail loud on the silent server fallback).
- **Phase 4, the store pack — SUBMITTED, in review** (Mac + iOS, one universal
  `app.m1k3` record); iPhone + iPad 13" plate sets real. Not live as of 09-18.
- **Phase 1, the cheap parity — NOT started.** Each is a package that already
  builds for iOS plus a thin `AppCore+` adapter: Heartbeat (one AppKit touch:
  `NSApp.isActive` → `UIApplication` state), the context senses (`UIDevice`
  battery; EventKit/CoreLocation adapters reused), Settings IA parity, the
  wake carousel, memory export (OKF, ADR 0003), long-think notifications,
  Spotlight donation. The constellation already crossed (#250, "one sky, two
  shells"); the brain menu is device-honest (#229). Exit: the Settings tabs
  read the same on both platforms and every consent toggle exists on iOS
  with the same copy.
- **Phase 3, the iOS-native soul — STARTED.** App Intents/Shortcuts SHIPPED
  (#366, 8 total: Ask, Speak, Remember, SearchKnowledge, RecallMemory,
  ListTodos, ProposeTodo, OpenVoiceMode). Image + file attachment in flight
  (#371). Still open: a Lock Screen/Home widget with the last pulse, a Live
  Activity for long thinks and downloads, a Control Center "Ask M1K3", a Share
  extension for drop-a-doc.
- **Phase 5, Vision Pro — hardware-owed.** visionOS 1.0.0 has no build; the
  archive action + its own entitlements file are the lane work. Banked from
  July so nobody re-runs them: K0/K1 (MLX-Kokoro, Kev's ear) → #58; V0 → the
  camera-less `GeometryReader3D` framing (#60); the tab shell retired by #82.
- **Not ported, by design (the Mac-shaped half):** the in-app MCP server,
  the Brain at Home *server*, the screensaver, the menu bar, the notch HUD,
  scripts/hands, launch-at-login, call recording's far-end capture. Parity
  means parity of soul — chat, voice, memory, companions, senses, heartbeat —
  not a window-for-window copy.

### Brain at Home (`docs/BRAIN_AT_HOME_SPEC.md`)

Mac server SHIPPED 08-19 (`M1K3BrainServe`, default OFF, TLS 1.2 + ECDHE_PSK
because TLS 1.3 external-PSK doesn't handshake on Network.framework; the
scoped LAN `/mcp` route on its own toggle). iPhone/iPad client BUILT 08-24
(`M1K3BrainLink`; the QR carries the Mac's LAN `hosts=`); the TLS-resumption
re-pair bug fixed 09-05 (#229/#231 — a resumed session skipped the PSK
exchange). **Hardware-owed: the real ceremony** — QR scan, Approve, the Local
Network dialog, a streamed answer, Tailscale-unreachable. Next: the Android
client (Conscrypt PSKKeyManager or the cert-pin fallback); canary → Keychain
migration; LAN-MCP client-name stamping; the N2/N3 escalation UI.

### The screensaver — SHIPPED 2026-08-20

`M1K3ScreensaverCore` (Foundation-only) + the `.saver` bundle, installed from
Settings ▸ General. Kev chose it over an always-on desktop wallpaper on a
`challenger` pass (occlusion-idle barely fires for a desktop-level window; the
pixel face is RealityKit; the heartbeat line would put remembered facts on
the most-screenshotted surface) — the full record is in this section's git
history (2026-08-20 → 09-02). A "Present/Ambient" in-app full-screen mode
stays a possible later companion.

---

## Carried from the August sweeps (still live; one line each)

- Context senses (`battery_status` / `calendar_peek` / `current_location`,
  #173): the first-use TCC dance, a live `calendar_peek` answer and a coarse +
  precise location read are still verify-by-launch. Each toggle flip changes
  the palette = one cold prefix rebuild (the documented trade).
- The first HUMAN voice-turn reading — `voice turn:` + `seed=conversation`
  lines from a real multi-turn chat (build ≥ #122). Prefill dominates
  time-to-first-audio; the lever is fewer prompt tokens, not decode.
- **#121** the palette is a KV-cache key: `PersonaPrefixCache.defaultCapacity`
  is 2 against three real palettes. Standing consequence: tune the grounding,
  never the palette (per-question routing stays off the table).
- Grounding narrates what's in front of it (the 3-March pomegranate) and no
  cosine threshold separates answerable from not (0.497 vs 0.489 on Kev's
  store). Surviving candidates: rank-aware injection (best 2, not 7) or an
  answerability judgement that is not a similarity number. Measure first.
- Heartbeat is a sidebar destination, default OFF: Kev's calls owed
  (default / cap / history length; Big vs Lil narrative A/B after an
  afternoon with it on).
- **#85** iOS voice-mode crash: `MXAppExitMetric` names the exit on the next
  repro; AVAudioSession activation moved off the main actor in the 09-03
  pass (suspect ②).
- Dream-cycle Tier-2 soak → the Tier-3 decision is a re-measure, not a
  build; #94's corrected-facts lens makes the soak eyeball-able.
- **#102** Mini's turn shape → now answerable by `toolCallingMode` (shipped in
  the September bundle); the small-talk gate stays rejected ("brittle both ways", 2026-06-12).
- Android eval harness — SHIPPED 08-22 (`tools/eval/android/`; the F1/F2/
  KV-clear fixes lifted Mini 9 → 19/22 and falsified the "armv9 broken
  logits" read). The KMP app is a slow burn; models may diverge from Apple.
- The reduction wave's staged cuts (show-a-state-once · one promise · the
  debug door · one thinking control · "Left this Mac" — the egress list that
  proves the thesis): #3 vocabulary collapse done (#96); the rest unbuilt,
  doctrine-tested when picked.
- The 08-16 perf lever list is superseded by the fanless-idle audit (#293)
  and the prewarm work (#328). Left: G2P dictionary RAM (197k small arrays →
  a flat buffer), the gemma batch tool-calling A/B (#131, eval-gated), and
  eval-vs-production façade parity (`facade-capability-forwarding`).

---

## Then

- **Knows-me LoRA — data pass.** The voice LoRA trained clean but was PARKED:
  2 of 4 pre-registered gates failed (a softened security refusal; a confident
  factual confabulation). The fix is DATA, not knobs: audit `anti_injection`
  seeds, rebalance world_fact vs uncertainty examples, target the
  confident-precision failure. Then retrain → A/B against the kept iter-100
  checkpoint → the Swift CHATEVAL `security` suite as the gate.
- **Age-gating follow-up PR.** #31 shipped only the pure `AgeBand` /
  `AgeAppropriateness` core; the `DeclaredAgeRange` request flow +
  entitlement + persona clause + web-tool gate wiring was held for Beta App
  Review, which cleared 2026-07-18. Re-verify the Declared Age Range API
  against current Apple docs before building.
- **Memory distiller-quality eval.** An AFM-judge eval scoring whether
  `MemoryDistillationCoordinator` extracts good facts from chat (no fixtures
  in `M1K3Eval` yet), and the `user.profile` vs `.memory`-graph collision
  check. #288's `DistillationAttribution` (user-anchored facts, wiring notes
  rejected) narrowed it again.
- **Core AI spike** (post-1.1): an `.aimodel` on the Neural Engine — the
  embedder or a tiny classifier, not a chat brain. And: what the
  `model-delegation` entitlement grants.

---

## Backlog (smaller, pick off anytime)

- **Spotlight `.memory` donation** — excluded from #29 on privacy grounds (a
  distilled fact's title *is* its body). Needs 3 lifecycle hooks
  (supersede-deindex, forget-revive-re-donate, tag-UI-deindex), each red-first.
- **White-pane Code-tab render check** — the offscreen probe renders a
  persisted artifact correctly, Kev saw it white/unstyled in-app. Probe-clean,
  app-divergent, cause unknown; Kev's Code-tab check is still owed.
- **Issue #46** — refusal-marker ledger: the scorer misses "Not going to do
  that one" / "Won't chase"; grows one entry per bake-off.
- **Audition finalists on disk** (`~/.cache/m1k3-audition`, 26 GB after the
  09-15 prune): Qwen3.6-35B (the craic pick), Ornith-9B (parked at parity,
  7× slower), LFM2.5-2.6B, MiniCPM5-2B. Never into the app's model store
  (cache-poison rule). Delete when the next audition has a new list.

---

## Watching / blocked upstream

- **MTP speculative decoding for Big** — re-measured 2026-09-05 (#212–#216)
  and PARKED again: gemma-4-12B's 1024-token sliding window puts every
  production turn in the wrapped regime (0.79–0.87× baseline, one fixture
  diverges). Unparks only if the prompt fits 1024 or upstream makes the
  wrapped regime faithful *and* engaging.
- **OptiQ mixed-precision** — parked; upstream loads the format but
  generates garbage (mlx-swift-lm #450). The OptiQ repo's fixed chat template
  is vendored directly instead (`Gemma4TemplateFix`).
- **`gemma-4-12B-it-4bit` chat template upstream** — the canonical 2026-07-09
  template is installed over the stale bytes at load (hash-gated); if
  mlx-community re-quantizes, re-check the pinned manifest hash.
- **Qwen3.8-27B** as a future Big — root-caused to the 12 GB ceiling
  (`MLXMemoryBudget` per tier, #218); the MoE queue's answer was "delegation
  brain, not front Big" (gemma-4-26B-A4B, 15 GB peak, 32 GB+ Macs).

---

## Needs Kev — open calls, gathered in one place

- **LinkedIn + the first Teams customer** — the 90-day founder move (#369).
  One post a week; the product demos itself; the DyslexiaAI story is the
  unfair advantage.
- **The Mini palette call** (above): smaller palette / shorter descriptions /
  `toolCallingMode(.disallowed)` (available since the September bundle).
- **#271** `TAP_PUSH_TOKEN` so the nightly bumps the Homebrew cask.
- Brain-at-home §8 calls (naming, serving indicator, thermal etiquette,
  visionOS timing) unblock Phase A of the Android client.
- Dream-cycle Tier-2 corpus-twin marker: sub-kind vs title-prefix (spec §5
  recommends sub-kind).
- **Brand calls** still open: the Labyrinth icon family → attic; the OG image
  regen (`site/og.png` 06-13 and `assets/brand/readme-hero.png` 07-02 predate
  the product — #322 carries the new ones); the reading-modes ceremony.
- **"Machine", not "Mac", in M1K3's own voice — RATIFIED 2026-08-03**: the seam
  is `HostPlatform.noun`; the pass: flip → re-pin → A/B both brains → sweep
  the ~6 first-person UI strings.
- Store keywords: en-US at exactly 100/100 — any new keyword displaces one.

---

<!-- Review: Kev + claude-opus-5-5, 2026-09-27 — the review build is 374: #423 (the route was dead on the
     Mac in 373) and #424 (the lean dispatched prompt, "Preparing Mini…", neutral titles) plus the carried
     items from walking it. Confidence 0.85. -->
<!-- Review: Kev + claude-opus-5-5, 2026-09-26 (7) — router-invoked tools (ADR 0009) join the next
     review build; the route's persona reversed to Mini's own on evidence. Confidence 0.85. -->
<!-- Review: Kev + claude-opus-5-5, 2026-09-26 (6) — #412 merged; the tool router (default on) and the
     Debug-build avatar finding (#413) join the next review build. Confidence 0.85. -->
<!-- Review: Kev + claude-opus-5-5, 2026-09-26 (5) — ADR 0007 accepted. Confidence 0.95. -->
<!-- Review: Kev + claude-opus-5-5, 2026-09-26 (4) — Mini tool-calling result recorded, with its costs
     and the two follow-ups. Confidence 0.85. -->
<!-- Review: Kev + claude-opus-5-5, 2026-09-26 (3) — SpeechAnalyzer landed in AppleSpeechTranscriber
     (Kev's call); the speech line records it and what stays owed. Confidence 0.85. -->
<!-- Review: Kev + claude-opus-5-5, 2026-09-26 (2) — the icon line records Kev's pick (C) instead of
     a recommendation. Confidence 0.95. -->
<!-- Review: Kev + claude-opus-5-5, 2026-09-26 — header truthed to build 372 (store still unlisted);
     "The next review build" block records the feat/review-build-polish work and the three calls
     it leaves with Kev (ADR 0007, reasoning; icons settled on C). Confidence 0.85. -->
<!-- Review: Kev + claude-fable-5.1, 2026-09-18 (2) — review fold on #381: the "1.1.0" section heading still
     said SHIPPED, with "PCC ships" and "are all live" under it — the same error in three phrasings, two
     screens below my own correction. Now "MERGED, riding under 1.0.0". The code-landed SHIPPED lines
     (App Intents, Mac server, screensaver, Android harness) describe the repo and stand. Confidence 0.9. -->
<!-- Review: Kev + claude-fable-5.1, 2026-09-18 — FACT correction only: 1.1.0 was merged, never
     shipped; 1.0.0 is still in App Review (store lookup → no listing; Kev's word). Header, the
     "Now" title, the #370 line and the store-pack line truthed; the plan itself untouched.
     The 09-17 entry below stands as written — its "1.1.0 shipped" is the error this corrects.
     Confidence 0.9. -->
<!-- Review: Kev + claude-opus-4-6, 2026-09-17 — post-1.1.0 sweep: 1.0/1.1/1.2
     sections folded (1.1.0 shipped PCC, intents, vision); "Now" rebuilt for the
     landing PRs (#370/#371/#372) + the monetization issue (#369). #336/#341
     closed (stale/backwards). iOS Phase 3 App Intents marked SHIPPED (#366).
     Confidence 0.85. -->
<!-- Review: Kev + claude-fable-5.1, 2026-09-15 (launch night): the post-launch
     realign. Header truthed to the 09-15 submission (Mac 362 / iOS 361,
     MANUAL); Now rebuilt as "in the queue" (on-approval steps, the 1.0.1
     verify-owed list from launch week, the standing 1.0.x items); 1.1 gates
     re-read (two of three met — Xcode 27 GA and ASC accepting 27-SDK builds;
     the CI/cloud pin waits for compute on 09-28); 1.2 corrected from "Kev
     files the entitlement" to GRANTED 09-14 with what is and is not in a
     build; the iOS ladder marked phase by phase (0 done, 2 landed, 4
     submitted, 1/3/5 open); the screensaver moved to SHIPPED; the ~260-line
     August "Now" folded to one line per still-live item; DONE backlog rows
     and resolved brand calls removed (Mike committed, noun = agent, store
     presence done). Confidence 0.85 (every state read off the ASC API, gh
     and the tree this session; the on-approval steps and the 1.1 order are
     judgment for Kev to overrule). -->
<!-- Review: Kev + claude-opus-5, 2026-09-14: Phase 17b decided (ADR 0006,
     Kev's call: PCC in, posture "private by design", copy swap ships with the
     rung). Confidence 0.85 (the decision is Kev's; the filing route for the
     entitlement is unverified). -->
<!-- Review: Kev + claude-opus-5, 2026-09-13: Golden Gate prep. Phase 17b
     re-gated from "no macOS 27 runtime" to the PCC entitlement (runtime
     probe: available, 32k context, generation refused with error 1046), and
     the Golden Gate wave bullet now points at GOLDEN_GATE_PLAN.md's 1.0 →
     1.2 roadmap. Confidence 0.85 (SDK surface read from the Xcode-beta
     27A5194q swiftinterfaces; the runtime numbers come from one probe on
     one M1 Max; the 1.x ordering is judgment for Kev to overrule). -->
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
<!-- Review: Kev + claude-opus-5-5, 2026-10-07 — the WhisperKit 0.18 → 1.1 line: probed with
     swift-transformers 1.3.4 (the Gemma tokenizer fix, GEMMA_1_1_PLAN); builds and tests green; the
     launch checks and the landing timing stay open. Confidence 0.75. -->
<!-- Review: Kev + claude-fable-5.1, 2026-10-09 — v1.1.0 release-commit pass: the header reads build 453
     (Mac IN_REVIEW, iOS WAITING_FOR_REVIEW; nothing live); the September bundle loses the "1.1.0" name so the
     real v1.1.0 (Gemma-shaped: Qwen3.5 Lil that sees, Lil tool turns, the Big tokenizer fix, #497–#520) has
     its own section with the open branches; the two toolCallingMode lines point at the bundle instead of
     "1.1.0". Confidence 0.85 (the PR list is git log; the branches are the worktree list, unpushed). -->
<!-- Review: Kev + claude-opus-5.5, 2026-10-11 — 1.0.0 went live on the Mac App Store (build 453), so the
     header leads with that and iOS's open review; § v1.1.0 is on master (bumped in #561) and lists what
     landed since 10-09 instead of the open branches; GOLDEN_GATE_PLAN.md is retired (#562), so its three
     pointers say "in git history". Confidence 0.85 (store state read from the lookup + ASC today). -->
<!-- Review: Kev + claude-opus-5-5, 2026-10-26 — the post-1.2.1 sweep: header truthed from the release
     tags and git log (1.1.1 → 1.2.0 → 1.2.1); the store lookup was blocked from the session, so storefront
     state is flagged unverified rather than asserted. The 09-27 "Now" (review build 374, landing #370–#372)
     is retired to git history; Now rebuilt as the four live streams (cross-turn cache, voice, distribution,
     process) off #616–#691 and the 10-26 session block. § v1.1.0 marked shipped. Monetization, the 1.0.1
     verify-owed list and the standing 1.0.x items are carried unchanged: not re-verified this sweep.
     Confidence 0.8. -->
<!-- Review: Kev + claude-opus-5.5, 2026-10-26 — the search head (#713) joins Now, flagged off, its teacher pass,
     paired arm and threshold ruling owed. -->
<!-- Review: Kev + claude-opus-5.5, 2026-10-26 (review fold) — the search head bullet counts 827 candidates (8 lexical
     near-copies of fixtures dropped) and names what the paired arm reads. Confidence 0.85. -->
<!-- Review: Kev + claude-opus-5.5, 2026-10-27 — the search head bullet carries the eval stage's numbers:
     the teacher pass on the fallback labeller, the gate missed, the stub kept, the threshold ruling owed.
     Confidence 0.85. -->
