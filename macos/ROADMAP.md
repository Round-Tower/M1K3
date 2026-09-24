# M1K3 — Roadmap

This is the living "what's next" doc — kept current, not append-only. For
architecture/build/test, see `CLAUDE.md`. For *why* a decision was made (model
swaps, phase rationale, the full session-by-session build log), see `PLAN.md` —
it's a signed historical record and stays that way; this file doesn't repeat it.
The release-by-release plan for the macOS 27 wave (1.0 → 1.1 → 1.2) lives in
`docs/GOLDEN_GATE_PLAN.md` § Roadmap; this file points at it rather than
copying it.

Last swept: 2026-09-18 — **1.0.0 is still in App Review; nothing is live yet.**
(The 09-17 sweep read "1.1.0 merged" as "1.1.0 shipped". Checked 09-18:
`itunes.apple.com/lookup?id=6780230835` → no listing; Kev: "we're releasing all
the recent work under 1.0.0 — we're still in review, and have the room.")
Merged to master and riding under 1.0.0: the "1.1.0" work (#362, 2026-09-16 —
Xcode 27 toolchain, typed AFM errors, Private Cloud Compute, CI guards), 5 new
Siri/Shortcuts intents (#366), AFM vision on macOS 27 + file-as-context (#367),
iOS image + file attach (#371). The site's App Store CTAs (#370) went out on the
same false premise and 404'd; reverted to TestFlight until the listing exists.
⚠️ The build in review (Mac 362) predates all of that AND carries a dead
sandboxed `m1k3` helper (#376) — a new build has to be attached before release.

---

## Now — 1.0.0 in review, the recent work rides under it

### Landing (open PRs)

- ~~**#370** site: TestFlight CTAs → App Store~~ — merged on a false premise, reverted 09-18; re-land it the day the listing is live.
- **#371** iOS: image + file attachment on iPhone/iPad + Mac help-text fix
  (review pending).
- **#372** agent: mid-conclusion ACTION prose now streams (#329 fix, review
  pending).

### Next picks

- **#303** Lil "What can you do?" 2/3 answers close on the decline line — needs
  an in-app eval gate before any prompt change (the capabilityMove shipped in
  #338 but the rate barely moved).

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
- WhisperKit 0.18 → 1.1: probe-first, post-launch only.

### Standing 1.0.x items (status lives in `docs/GOLDEN_GATE_PLAN.md` § 1.0.x)

- **Prefix prewarm: n ≥ 5 in-app rerun owed** (turn-1 2.7 s vs 5.8 s at n = 2).
- **The Mini palette call (Kev):** 16-tool palette puts ~3.9k of Mini's 4,096
  in the fixed prompt. Levers: smaller palette, shorter descriptions, or
  `toolCallingMode(.disallowed)` for small talk (now available in 1.1.0).
- Mini's invented user threads; the verbatim-recital hardening (#111).

---

## Next — the releases

### "1.1.0" — MERGED 2026-09-16, riding under 1.0.0 (`docs/GOLDEN_GATE_PLAN.md`)

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
  1.1.0); the small-talk gate stays rejected ("brittle both ways", 2026-06-12).
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
  `toolCallingMode(.disallowed)` (available since 1.1.0).
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
