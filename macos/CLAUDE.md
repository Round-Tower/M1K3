# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Orientation

This directory (`macos/`) is the **live product**: M1K3, private on-device AI
with live voice, a knowledge graph, document memory, an embedded agent, call
transcription, a 3D avatar, and an MCP server. The **macOS 26 (Tahoe)** app
(`M1K3App/`, real Liquid Glass + on-device Foundation Models) is the primary
shipping surface, written in **Swift 6.2**. The same portable `Sources/` package
graph also drives a native **iOS 26 / visionOS 26** SwiftUI shell under
`M1K3iOSApp/` (the `M1K3iOS` / `M1K3visionOS` targets in `project.yml`) — a
distinct surface from the KMP `../app/` (that's the Android effort).

The parent `../CLAUDE.md` covers repo orientation (the legacy Python CLI was
cleared from the tree 2026-08-13 — git history before `7545b4a4` keeps it).
When working under `macos/`, this
file is the relevant one. Durable session history lives in
`../.claude/project-memory.md` (read it for in-flight threads and hard-won gotchas).
**`ROADMAP.md` is the current "what's next" doc** — kept live, not append-only.
`PLAN.md` is the historical build log / decision record (append-only, signed —
reconcile additively, never rewrite signed blocks); read it for *why* a decision
was made, not for what's next.

## Build & Test

```bash
# Run the fast TDD loop — the package builds & tests business logic without Xcode.
# Heavy MLX/Metal + WhisperKit integration is env-gated OFF by default.
swift test                                   # full suite (uses swift-testing, not XCTest)
swift test --parallel                        # what CI runs
swift test --filter M1K3KnowledgeTests       # one target
swift test --filter BrainCatalogueTests      # one suite
swift test --filter "BrainCatalogueTests/recommendsForRam"   # one test

# Build a specific module / the MCP executable without the Metal storm
swift build --target M1K3EvalTests           # M1K3Eval + M1K3Inference only (~no MLX)
swift build -c release --product M1K3MCP     # the stdio MCP server binary

# The SwiftUI app shell (needs Xcode 26 / macOS 26).
# project.yml is the source of truth; M1K3.xcodeproj is a gitignored build artifact.
xcodegen generate                            # regenerate the project after adding M1K3App/ files
xcodebuild -scheme M1K3 -destination 'platform=macOS' build | xcbeautify   # always pipe through xcbeautify
```

- **CI** (`../.github/workflows/ci.yml`) runs `swift test --parallel` on a
  `macos-26` runner with `M1K3_MLX_INTEGRATION=0`, plus a curated Python smoke
  subset for the legacy tree. PR CI also runs an `app-build` job (xcodegen
  generate + unsigned `xcodebuild -scheme M1K3` on `macos-26`) so app-shell
  compile breaks in `M1K3App/` fail at PR time, not only at release, and a
  `mobile-build` job (unsigned `M1K3iOS` + `M1K3visionOS` against the
  simulator SDKs) so the iOS/visionOS shell can't silently break either.
  The app targets build for distribution via Xcode Cloud → TestFlight
  (`M1K3` for macOS and `M1K3iOS` for iPhone/iPad, both archived by the one
  `Release` workflow into the single universal `app.m1k3` App Store record);
  pushing to `master` triggers that pipeline (a deliberate, user-gated
  action). `tools/ci/check_store_targets.py` pins the bundle-ID /
  privacy-manifest / Info.plist invariants the lane depends on.
- Tests use the **swift-testing** framework (`import Testing`, `@Test`), not
  XCTest.

## The metallib wall & on-device verification

`swift test` **cannot run MLX/Metal** — the metallib only resolves inside a
built `.app` bundle. So MLX/WhisperKit code is verified two ways:

1. **Unit tests** cover the pure policy layers (routers, scorers, budget math,
   tier metadata) against fakes — `M1K3_MLX_INTEGRATION=1` enables the heavy
   integration tests that actually download a model and generate (run locally,
   off in CI). `M1K3_AUDIO_INTEGRATION=1` likewise enables the real-speaker
   speech smoke (`EffectfulStreamingIntegrationTests`): it plays audio out of
   your speakers and its word clock is a real-time delegate correlation that
   starves under a loaded parallel run, so the default suite is silent and
   deterministic. Run it deliberately when touching speech. Note this is the
   SYSTEM voice — M1K3's own (Kokoro) is MLX/Metal and can't run under
   `swift test` at all.
2. **`SelfTest.swift`** (in `M1K3App/`) is the headless on-device harness. Drop
   a `~/Library/Containers/app.m1k3/Data/.m1k3-selftest.json` config file
   (keyed by env-var name), launch the built `.app`, and it runs the real
   pipeline (load / generate / RAM snapshot / TTFT / CHATEVAL) and `exit(0)`s.
   Keys: `M1K3_SELFTEST=1`, `M1K3_SELFTEST_MODEL`, `M1K3_SELFTEST_MEMLOOP=N`,
   `M1K3_SELFTEST_CHATEVAL=1` + `_CHATEVAL_BRAINS`/`_CHATEVAL_MLX_MODEL` (A/B
   override), `M1K3_SELFTEST_KEYEVAL=1` (keyword-query gap: bare vs instructed
   query arms), `M1K3_SELFTEST_MEMSTAT=1` (dream-cycle Tier-0 census: real-graph
   cosine histogram + eaten-correction ingest probe — read-only on the real
   container stores), `M1K3_SELFTEST_MEMBLOCK=1` (Tier-1 dated-memory-block
   probe: seeded dated contradiction through the real responder per brain),
   `M1K3_SELFTEST_OUT=<container path>`. This is the cleanest
   verify path — no UI, no MCP grace window or job deadline.

When a change touches MLX/Metal/RealityKit/voice, the convention is
**verify-by-launch**: state it as a named "verify-owed" rather than claiming it
proven from `swift test`.

## Architecture

The package is **protocol-seam first**: pure, dependency-free logic in the core
targets (so `swift test` drives TDD in seconds), with heavy backends (MLX,
WhisperKit, Kokoro/MLX, GRDB) isolated into their own targets behind protocols
so they never weigh down the core build. The SwiftUI app (`M1K3App/`) is a thin
shell that wires concrete backends to the seams; `AppEnvironment` (+ its
`AppEnvironment+*.swift` extensions) is the composition root.

**Module map** (`Sources/`):

| Target | Role |
|---|---|
| `M1K3LogCore` | Single source of truth for unified logging: the `app.m1k3` subsystem + category catalogue + `LogPreview`. Dependency-free so every target references it. |
| `M1K3Knowledge` | RAG corpus: GRDB store, embeddings, hybrid (vector + FTS) search, RRF fusion, grounding gate. The knowledge primitives. Also `SwappableEmbeddingService` (the runtime embedder-swap façade). |
| `M1K3Memory` | Temporal memory **graph** (atomic facts + typed edges + recursive-CTE traversal). Separate DB/consent lifecycle from the corpus. |
| `M1K3MemoryViz` | 3D memory constellation (RealityKit over a pure layout model). |
| `M1K3Inference` | The `InferenceProvider` seam + `BrainTier`. Backends are thin adapters. No external deps. |
| `M1K3Agent` | Local agent: ReAct + native tool-calling loop over the inference seam; tools injected. |
| `M1K3LanguageModel` | WWDC26 LanguageModel bridge (ADR 0001) — local mirror of Apple's FoundationModels surface + escalation-ladder policy. |
| `M1K3Eval` | Model-evals enclave: fixtures + deterministic heuristic scorer + cross-brain report (pure; the model-running half rides SelfTest). |
| `M1K3KnowledgeTools` / `M1K3AgentTools` | Knowledge-backed agent tools (search/list/get document). |
| `M1K3Chat` | RAG chat brain: embed → hybrid search → documents-first prompt → generate; multi-conversation history. Also the `MemoryDistillationCoordinator` (distils durable facts from chat). |
| `M1K3MemoryChatBridge` | Leaf bridge (deps `[M1K3Chat, M1K3Memory]`): `DistilledFactGraphAdapter`, the Chat→memory-graph dual-write. Shared by BOTH the macOS app and the iOS/visionOS shell (relocated out of the app target). |
| `M1K3Voice` | TTS (`SpeechProvider`) + transcription (`TranscriptionProvider`) seams (system AVFoundation/Speech only). |
| `M1K3MLX` | **Heavy.** MLX embeddings + Gemma/Qwen generation on Metal. Conforms to the `EmbeddingService`/`InferenceProvider` seams. |
| `M1K3WhisperKit` | **Heavy.** WhisperKit on-device transcription (CoreML). Apple Speech is the always-available fallback behind the same seam. |
| `M1K3Kokoro` | **Heavy.** Kokoro neural TTS via a pure-MLX backend (a vendored StyleTTS2/Kokoro port, MIT, `Sources/M1K3Kokoro/MLX/Vendored/`; ONNX Runtime removed 2026-07-18 — the visionOS unlock) + M1K3's own G2P phonemizer. |
| `M1K3Calls` | Model-agnostic call intelligence: batch transcription + diarization + two-stage summarization protocols. |
| `M1K3Avatar` | 3D companion (RealityKit) + pure emotion/animation types + earcons. Per-clip companion USDZs as resources. |
| `M1K3MCPKit` / `M1K3MCP` | MCP server: testable tool handlers (`-Kit`) + the thin stdio executable (`M1K3MCP`) Claude spawns. |
| `M1K3MCPLog` | Opt-in Agent Interaction Log: a GRDB sink (conforms to `MCPCallLogSink`) capturing full MCP request+response text ONLY when the Settings toggle is on — since 2026-08-19 also the calling client's self-reported name (`client_name`, v2), which folds the Heartbeat timeline's per-client visits. Separate target so the PII-bearing capture stays out of the tool-dispatch core. |
| `M1K3Launch` | Launch-at-login (SMAppService seam) for the menu-bar app. |
| `M1K3Preview` | Review-panel router (link/file → `ReviewTarget`); QuickLook/WKWebView renderers live in the app. |
| `M1K3Diagnostics` | Privacy scrub + issue-report formatting + the diagnostic log partition for the secret-free "Report an issue" flow, plus the MetricKit payload digest (`MetricPayloadDigest`) and the bounded on-disk store's pure retention/pruning decision (`MetricRetentionPolicy`). Pure/dependency-free so the redaction + digest/retention rules are unit-pinned. |
| `M1K3Heartbeat` | The 2-hourly narrative pulse: pure schedule/quiet-hours/empty-pulse policies, the deterministic digest composer (the #102 guard — facts from code, never the model), `NarrativeGuard` (confabulation tripwire), and a capped GRDB pulse store (own file, one-tap Clear, backup- and diagnostics-excluded, never enters the chat transcript), plus `InteractionTimeline` — the pure fold behind the Heartbeat destination screen (pulses + agent calls → day-bucketed, per-client visits). The scheduler effect + resident-MLX render live in `AppEnvironment+Heartbeat.swift`. |
| `M1K3BrainServe` | Brain at Home — the LAN brain service for QR-paired devices: pure pairing state machine + tool-scope allowlist + route/SSE policies (TDD), the TLS-PSK NWListener shell (TLS 1.2 ECDHE_PSK — see `docs/BRAIN_AT_HOME_SPEC.md` §3 for why not 1.3), and the dnssd advertiser. App glue in `BrainServeController.swift`; default OFF. |
| `M1K3BrainLink` | Brain at Home, the DEVICE side (Phase C): the shared TLS-PSK wire (`PSKCredential`/`BrainServeTLS` live here now; M1K3BrainServe re-imports), the QR `PairingPayload` (compose + parse, one round-trip-pinned type — carries the Mac's LAN `hosts=` since first pairing has no Bonjour), client HTTP/SSE codecs pinned against the server's own frames, the `NWConnection` transport (URLSession can't do external PSK), the pairing ceremony (pair → poll-health-until-Approve), `HomeBrainProvider` (the Mac's brain as an `InferenceProvider` — refusals render as etiquette copy, never empty bubbles), and the device-side store (metadata defaults + Keychain PSK). MCP-free so the mobile shells link it lean. |
| `M1K3ScreensaverCore` | The M1K3 screensaver's pure model (Foundation-only, so the sandboxed `legacyScreenSaver` process links no app modules): the M mark geometry (`PixelMark`, same 5×7 map as the app icon), the ambient rain sim (`RainField`, deterministic), the presence copy (`PresenceFormatter`), and `ScreenSaverInstall` (the sandbox-safe install helper — status/path). The `.saver` bundle target (`M1K3Screensaver/`) draws it in AppKit; the app embeds the .saver and installs it via a Settings ▸ General button. |

**Brains** (`BrainTier.swift`): four tiers, three shown per device — **Mini** (Apple Foundation Models,
instant, no download) or, wherever Apple Intelligence is blocked, **pocket** shown as "Mini"
(`LFM2.5-1.2B-Instruct-4bit`, ~630 MB, since 2026-09-06; one Mini per device via
`BrainTier.offered(afm:)`; mobile floor 3.5 GB — the 3 GB A12 class can't build MLX's kernels), **Lil** (`Qwen3-4B-Instruct-2507-4bit-DWQ-2510`, since 2026-09-05 — the DWQ
recipe of the 2026-07-16 non-thinking refresh; the reasoning toggle is pinned off for the 2507 line),
**Big** (`gemma-4-12B-it-4bit`, since 2026-07-15 — 16GB selection floor).
First run is **Mini-first** (one screen, `HelloView` — instant AFM, nothing to
download); Lil/Big are opt-in upgrades surfaced after the first answer or in
Settings (`BrainPickerView`), not a three-way onboarding picker. The mobile
(iOS/visionOS) ladder tops out at Lil — Big is excluded on-device.
`BrainBacking` maps a tier to
`appleFoundationModels` or `mlx(modelID:)`. **Huge** (`Qwen3-8B-4bit`) was
retired 2026-07-02 (weakest tool-caller; the all-gemma reshuffle) — a persisted
`"huge"` migrates to `.big` via `BrainTier(persisted:)`. Current model choices
and their hard-won rationale (dense Qwen3 over the Qwen3.5 GatedDeltaNet hybrid;
gemma-4-12B rejected; OptiQ parked) are in `docs/MODEL_CHOICES.md`.

**Tool-calling routing** (`LocalAgent.run`): a brain with a resolvable tool-call
format runs **native** (`runNative`); otherwise the **ReAct** floor
(`runReAct`). Qwen3 → `.json`; gemma-4 → `.gemma4` (requires mlx-swift-lm ≥
3.31.4 — see `Package.swift`).

**MCP exposure (two surfaces):**
- **In-app HTTP MCP server** (`M1K3App/MCPHostController.swift`) — serves on
  `127.0.0.1:4242/mcp` while the app runs. This is the live way agents reach
  M1K3's voice/RAG/memory.
- **`M1K3MCP` stdio binary** — registered into Claude Desktop/Code; reads the
  app's sandbox store. See `docs/MCP_SETUP.md`. (`ask_m1k3` is submit-and-poll:
  ~8s inline grace, then a job id polled via `get_answer` — see
  `Sources/M1K3MCPKit/IntelligenceMCPTools.swift`. Since 2026-08-19 a slow
  turn runs to completion — the old 120s cap that cancelled good Big answers
  is now a 600s runaway backstop matching job retention; `list_jobs` recovers
  lost ids, and interim-Mini serves asks while a brain downloads.)

## Conventions specific to this repo

- **Bundle ID / log subsystem / Keychain / sandbox container are all `app.m1k3`**
  (renamed from `dev.murphysig.M1K3` on 2026-06-14 — translate any old ref on
  read). MLX LLM weights live **inside the sandbox container** under
  `~/Library/Containers/app.m1k3/Data/Library/Application Support/models/<org>/<repo>/`
  — moved OUT of `…/Library/Caches/models/` on 2026-08-02 (#92) because macOS
  purges Caches under disk pressure and really did eat the brains (twice in
  one afternoon, log-evidenced); `ModelStoreLocation` migrates a surviving
  Caches store across on first touch. `DEVELOPMENT_TEAM` is pinned in `project.yml` because a
  stable signing identity is load-bearing for persistent Keychain/TCC grants.
- **`Package.swift` mlx-swift-lm is on a main REVISION pin** (`e3d4a20e`,
  2026-09-05 — moved from `c97539da` for #516's MTP rewind fix, #533, #514
  and #575; all post-3.31.4 and untagged). Move back to a tag when one
  carries #516. `newCache(parameters:)` throws on this revision — every call
  site needs `try`. `mlx-swift` moved 0.31.4 → 0.31.6 in
  the same bump — main needs it (`DType.greatestFiniteMagnitudeArray`,
  `MLXArray.maskFill`). Dep bumps are probe-first (`swift package resolve`)
  because of the WhisperKit/swift-transformers `Tokenizers` clash landmine,
  and **any bump owes a gemma-4 NATIVE tool-call smoke** (tool-calling is why
  this dep moves) — the 08-08 bump took gemma-4 tool-use from 5/5 to **0/5**
  and only the smoke caught it (upstream #453's typed KV validation now
  *throws* on the caller `maxKVSize` that Gemma4Text had always silently
  ignored; see `MLXGemmaProvider.supportsCallerKVCapacity`). Run it with
  `M1K3_SELFTEST_CHATEVAL=1 M1K3_SELFTEST_CHATEVAL_BRAINS=big
  M1K3_SELFTEST_CHATEVAL_KINDS=tool-use`.
- **`xcodebuild` needs `-skipPackagePluginValidation`** since the mlx-swift
  0.31.6 bump (its `CudaBuild` plugin fails validation on an interactive
  build). CI already passes it; the release scripts gained it 2026-08-08.
- **`rg -rn` is a footgun** — `-r` is `--replace`, so `-rn "pat"` rewrites every
  match to "n". Use `rg -n` (recursive is the default). This trap has bitten
  repeatedly.
- Parallel sessions share `macos/.build` and the git index — `swift build` can
  queue behind another session's `.build/.lock`. For commits, use an isolated
  worktree branched off `origin/master`; stage only your own paths
  (`git add -A` sweeps other sessions' uncommitted files).
- SwiftLint pre-commit is **advisory** (warnings/errors don't block). Pre-existing
  length/cyclomatic violations on large files are a standing "don't chase" set.
- **Keep docs fresh in the SAME commit as the code.** When you add/remove a
  `Package.swift` `.library` product, add a new app surface (an `M1K3iOSApp/`-style
  shell), or move a type between the app target and `Sources/`, update the matching
  doc — the Module map (this file), the surface tables (`../README.md`,
  `../CONTRIBUTING.md`), and `docs/IOS_VISIONOS_PORT.md` — and keep relative doc
  pointers resolving on disk. The `doc-drift` CI job
  (`tools/ci/check_doc_drift.py`) enforces the Module-map ↔ Package.swift half
  automatically (red→green like the scheme-drift guard); the prose half is on you.
