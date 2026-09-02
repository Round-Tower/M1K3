# iOS + visionOS port — the derisk spike (2026-07-06)

> Living doc for bringing the **native SwiftUI M1K3** (this `macos/` app) to iOS and
> visionOS as one shared, RAM-gated adaptive shell. This first pass is a **derisk
> spike**: declare the platforms, prove the library graph compiles for iOS/visionOS,
> guard the few macOS-only leaves, and inventory the real runtime work — *before*
> building the app target / UI / TestFlight lane. Kev's decision (2026-07-06):
> mobile is THIS app, not the KMP `app/` surface. (The "iOS = KMP" note in
> `tools/release/README.md` §3 was reconciled when the shell landed — done.)

## What the spike proved

The package is protocol-seam first, so the macOS lock-in lives in the `M1K3App/`
shell — **not** in the library graph. After declaring `.iOS(.v26)` + `.visionOS(.v26)`
(`Package.swift`) and two small guards, **every library product compiles for iOS**
(verified via `xcodebuild -destination 'generic/platform=iOS Simulator'`, Xcode 26.6):

| Product | iOS | Notes |
|---|---|---|
| M1K3Knowledge, M1K3Memory, M1K3Inference | ✅ | pure logic + GRDB; `MemoryStore` was pre-annotated "works unchanged on iOS" |
| M1K3MLX | ✅ | the full MLX/Metal graph cross-compiles |
| M1K3Kokoro | ✅ | MLX backend since 2026-07-18 (was ONNX Runtime); see the RESOLVED note below |
| M1K3WhisperKit | ✅ | after the M1K3Calls guard |
| M1K3MemoryViz, M1K3Avatar | ✅ | RealityKit; `ConstellationPalette` was already `canImport(AppKit)`-guarded |
| M1K3Chat, M1K3Agent | ✅ | FoundationModels (`@_weakLinked`) needs **no** availability change at deployment floor 26 |
| M1K3Calls | ✅ | after the ScreenCaptureKit guard |
| M1K3MCPKit, M1K3MCP | ✅ | after the `homeDirectoryForCurrentUser` guard |

`swift test --parallel` on macOS stayed green (**1749 tests / 258 suites at the
time of the spike** — the live count has grown well past that since; ROADMAP.md
carries the current number), so the platform declaration + guards + memory-band
changes were non-regressive to the Mac build.

**visionOS** (`generic/platform=visionOS Simulator`, representative spot-check): M1K3MLX,
M1K3Calls, M1K3MCPKit, M1K3Chat, M1K3Avatar all ✅. **One dependency gap, not our code:**
`M1K3Kokoro` ❌ — the prebuilt `onnxruntime.xcframework` (Microsoft's SPM package) **ships
no visionOS slice** ("no library for this platform was found"). It has an iOS slice (Kokoro
builds for iOS), just not xrOS. Phase-2 options: exclude M1K3Kokoro from the visionOS
product and fall back to AVSpeech TTS on Vision Pro, or wait for an upstream xrOS binary.
Nothing in M1K3's own source blocks visionOS.

> **RESOLVED 2026-07-18 — the xrOS gap above is gone.** `M1K3Kokoro`'s ONNX Runtime
> backend was replaced with a pure-MLX one (a vendored StyleTTS2/Kokoro port, MIT,
> `Sources/M1K3Kokoro/MLX/Vendored/`, from Blaizzy/mlx-audio-swift) — MLX/MLXNN/MLXFFT/
> MLXFast already build for visionOS (same graph M1K3MLX already proved ✅ above), so
> `M1K3Kokoro` needs no more platform exclusion or AVSpeech fallback on Vision Pro on
> dependency grounds. `swift build` for the package targets `.macOS/.iOS/.visionOS`
> stays green post-swap (`swift build`/`swift test --parallel`, this session). Kokoro is
> still not WIRED into the `M1K3iOSApp/` shell's UI (a separate, still-open Phase-2
> product decision — see the shell inventory below), but the dependency-level blocker
> this note originally described no longer exists.

## The two real compile breaks the probe found (now fixed)

1. **`ScreenCaptureKit`** — `Sources/M1K3Calls/StereoCallRecorder.swift`. Far-end
   (system-audio) call capture is ScreenCaptureKit, which is macOS-only (no iOS/visionOS
   equivalent; ReplayKit is a different foreground-consent model). The whole recorder is
   now `#if canImport(ScreenCaptureKit)`-guarded (it's only self-consumed). On mobile the
   feature is simply absent — a Phase-2 product decision, not a silent stub.
2. **`homeDirectoryForCurrentUser`** — `Sources/M1K3MCPKit/MCPServer.swift:33`,
   unavailable on iOS. Now `#if os(macOS)` uses it (byte-identical Mac behaviour); iOS/
   visionOS take `NSHomeDirectory()` (the app's home *is* its container there).

## Memory band + tier gate (shipped in the spike, TDD'd)

The iOS jetsam budget is a fraction of physical RAM, so the Mac-tuned budgets would
push a mobile app toward jetsam. Two pure, tested policy changes (desktop stays the
default — zero Mac behaviour change):

- **`MLXMemoryBudget.DeviceProfile{.desktop,.mobile}`** — `.mobile` caps the MLX
  back-pressure ceiling at 4 GB (vs the 12 GB Mac app ceiling), so a 4-bit 4B
  brain + KV fits and MLX yields before the OS jetsams. Applied via `#if os(iOS) ||
  os(visionOS)` in `applyOnce`.
- **`BrainTier.recommended(…, platform:)`** — `.mobile` never recommends Big
  (gemma-4-12B ≈7.4 GB at inference exceeds any current mobile budget); Lil only on
  ≥16 GB (iPad Pro / Vision Pro); everything smaller stays on **Mini** (Apple
  Foundation Models, no MLX footprint). iPhones therefore land on Mini by design.

Both ceilings are tunable and marked verify-by-launch (confirm against
`os_proc_available_memory()` on real devices when the shell lands).

## Phase 2 — the shared adaptive shell (NOT in this spike)

The library graph is portable; the remaining work is the front end and the runtime seams:

1. **AVAudioSession lifecycle** (the top item) — absent repo-wide (0 hits). iOS/visionOS
   need a `.playAndRecord` session + interruption/route handling behind the existing
   `SpeechProvider`/`TranscriptionProvider` seams before mic or playback works. Compiles
   today, silent at runtime.
2. **The app shell** — `M1K3App/` is an AppKit menu-bar app (`NSApplicationDelegateAdaptor`,
   `MenuBarExtra`, single-`Window`/`Settings` scenes, `.hiddenTitleBar`, launch-at-login).
   A fresh SwiftUI scene graph per platform; `NSColor`→`UIColor`, `NSImage`→`UIImage`, four
   `NSViewRepresentable`→`UIViewRepresentable` wrappers (QuickLook/WebKit/GlassBackground/Artifact),
   `NSPasteboard`/`NSWorkspace` call sites.
3. **In-app MCP server** — `LocalMCPHTTPServer` (NWListener on 127.0.0.1:4242) compiles on
   iOS but its "resident, peer-reachable" premise is meaningless there (no desktop agents
   dialing in; background sockets get suspended). Keep on macOS (+ visionOS-windowed);
   exclude from the iOS shell surface.
4. **Kokoro EP** — no CoreML execution provider wired (CPU only); acceptable for the spike,
   flag for on-device TTS perf.
5. **Entitlements / Info.plist** — drop the macOS `app-sandbox` / `audioanalyticsd`
   mach-lookup exceptions; iOS mic is gated by `NSMicrophoneUsageDescription` (already
   present) + AVAudioSession; add `UIBackgroundModes` (audio) if voice must persist.
6. **App target + scheme + icons + Xcode Cloud iOS/visionOS archive → TestFlight lane**
   (the existing lane is macOS-only).
7. **visionOS spatial treatment** — the 3D avatar + memory constellation are spatial-native;
   the differentiated "wow" that neither Mac nor phone gives.

## Full UI parity roadmap (planned 2026-07-06, after the on-device harness worked)

The compile spike + the running harness (`M1K3iOSApp/`, real engine + real pixel-face
avatar on an iPhone 17 Pro, both Mini and Lil verified on device) prove the engine and
the brand port. The road to a shipping iOS/visionOS app with UI parity:

**Keystone — split `AppEnvironment`.** The macOS composition root imports AppKit and
wires every store/provider/controller; it's the one thing everything depends on.
Extract a portable `M1K3Core` (stores, embedder, brains, chat + voice controllers,
memory) from the macOS-only shell (NSApp lifecycle, menu bar, windows, System Settings
deep-links). Then the Mac app and the iOS/visionOS shell wire the SAME core. Delicate —
it's load-bearing and only tested through the Mac app today.

- **Phase A — Real chat (the spine).** Replace the harness's raw `generate` with the
  `M1K3Chat` pipeline via the core: streaming (face speaks token-by-token), RAG +
  documents-first, native tool-calling, multi-conversation history, copy, reading modes
  (bionic/dyslexia focus reader), generation stats, artifact/WebView panel (UIViewRepresentable).
- **Phase B — Voice.** AVAudioSession lifecycle (the one true blocker) behind the
  SpeechProvider/TranscriptionProvider seams; voice mode (avatar hero + karaoke +
  push-to-talk), Kokoro TTS (iOS ✓; visionOS dependency gap RESOLVED 2026-07-18 —
  the MLX backend has no xrOS slice problem, see above), WhisperKit/Apple STT,
  interruption/route handling.
- **Phase C — Shell & navigation (iOS-native, not a port).** TabView/NavigationStack
  for Chat / Memories / Documents / Settings; onboarding + capability ladder. The
  menu-bar app's iOS soul: Home/Lock-Screen widgets, App Intents/Shortcuts
  (already in the codebase), a Live Activity for long thinks, a Control Center control.
- **Phase D — Spatial (visionOS), the flagship.** The avatar as a volumetric companion +
  the 3D memory constellation (M1K3MemoryViz, already green) as a walkable field.
- **Phase E — Distribution.** iOS/visionOS entitlements (drop macOS sandbox/mach-lookup,
  add background-audio if voice persists), icon renditions, an Xcode Cloud iOS/visionOS →
  TestFlight lane, device-tune the memory cap (os_proc_available_memory).

Sequencing: keystone → A is the spine; B and C parallelize once the core exists; D is the
flagship follow; E rides alongside. Not ported: the in-app MCP HTTP server (meaningless
on iOS — no desktop agents dialing in); stays macOS (+ visionOS-windowed).

_Signed: Kev + claude-opus-4-8, 2026-07-06, Confidence 0.9 (every "compiles for iOS" row
verified by an actual `xcodebuild` per product; macOS `swift test` 1749/258 green proves
non-regression; the two guards + memory band are the only source changes and are
TDD-pinned. Honest caveats: builds are compile-green only — AVAudioSession, the UI shell,
and on-device MLX memory behaviour are Phase-2 verify-by-launch; the 4 GB mobile ceiling
and the ≥16 GB Lil threshold are tunable constants, not yet device-measured). Prior: Unknown._

---

## 2026-07-06 (later) — the shared shell SHIPPED (Phase A + C, iOS **and** visionOS compile-green)

The derisk harness has grown into the **real, multi-screen shared adaptive shell** —
not a mock, not the throwaway harness. The lead call was deliberate: rather than the
risky keystone surgery on the Mac's `AppEnvironment` (the shipping product's composition
root, AppKit-bound and only tested through the Mac app — I can't runtime-verify it without
a device), the shell gets its **own** portable composition root that wires the SAME
`swift test`-covered package graph. **The macOS `AppEnvironment` is untouched → zero
regression risk to the shipping Mac product** (proved: 1749/258 still green).

### What shipped (`M1K3iOSApp/`, one target per platform)

- **`AppCore.swift`** — the mobile composition root. Wires `KnowledgeStore` (hybrid RAG),
  the temporal `MemoryStore`, `HashingEmbeddingService`, a `SwappableInferenceProvider`
  slot (Mini = Apple Foundation Models, Lil = MLX Qwen3-4B, re-pointed on brain switch so
  the transcript survives), the always-on tool-calling `AgentRAGResponder` (its own iOS
  factory — knowledge + web tools; no CoolHead/voice plumbing), a persisted `ChatSession`
  (`GRDBChatHistoryStore` + `ProviderConversationTitler`), `DocumentIngester`, and the
  pixel-face avatar. Container paths use `NSHomeDirectory()`/`applicationSupportDirectory`
  (no macOS-only `homeDirectoryForCurrentUser`).
- **`ChatScreen.swift`** — the spine: real grounded streaming chat over `ChatSession`, the
  avatar as hero→dock, brain-load progress, asymmetric bubbles.
- **`RootView.swift`** — first-run onboarding gate → `TabView` (Chat / Memories / Documents
  / Settings), iOS-native navigation (not a port of the menu-bar app).
- **`DocumentsScreen`** (list + `fileImporter` ingest + delete over the real ingester),
  **`MemoriesScreen`** (live count + hybrid `MemoryStore.recall`), **`SettingsScreen`**
  (mobile-safe brain picker, web-search toggle, AFM availability, about),
  **`OnboardingScreen`** (`BrainTier.recommended(platform:.mobile)` — iPhones land on Mini,
  ≥16 GB iPad Pro / Vision Pro can pick Lil), **`MessageBubble`**, **`GlassCompat`**.
- **`project.yml`** — `M1K3iOS` deps expanded to the full portable pipeline; new
  **`M1K3visionOS`** target + scheme sharing the exact source list & deps (YAML anchors).

### The three portability fixes this pass found (compile-verified, not asserted)

1. **`IOKit` is macOS-only** — `M1K3AgentTools/SystemStatusProviding.swift` imported
   `IOKit.ps` for the battery lane (the spike's table never covered `M1K3AgentTools`). Now
   `#if canImport(IOKit)`-guarded; macOS byte-identical, iOS/visionOS return `nil` battery
   (already `Optional` — nil on a desktop Mac too, so the tool degrades cleanly). A
   `UIDevice` battery lane is a follow (it needs MainActor hops the nonisolated seam avoids).
2. **`glassEffect(_:in:)` is unavailable on visionOS** — the shell's glass chips route
   through a `.m1k3Glass(cornerRadius:tint:)` helper: Liquid Glass on iOS, `.regularMaterial`
   on visionOS. One call site to evolve when the Phase-D spatial treatment lands.
3. **`@Sendable` responder closures can't read MainActor statics** — the persistence keys
   are `nonisolated static let` (the Mac `AppEnvironment`'s own fix).

### Verification (this session)

| Gate | Result |
|---|---|
| `xcodebuild -scheme M1K3iOS -destination 'generic/platform=iOS Simulator'` | **BUILD SUCCEEDED**, 0 errors |
| `xcodebuild -scheme M1K3visionOS -destination 'generic/platform=visionOS Simulator'` | **BUILD SUCCEEDED**, 0 errors |
| `swift test --parallel` (macOS non-regression) | **1749 tests / 258 suites passed** |

The MLX Metal graph links for **both** the iOS and visionOS simulators (the storm ran per
arch). Verification ceiling is **compile-green** — the simulator can't run MLX (no Metal
for it), so on-device run is verify-owed, same as the spike.

### Still to do (honestly device/runtime-gated — NOT claimed done)

- **Phase B — Voice.** `AVAudioSession` lifecycle behind the `SpeechProvider`/
  `TranscriptionProvider` seams; Kokoro TTS (iOS ✓; visionOS dependency gap RESOLVED
  2026-07-18 — MLX backend, no xrOS slice problem). Not wired in the shell.
- **On-device run** — MLX generation, memory behaviour under the 4 GB mobile ceiling, the
  streaming feel, first-run onboarding, AFM availability on real AI-off hardware.
- **Phase D — Spatial (visionOS flagship)** — volumetric avatar + walkable memory
  constellation. The shell renders as a window today; `m1k3Glass` is the seam to upgrade.
- **Phase E — Distribution** — ~~iOS/visionOS icons~~ (DONE 2026-07-20, see below),
  ~~entitlements, an Xcode Cloud → TestFlight lane~~ (DONE 2026-09-02, see the
  addendum at the end), device-tune the memory cap (`os_proc_available_memory()`
  on hardware — still owed).

### App icons (done 2026-07-20)

Both mobile shells shipped iconless until now. The two targets take **different**
routes, which is why the app-icon asset is the one thing the shared `MobileShell`
XcodeGen template does *not* carry — each target adds its own:

| Target | Asset | Wiring |
|---|---|---|
| `M1K3iOS` | `M1K3.icon` — the **same** Icon Composer document the Mac ships (`icon.json` declares `"squares": "shared"`) | `ASSETCATALOG_COMPILER_APPICON_NAME: M1K3` |
| `M1K3visionOS` | `M1K3visionOS/Assets.xcassets` — a hand-built `AppIcon.solidimagestack` | `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` (Xcode's default) |

**Icon Composer cannot author visionOS icons** as of Xcode 26.x — it covers iOS,
iPadOS, macOS and watchOS only. visionOS needs a layered image stack: 1–3 layers,
each a 1024×1024 PNG, where the **Back layer must be fully opaque** (actool errors
otherwise) and the Middle/Front layers stay transparent so the system can render the
parallax depth. The circular mask is applied by the system — layers are not pre-cropped.

The visionOS layers are generated, not hand-drawn: `tools/icons/build_visionos_icon.py`
derives them from the same wordmark art the Mac icon uses (isolating the leading pixel
"M" as the monogram, plus a soft bloom on the middle layer). Re-run it to regenerate.

Verified by build, not just by compile: the iOS bundle carries `CFBundleIconName = M1K3`
with a compiled `M1K3.iconstack`; the visionOS `Assets.car` carries
`AppIcon/{Back,Middle,Front}/Content` at LayerIndex 0/1/2.

> Note: the `MobileShell` target template (`project.yml`) replaced a pair of YAML
> anchors on `M1K3iOS` at the same time — a target's own `sources:` are *appended* to
> the template's, which is what lets the two platforms diverge on icons while still
> sharing one source list and dependency set.
- Trivial: the entry file is still named `M1K3iOSHarnessApp.swift` (now holds
  `struct M1K3iOSApp`); a rename is cosmetic and deferred to avoid re-verifying both builds.

### Review pass (folded before sign-off)

A `code-quality-reviewer` pass on `AppCore` + the screens caught that the hand-ported
brain-swap flow had dropped the Mac's hard-won guards. Fixed (all re-compiled green):
- **Data-loss (critical):** Return-key `send()` only checked non-empty, not `canSend` — a
  Return while warming/streaming cleared the draft then no-op'd, eating the message. Now
  guarded on `canSend`.
- **Stale progress clobber:** a `warmGeneration` token now invalidates an abandoned warm's
  late progress callbacks (a switch-to-Mini mid-download could otherwise render "Waking
  Mini… N%").
- **No-op guard:** re-selecting the already-warm brain no longer tears down its KV/persona
  cache; **`releaseMemory()`** is called on every discarded MLX provider (it was leaking a
  Metal allocation against the 4 GB mobile ceiling); the cold-launch double-instance is
  gone (warm reuses the slot's provider).
- **Readiness honesty:** Chat now shows *why* it can't answer (AFM unavailable / brain
  warming) instead of a silently-disabled button; the ingest banner auto-dismisses and a
  0-chunk ingest reads as "no indexable text," not a success.

Deferred (noted, non-blocking): make AFM availability Observation-tracked (poll on
foreground); the reviewer's principled call — extract the brain-swap state machine into a
shared, `swift test`-covered package type both apps use, rather than hand-porting the Mac's
logic a third time. That's the right next refactor.

_Signed: Kev + claude-opus-4-8, 2026-07-06 (shell delivery), Confidence 0.85 (both platforms
BUILD SUCCEEDED via real xcodebuild with the true exit code read from the log — NOT a
wrapper's exit, per the standing false-success trap; macOS 1749/258 green proves the one
package edit is non-regressive; every API was pinned against the Mac's ground-truth wiring
before writing. Honest caveats: compile-green only — on-device MLX run, voice, and the
spatial flagship are named verify-owed, not done; the shell is uncommitted in the working
tree, as the goal framed it — committing fires the TestFlight-adjacent pipeline and is
Kev's call). Prior: Kev + claude-fable-5 (the spike + harness)._

---

## Addendum — 2026-07-07: the DRY relocation + mobile memory ON (commit 1fcf13f5)

The "refactor a third time" the delivery block flagged got done. Two app-target-only
helpers moved DOWN into the package so both shells share one copy:

- **`SwappableEmbeddingService`** → `M1K3Knowledge` (beside the `EmbeddingService`
  protocol; the last stranded member of the Swappable\* family). No new dep edge.
- **`DistilledFactGraphAdapter`** → a **new leaf module `M1K3MemoryChatBridge`**
  (deps exactly `[M1K3Chat, M1K3Memory]`). NOT folded into `M1K3Chat` — that would
  force `Chat→Memory` and break the documented "Chat must not depend on Memory" seam.
  Nothing depends back on the bridge, so it's cycle-free.

With the adapter shared, **`AppCore` now wires the same `MemoryDistillationCoordinator`
the Mac uses** (`memoryAutoCaptureKey`, default ON): durable facts distil from chat into
the corpus AND mirror into the temporal graph. `MemoriesScreen` recall is the read side;
this is the write side. So the Memories tab is real on mobile now, not a placeholder.
(Runtime firing is verify-by-launch — the `ChatSession` scheduling is package-pinned,
the `AppCore` glue has no iOS test bundle.) Verified: `swift test` 1752/260 + Mac/iOS/
visionOS xcodebuild all BUILD SUCCEEDED.

_Signed: Kev + claude-opus-4-8, 2026-07-07 (DRY + mobile memory), Confidence 0.85._

---

## Addendum — 2026-07-18: the Mac-feel aesthetic pass (feat/ios-aesthetic-pass)

First pass at closing the LOOK gap Kev named ("the iOS app doesn't have the Mac
aesthetic we nailed"). All composition of already-shared, already-TDD'd pieces —
no new policy logic:

- **Reactive avatar backdrop** (`M1K3iOSApp/ChatBackdrop.swift`): once a
  conversation starts, the pixel face stops shrinking to a 76pt dock and becomes
  the full-bleed background — bloom when idle, recede (dim/blur/scale) while an
  answer streams or the user is composing. Drives the shared
  `ChatBackdropTreatment` (package-tested); one RealityView at a time (the hero
  hands off to the backdrop). `isComposing` is broader than the Mac's
  `!draft.isEmpty` — keyboard focus alone recedes, because the keyboard
  shortens the viewport on a phone.
- **Reading modes on mobile**: `ReadingMode.swift` + `ReadingText.swift` joined
  `&mobileShellSources`, with the OpenDyslexic-{Regular,Bold}.otf resources
  (`BundledFonts.register()` already listed them; the resource lines make the
  registration real). Settings gains a Reading section (picker + live preview).
- **FOLLOWUPS chips rendered**: the shared `ChatSession` was already populating
  `message.followUps` on iOS — `MessageBubble` now renders the chips
  (`.complete`-gated, tap-to-send via `core.send`), with the Mac's
  `LegibilityScrim` treatment on flat assistant turns over the live backdrop.
  Autoscroll also fires on chip arrival (no text change at `.complete`).
- **Platform-honest copy**: `BrainTier.detail` for Lil said "Runs entirely on
  your Mac" on an iPhone (caught on-simulator) — now `#if os(macOS)` branched.

Review folds (multi-lens review, all adversarially confirmed): chip taps now
share the input bar's `isResponding` gate (a mid-stream tap was silently eaten
AND the avatar epilogue bloomed the backdrop over streaming text); the backdrop
is opt-out-able (Settings → Appearance) and Reduce Transparency disables it;
and `ChatBackdropTreatment.animatesMotion` finally has a consumer —
`AvatarView`/`CRTOverlay` gained a `paused` flag (recede/still/Reduce Motion
render one frame and stop the 30fps clocks), wired on BOTH platforms
(`ChatBackdrop` + the Mac's `AvatarChatBackground` via `AvatarSurface`;
companion/constellation surfaces are a logged follow-up).

Verify-owed (named): backdrop legibility + bloom/recede feel on device; the
paused-face look on both platforms (one crisp frame, no drift); CRT canvas +
full-bleed RealityView thermals on A-series in the BLOOM state (receded/still
are now quiet); OpenDyslexic rendering on device; chip frequency on the mobile
ladder (Mini/Lil emit FOLLOWUPS less reliably than Big).

_Signed: Kev + claude-fable-5, 2026-07-18 (Mac-feel pass), Confidence 0.85
(composition of TDD'd shared pieces; sim-verified live — bloom/recede/scrim/
streaming seen working; on-device feel + thermals verify-owed as named).
Prior: Kev + claude-opus-4-8 (the shell this restyles)._

---

## Addendum — 2026-07-28: the 3D companions come to the phone + a design polish

The mobile shell was **pixel-face only** — the five 3D companions (Fox, Inkfish,
Sparrow, Gecko, Colobus) already shipped in `M1K3Avatar`'s bundle but nothing on
iOS/visionOS could render them (the render path was AppKit-bound, Mac-only). This
pass brings them across and adds the picker, following the exact pattern
`AvatarView` set (port cross-platform, then add to the `MobileShell` template).

### What shipped

- **`CompanionDefaults` (M1K3Avatar)** — the companion/shading UserDefaults
  spellings, hoisted into the package so BOTH composition roots share one source
  of truth. Before this, `CompanionAvatarView` read `AppEnvironment.*` keys — a
  Mac-only type it couldn't reference from the shell. `AppEnvironment+VoiceMode`
  now aliases these (same string VALUES → no migration; a persisted choice reads
  back identically).
- **`CompanionAvatarView` + `PhosphorMaterial` cross-platform** — `#if
  canImport(AppKit)/UIKit` guards (the one `NSColor` fill-light extraction); the
  camera is `#if !os(visionOS)` (visionOS ignores in-scene cameras — sized in
  metres there instead). Added to the `MobileShell` sources.
- **`AvatarSurface` (shell)** — the iOS sibling of the Mac's resolver: pixel-vs-
  creature (identity kept stable — **no** `.id(spec.id)`; the creature reloads in
  place, see the swap→black fix below), read by the chat hero, the reactive
  `ChatBackdrop`, onboarding, and the Settings live preview. One place decides
  the face; every surface renders it.
- **`CompanionPickerSection` (shell)** — the Mac's live-preview + glass face-card
  vocabulary in iOS Settings; the skin (shading) picker shows only for a creature.
  Self-extends from `CompanionSpec.all.filter(isInstalled)`.
- **Design polish** — starter-prompt chips on the blank chat canvas (gated on
  `brainReady` = `!isResponding && isReady` + tap-to-send, the same gate the
  follow-up chips use — NOT `canSend`, which also requires a non-empty draft the
  empty canvas never has); a warmer onboarding (a lively greeting beat that settles
  + an "everything runs on your device" line).

### The visionOS gotcha this pass found (compile-verified)

**RealityKit `CustomMaterial` surface shaders are macOS/iOS only.** The xrOS SDK
ships no `RealityKit.h` Metal header and no `CustomMaterial` (visionOS uses
`ShaderGraphMaterial`), so `Phosphor.metal` + `PhosphorMaterial.swift` **cannot**
compile for visionOS. They live on the `M1K3iOS` target alone (not the shared
`MobileShell` template), and `CompanionAvatarView` `#if !os(visionOS)`'s out its
shading calls. On Vision Pro a companion shows its **baked textures** (no
phosphor/cel) — the skin picker is hidden there. Creatures themselves render on
all three platforms.

### The RealityView "swap → black" trap (found on-sim, refactored)

On-simulator verification (driven UI) surfaced a real bug the first cut shipped:
the companion live-preview rendered the FIRST creature but went **permanently
black on any switch** — creature→creature AND creature→pixel. Root cause was the
iOS RealityView lifecycle: `AvatarSurface` used `.id(spec.id)` to force a rebuild
on switch, but **recreating a RealityView within a persisted iOS view tree renders
the new one black** (the pixel face survived because it populates its content
synchronously; the creature populates *after* an `await` on the USDZ load, which a
swapped-in iOS RealityView doesn't present).

The fix (this pass): `CompanionAvatarView` was reworked to a **single stable
RealityView** — a persistent `root` + lights + camera built once, and the creature
mesh swapped as `root`'s children **in place** (a monotonic reload token drops
superseded loads). The iOS `AvatarSurface` drops `.id` so the view identity
persists (the Mac's `AvatarSurface` keeps `.id` — recreation renders fine on
macOS, so zero Mac change). Two supporting robustness fixes rode along: a
process-level clip cache (RealityKit's `Entity(contentsOf:)` can hand back an
animationless clone on repeat loads) and "render the static mesh rather than
nothing" when an idle clip is missing.

### Verification

| Gate | Result |
|---|---|
| `xcodebuild -scheme M1K3iOS` (iPhone 17 Pro sim, iOS 27) | **BUILD SUCCEEDED** |
| `xcodebuild -scheme M1K3visionOS` (Vision Pro sim) | **BUILD SUCCEEDED** |
| `xcodebuild -scheme M1K3` (My Mac) | **BUILD SUCCEEDED** (non-regressive) |
| `swift test --parallel` | **2186 tests / 314 suites passed** |
| iOS Simulator, driven UI | pixel face renders + switches cleanly; **creature render unconfirmed** (see below) |

**⚠️ Verify-owed — creature render on a real device (the headline caveat).** The
iOS **Simulator is not a reliable oracle for RealityView**: async-populated content
in a swapped-in RealityView does not present there, so the driven-UI check could
NOT confirm the 3D creatures render on iOS (only the synchronous pixel face was
confirmed). This is compile-green + architecture-sound, but **whether Fox/Inkfish/
Sparrow/Gecko/Colobus actually render on an iPhone / Vision Pro is verify-by-launch
on real hardware** — deliberately shipped to PR with this flagged (Kev's call) for
a device check + review to drive any follow-up. The build installs to a connected
device cleanly.

Other named follow-ups: visionOS companion framing (the 0.45 m absolute-size guess
vs a proper scene-bounds fit) is Phase-D; `paused` isn't threaded to the creature
surface yet (same logged follow-up as the Mac); navigation/section structure left
as-is — the adaptive sidebar is already sound, restructuring blind wasn't worth the
regression risk.

_Signed: Kev + claude-opus-4-8, 2026-07-28 (companions-on-mobile + polish +
RealityView swap-fix), Confidence 0.7 (all three targets BUILD SUCCEEDED via real
xcodebuild; macOS 2186/314 green proves non-regression; the CustomMaterial/visionOS
split is compile-proven; the swap→black bug was found by driven-UI on-sim and the
in-place-reload refactor is architecture-sound. The 0.7 (not higher) is deliberate:
the Simulator can't confirm the 3D creatures render on iOS — that's the named
verify-owed, shipped to PR flagged for a real-device check, Kev's call). Prior: Kev
+ claude-fable-5 (the Mac-feel pass this builds on)._

---

## 2026-07-29 — The voice-first + navigation pass (no tab bar, None companion, Liquid-Glass parity)

Kev's direction: the chat IS the app. Five moves in one pass:

- **Navigation restructure.** The bottom tab bar is gone: `RootView` is now
  `NavigationStack { ChatScreen }`. Settings is a toolbar push (gear); Memories and
  Documents live in a **Workspace** section inside Settings (their own
  `NavigationStack`s stripped — they're pushes now). The `"M1K3"` navigation title is
  removed (the wordmark already owns the empty-state hero); a **New chat** toolbar
  button rides `ChatSession.startNewConversation()` (disabled when empty/responding —
  the session's own no-op guards, surfaced honestly). On visionOS this also retires
  the tab ornament that rendered as dark squares (the V0 finding, closed by removal).
- **Voice-first mode wired on mobile** (`AppCore+Voice.swift`, `VoiceScreen.swift`) —
  the package-TDD'd `VoiceLoopController` over `AppleSpeechTranscriber` (on-device
  STT) + `AVSpeechProvider` (system TTS), `M1K3Voice` added to the `MobileShell`
  deps + mic/speech usage strings to both targets. Mobile-specific ground: an
  explicit `AVAudioSession` (.playAndRecord/.voiceChat, activated on entry, released
  on exit), gentler endpointing than the Mac's — **superseded 2026-08-11: both
  shells now share `EndpointCadence.conversational`, because those two hand-typed
  pairs came from the SAME "it cuts me off" complaint and drifted anyway; the
  endpointer also learns the speaker's own pause rhythm on top** — whole-answer
  turns for v1 (the Mac's
  sentence-streaming poller is a named follow-up). Entry via a toolbar waveform
  button; a true background exits the mode before the brain sheds (scenePhase hook).
- **Companion picker rework.** Cards are text-only (the generic pawprint glyphs said
  nothing — the live preview above is the picture) and a **None** choice ships on a
  package-pinned sentinel (`CompanionDefaults.noneID` + `hidesAvatar`, TDD'd): no
  hero face, no live chat backdrop, no Settings preview — just the conversation.
  Unknown/stale ids still fall back to the pixel face, never to a blank surface.
- **Liquid-Glass parity pass.** User bubbles match the Mac's exact treatment
  (`.regular.tint(.accentColor.opacity(0.2))`, rect 18); the input row and chip
  stacks share a `GlassEffectContainer` via the portable `M1K3GlassGroup` (Group on
  visionOS); input field glass at rect 22 (the Mac inputRow's radius).
- **Branch hygiene:** the `companion` Logger category from the companions PR was
  missing from the `M1K3Log.Category` catalogue (SubsystemGuard red) — case added.

Verification: both mobile targets BUILD SUCCEEDED; `swift test --parallel`
2191/315 green; the full flow driven live on the iPhone 17 Pro Max simulator
(starter chip → send → backdrop handoff → Settings push → None selection → calm-dark
chat → New chat → voice-mode cover incl. parked-idle honesty when the sim has no
recognizer). ★ Bonus evidence: a 3D creature (Sparrow) **rendered live as the chat
backdrop on the Simulator** via the in-place-reload path — softening (not closing)
the 07-28 "creature render unconfirmed on sim" caveat; real-device feel remains
verify-owed.

Verify-owed on hardware: the full spoken beat (mic TCC dialogs, echo/endpointing
feel, barge-in), speaker routing, and the answer path (Mini's reply never landed on
this sim run — AFM-on-sim flakiness, pipeline untouched today).

_Signed: Kev + claude-fable-5, 2026-07-29, Confidence 0.8 (every UI flow above
watched live on-sim; voice is adapter glue over test-pinned loop/endpointer with the
felt beat honestly device-owed). Prior: Kev + claude-opus-4-8 (this file)._

## 2026-07-30 — MetricKit adoption (#86): `M1K3Diagnostics` joins the `MobileShell` deps

The mobile shell now subscribes `MXMetricManager` too (`AppCore+MetricKit.swift`,
mirroring the Mac's `M1K3App/MetricKitCollector.swift`) — a small, separate
`MobileMetricKitCollector` rather than a shared app-target type, since
`M1K3App`/`M1K3iOSApp` are different compiled targets/apps and can't share app-glue
files directly. Both reuse the SAME pure decision logic
(`M1K3Diagnostics.MetricPayloadDigest` / `MetricRetentionPolicy`), so
`M1K3Diagnostics` was added to the `MobileShell` targetTemplate's `dependencies` in
`project.yml` (`project.yml:112`) — the first time this package pulls in a target
outside the RAG/voice/avatar core. Both iOS and visionOS SDKs ship
`MetricKit.framework`; its availability macros are `ios()`-keyed with no `xros()`
override, and visionOS inherits iOS availability in that case, so the same code
compiles for both `M1K3iOS` and `M1K3visionOS`. v1 surfacing on mobile is minimal —
persist to a bounded on-disk store + a `.notice` count line — there's no "Report an
issue" flow on this shell yet (that's Mac-only, `IssueReporter.swift`), matching the
task's documented fallback for a shell whose report surface doesn't exist.

_Signed: Kev + claude-fable-5, 2026-07-30, Confidence 0.75 (compile-verified for
iOS/visionOS; mirrors the SDK-header-verified Mac collector's shape but has no
device-run or MXMetricManagerSubscriber smoke test of its own, by mobile-shell
design). Prior: Kev + claude-fable-5 (this file)._

---

## Addendum (2026-09-02) — Phase E lands: the iOS → TestFlight lane

> **This doc is the port's build log; the live iOS plan is `macos/ROADMAP.md` §1
> (the parity ladder).** Everything after 2026-07-30 that isn't here — Brain at
> Home Phase C on the device side (PR #152: `BrainPairingScreen`,
> `BrainAtHomeSection`, `AppCore+BrainLink`, the `M1K3BrainLink` dep), the voice
> turn-boundary work (#118/#124/#129), the grounding-budget fix crossing to mobile
> (#101 → `AppCore.swift`) — is recorded in the ROADMAP and PR history, not
> re-narrated here.

**What the Mac's 1.0.0 (265) TestFlight build (2026-09-01) showed about iOS:** the
whole lane was three facts apart from working.

1. **The bundle ID was the wrong shape.** The mobile targets carried
   `app.m1k3.ios` / `app.m1k3.visionos` — reasonable-looking, but the developer
   portal registers `app.m1k3` as **UNIVERSAL** and the ASC app record (id
   6780230835) already holds IOS + VISION_OS 1.0.0 version drafts. Universal
   purchase means one record, one identifier, every platform. A suffixed ID has
   no record to land in and fails only at upload, after the full build. Both
   mobile targets now build as `app.m1k3` (`project.yml`). Immutable once a
   build ships — this is the one-way door, chosen deliberately: one listing,
   one rating pool, "Available on Mac · iPhone · iPad · Vision Pro".
2. **No privacy manifest on the mobile bundles.** The Mac sweeps
   `M1K3App/PrivacyInfo.xcprivacy` in with its directory; the `MobileShell`
   template cherry-picks and never listed it. Apple rejects an iOS binary
   without one. The template now ships the same file (zero tracking, zero
   collected data).
3. **No iOS entitlements at all.** New `M1K3iOSApp/M1K3iOS.entitlements` carries
   exactly one entry — `com.apple.developer.kernel.increased-memory-limit` — the
   lever that lets the 4 GB mobile MLX ceiling (`MLXMemoryBudget`) engage before
   the kernel's jetsam does. iOS needs none of the Mac's sandbox/network/file
   entitlements (all Info.plist usage keys or implicit).

Also folded in: `NSBonjourServices: [_m1k3._tcp]` on both mobile targets (iOS
gates Bonjour *browsing* on it — without it only the QR's `hosts=` dial-in
worked), `PRODUCT_NAME: M1K3` on both mobile targets (Xcode derives
`CFBundleName` from it even with an explicit plist — a plist `CFBundleName`
lost on the first local archive; the schemes keep their platform names), the
visionOS target's **own** generated Info.plist (the two
mobile targets were writing the same file), and `ci_post_clone.sh` resolving
packages against `CI_XCODE_SCHEME` instead of the hardcoded Mac scheme.

**The guard:** `tools/ci/check_store_targets.py` (+ unit tests) pins all four
invariants in the PR CI's project-guards job — red against the pre-change
`project.yml`, green after — so the next "reasonable-looking" rename fails in
seconds, not at upload. The fourth (all four iPad orientations declared, or
`UIRequiresFullScreen`) was added after run #272 archived and exported cleanly
and then died at "Preparing build for App Store Connect" with ITMS-90474.

**The lane itself** is one `PATCH` on the existing `Release` workflow: a second
`ARCHIVE` action (`platform: IOS`, `scheme: M1K3iOS`, App-Store-eligible), so a
master merge mints a Mac build and an iOS build with the same number in one run
(`docs/XCODE_CLOUD_RELEASE.md` §3). Sequenced AFTER this change merges — an iOS
archive of a still-suffixed master would just fail at upload.

**Verify-owed, in order:** the first iOS build reading VALID in ASC under
platform IOS · TestFlight install on Kev's iPhone 17 Pro (iOS 27 beta) · the
on-device smoke the July harness did but the shell never has (Mini chat, Lil
download + a turn under the memory entitlement, voice round-trip, the Brain at
Home ceremony with Bonjour now declared).

_Signed: Kev + claude-fable-5.1, 2026-09-02, Confidence 0.85 (the three facts are
read off the ASC API + developer portal the same day, not inferred; the guard is
red-then-green against the real file; the cloud upload is the still-unverified
step — nothing here is claimed to have reached TestFlight yet)._
