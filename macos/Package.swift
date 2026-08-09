// swift-tools-version: 6.2
//
// M1K3 — Mac-native MVP.
// Multi-module Swift package consumed by the SwiftUI app shell (added at the UI
// phase). Business logic lives here so `swift test` drives the TDD loop without
// the Xcode/simulator storm — same split as the prior internal server package.
//
// Target platform is macOS 26 (Tahoe): SwiftUI Liquid Glass + on-device
// Foundation Models. Heavy deps (MLX, GRDB, WhisperKit, swift-sdk) are added
// per-phase as the modules that need them land, to keep early builds quick.
//
// Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.8, Prior: Unknown
// Context: First Mac-native surface for M1K3. Scaffold begins with the pure,
// dependency-free knowledge primitives (VectorMath, RRFFusion) ported from
// the prior knowledge-server project so the foundation builds in seconds before MLX/GRDB enter the graph.

import Foundation
import PackageDescription

// M1K3_FM27 — compile the REAL FoundationModels conformance (ADR 0001 dual-path;
// M1K3Agent/M1K3FoundationModel.swift). Env-gated because the conformance needs
// the macOS 27 SDK, which only the Xcode 27 beta carries:
//
//   M1K3_FM27=1 DEVELOPER_DIR=/Applications/Xcode-beta.app \
//     swift build --target M1K3Agent --scratch-path .build-fm27
//
// Default OFF: stable 26.x builds (CI, releases, plain `swift build`) never set
// the env var, so they are byte-identical to before this gate existed. The
// separate scratch path keeps beta-toolchain artifacts out of the shared .build.
let fm27 = ProcessInfo.processInfo.environment["M1K3_FM27"] == "1"
let fm27Settings: [SwiftSetting] = fm27 ? [.define("M1K3_FM27")] : []

let package = Package(
    name: "M1K3",
    // iOS/visionOS added for the multiplatform derisk spike (2026-07-06): the app
    // shell (M1K3App/) is still macOS-only, but the library graph is protocol-seam
    // first, so the products build for iOS 26 / visionOS 26 to prove portability
    // ahead of the shared adaptive shell. macOS stays the shipping surface.
    platforms: [.macOS(.v26), .iOS(.v26), .visionOS(.v26)],
    products: [
        .library(name: "M1K3LogCore", targets: ["M1K3LogCore"]),
        .library(name: "M1K3Knowledge", targets: ["M1K3Knowledge"]),
        .library(name: "M1K3Memory", targets: ["M1K3Memory"]),
        .library(name: "M1K3MemoryViz", targets: ["M1K3MemoryViz"]),
        .library(name: "M1K3Inference", targets: ["M1K3Inference"]),
        .library(name: "M1K3Agent", targets: ["M1K3Agent"]),
        .library(name: "M1K3LanguageModel", targets: ["M1K3LanguageModel"]),
        .library(name: "M1K3Eval", targets: ["M1K3Eval"]),
        .library(name: "M1K3KnowledgeTools", targets: ["M1K3KnowledgeTools"]),
        .library(name: "M1K3AgentTools", targets: ["M1K3AgentTools"]),
        .library(name: "M1K3Chat", targets: ["M1K3Chat"]),
        // Leaf bridge: adapts M1K3Memory's graph to M1K3Chat's
        // DistilledFactGraphWriting seam so chat memory auto-capture reaches the
        // temporal graph WITHOUT Chat↔Memory depending on each other. Shared by
        // both the macOS app and the iOS/visionOS shell.
        .library(name: "M1K3MemoryChatBridge", targets: ["M1K3MemoryChatBridge"]),
        .library(name: "M1K3Voice", targets: ["M1K3Voice"]),
        .library(name: "M1K3MLX", targets: ["M1K3MLX"]),
        .library(name: "M1K3WhisperKit", targets: ["M1K3WhisperKit"]),
        .library(name: "M1K3Calls", targets: ["M1K3Calls"]),
        .library(name: "M1K3Avatar", targets: ["M1K3Avatar"]),
        .library(name: "M1K3Kokoro", targets: ["M1K3Kokoro"]),
        // Exported for the app's in-process MCP host (the stdio executable
        // reaches the target directly; the app needs the product).
        .library(name: "M1K3MCPKit", targets: ["M1K3MCPKit"]),
        // The opt-in Agent Interaction Log store — conforms to M1K3MCPKit's
        // MCPCallLogSink, capturing full request+response text ONLY when the
        // app's Settings toggle is on. Separate target (not folded into
        // M1K3MCPKit) so the PII-bearing capture/persistence logic — and its
        // own GRDB store file — stays out of the tool-dispatch core.
        .library(name: "M1K3MCPLog", targets: ["M1K3MCPLog"]),
        // Launch-at-login policy (SMAppService seam) for the always-resident
        // menu-bar companion. Pure controller + thin ServiceManagement adapter.
        .library(name: "M1K3Launch", targets: ["M1K3Launch"]),
        // The review-panel router: turns a pasted link / dropped file into a
        // routed ReviewTarget. Pure + dependency-free; the QuickLook/WKWebView
        // renderers live in the app target (verify-by-run).
        .library(name: "M1K3Preview", targets: ["M1K3Preview"]),
        // Diagnostics: privacy scrub + issue-report formatting for the secret-free
        // "Report an issue" flow. Pure + dependency-free so the redaction rules
        // are unit-pinned (a miss leaks PII).
        .library(name: "M1K3Diagnostics", targets: ["M1K3Diagnostics"]),
        // The heartbeat: the 2-hourly narrative pulse. Pure schedule/compose/
        // guard policies + its own GRDB store (separate file, capped, one-tap
        // Clear, excluded from diagnostics AND from memory distillation — a
        // pulse history must never become permanent memory-graph facts).
        .library(name: "M1K3Heartbeat", targets: ["M1K3Heartbeat"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        // On-device embeddings + Gemma generation on Apple Silicon (Metal).
        // Same package family the prior knowledge-server ships MLXEmbedders from; isolated to the
        // M1K3MLX target so the heavy Metal build never touches the core tests.
        // upToNextMinor deliberately when on a tag: 3.x majors AND minors have
        // carried API + mlx-swift kernel changes (kernel change = embedder
        // re-index); bumps are probe-first, on purpose (see HuggingFaceBridge.swift).
        //
        // Back on a tag (3.31.4, cut 2026-06-30) after the 06-24 → 06-30 spell
        // pinned to main HEAD (40c2ff06, = PR #330's merge): tag 3.31.3 had no
        // Gemma 4 tool-call parser, so M1K3's big brain (gemma-4-e4b) was stuck
        // on the ReAct floor and reasoned into silence. 3.31.4 contains
        // everything the revision pin existed for — #183 (GemmaFunctionParser →
        // .gemma4), #330 (Gemma 4 E-series load fix), #225 (asyncEval prefill),
        // #327 (gemma4_unified) — 40c2ff06 is an ancestor, 11 commits behind
        // the tag. Verify-owed on any bump here: a gemma-4 NATIVE TOOL-CALL
        // smoke (not just load-and-generate) — tool-calling is the reason this
        // dependency moves.
        // Pinned to a main revision (2026-08-06, "Olmo3: fix newCache signature",
        // c97539da) for Gemma-4 MTP speculative decoding: #415 (the
        // Gemma4Unified MTP entry points + drafter registration — the #61
        // unlock) and #506 (stand down before the sliding cache wraps) are
        // both post-3.31.4 and unreleased as tags. Revision-pin + release-watch
        // (the 2026-06 pattern): move back to a tag when one ships carrying
        // both. This revision also carries the #502 ChatConventionsProviding
        // migration — our .gemma4 dialect integration was re-verified against
        // it in the same commit that changed this line.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", revision: "c97539da0e8554d2fad90cc79692381eab1c7906"),
        // mlx-swift itself (MLX/MLXNN/MLXFFT/MLXFast) — mlx-swift-lm depends on
        // this but doesn't re-export its products, so M1K3Kokoro (which needs
        // the raw neural-net/FFT primitives for the vendored Kokoro port, not
        // mlx-swift-lm's LLM-loading machinery) declares it directly. SAME URL
        // mlx-swift-lm itself pins (`https://github.com/ml-explore/mlx-swift`,
        // no `.git` suffix) so SwiftPM resolves one copy, not two.
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.31.4")),
        // Downloader/Tokenizer for the MLX stack. 3.x removed the built-in HF
        // client; the official adapter packages (swift-tokenizers-mlx) clash
        // with WhisperKit's swift-transformers (duplicate `Tokenizers` target),
        // so M1K3 bridges the small Downloader/TokenizerLoader protocols to
        // swift-transformers directly — the SAME library WhisperKit already
        // pins, and the same HubApi the 2.x line used (cache layout preserved).
        .package(url: "https://github.com/huggingface/swift-transformers", .upToNextMinor(from: "1.1.6")),
        // Official MCP Swift SDK — the M1K3MCP stdio server exposes M1K3's
        // knowledge to Claude Desktop/Code as MCP tools.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.7.0"),
        // WhisperKit — high-accuracy on-device transcription (the P6 primary
        // engine). Heavy (CoreML + model download), so it's isolated to the
        // M1K3WhisperKit target; Apple Speech (system framework) is the
        // always-available fallback behind the same TranscriptionProvider seam.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.15.0"),
    ],
    targets: [
        // The single source of truth for unified logging: the `app.m1k3`
        // subsystem + the category catalogue + LogPreview. DEPENDENCY-FREE on
        // purpose so every target (including the heavy MLX/Kokoro/WhisperKit
        // seams) can reference the constants without dragging in the agent
        // stack. The SubsystemGuard test scans the tree to enforce uniformity.
        .target(
            name: "M1K3LogCore",
            path: "Sources/M1K3LogCore"
        ),
        .testTarget(
            name: "M1K3LogCoreTests",
            dependencies: ["M1K3LogCore"],
            path: "Tests/M1K3LogCoreTests"
        ),
        .target(
            name: "M1K3Knowledge",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/M1K3Knowledge"
        ),
        .testTarget(
            name: "M1K3KnowledgeTests",
            dependencies: ["M1K3Knowledge"],
            path: "Tests/M1K3KnowledgeTests"
        ),
        // The temporal memory graph: atomic facts + typed edges + recursive-CTE
        // traversal + supersession-over-time. SEPARATE store (own DB file,
        // consent lifecycle) from the RAG corpus; reuses M1K3Knowledge's proven
        // VectorMath/RRF/GroundingGate/EmbeddingService primitives. GRDB only —
        // no graph engine. This is the artifact a later "knows-me" LoRA distils.
        .target(
            name: "M1K3Memory",
            dependencies: [
                "M1K3Knowledge",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/M1K3Memory"
        ),
        .testTarget(
            name: "M1K3MemoryTests",
            dependencies: ["M1K3Memory", "M1K3Knowledge"],
            path: "Tests/M1K3MemoryTests"
        ),
        // The 3D memory constellation — RealityKit view over the pure
        // ConstellationModel (layout lives in M1K3Memory). RealityKit/SwiftUI are
        // system frameworks (no third-party dep), same as M1K3Avatar. The pure
        // geometry/palette helpers are unit-tested; the RealityView is verify-by-run.
        .target(
            name: "M1K3MemoryViz",
            dependencies: ["M1K3Memory"],
            path: "Sources/M1K3MemoryViz"
        ),
        .testTarget(
            name: "M1K3MemoryVizTests",
            dependencies: ["M1K3MemoryViz"],
            path: "Tests/M1K3MemoryVizTests"
        ),
        // Pluggable LLM runtime. The InferenceProvider protocol + router are
        // pure/testable; backends (Apple Foundation Models now, MLX/LiteRT
        // Gemma later) are thin adapters behind it. No external deps —
        // FoundationModels is a system framework on macOS 26.
        .target(
            name: "M1K3Inference",
            // M1K3LogCore only — the dependency-free logging catalogue. Added
            // 2026-08-09 because AppleFoundationModelsProvider (the Mini tier,
            // and the first-run default) had NO logger at all, so overflows,
            // guardrail refusals and daemon collapses were one silent empty
            // stream. This target stays otherwise dependency-free by design.
            dependencies: ["M1K3LogCore"],
            path: "Sources/M1K3Inference"
        ),
        .testTarget(
            name: "M1K3InferenceTests",
            dependencies: ["M1K3Inference"],
            path: "Tests/M1K3InferenceTests"
        ),
        // Privacy scrub + issue-report formatting (no deps; the redaction rules
        // are the most test-worthy code in the report-an-issue feature).
        .target(
            name: "M1K3Diagnostics",
            path: "Sources/M1K3Diagnostics"
        ),
        .testTarget(
            name: "M1K3DiagnosticsTests",
            dependencies: ["M1K3Diagnostics"],
            path: "Tests/M1K3DiagnosticsTests"
        ),
        // Local agent: ReAct loop + tool protocol. Pure logic over the
        // InferenceProvider seam — tools are injected, so it tests against
        // fakes with no model. Knowledge-backed tools wire in at the app layer.
        .target(
            name: "M1K3Agent",
            dependencies: ["M1K3LogCore", "M1K3Inference", "M1K3LanguageModel"],
            path: "Sources/M1K3Agent",
            swiftSettings: fm27Settings
        ),
        .testTarget(
            name: "M1K3AgentTests",
            dependencies: ["M1K3Agent"],
            path: "Tests/M1K3AgentTests"
        ),
        // The WWDC26 LanguageModel bridge (ADR 0001). Pure, dependency-free:
        // a local MIRROR of Apple's FoundationModels surface (retargets to the
        // real types on macOS 27) + the consent-gated escalation-ladder policy.
        // Buildable/runnable on Tahoe today; the real-provider executor lands
        // separately on M1K3Agent.
        .target(
            name: "M1K3LanguageModel",
            dependencies: [],
            path: "Sources/M1K3LanguageModel"
        ),
        .testTarget(
            name: "M1K3LanguageModelTests",
            dependencies: ["M1K3LanguageModel"],
            path: "Tests/M1K3LanguageModelTests"
        ),
        // The model-evals enclave (Phase 14). PURE, dependency-free: task-kind
        // fixtures + a deterministic heuristic scorer + the cross-brain report
        // matrix. Mirrors MemoryEvalFixtures/ModelEval — the scoring is unit-
        // tested off-device here; the model-running half rides the headless
        // self-test (M1K3_SELFTEST_CHATEVAL) because MLX needs the .app bundle.
        .target(
            name: "M1K3Eval",
            // ChatEvalScorer uses M1K3Inference.ThinkStripper (added #87). The
            // SwiftPM CLI build resolved this implicitly via the shared module
            // dir, but the strict Xcode/xcodegen graph needs it declared.
            dependencies: ["M1K3Inference"],
            path: "Sources/M1K3Eval"
        ),
        .testTarget(
            name: "M1K3EvalTests",
            dependencies: ["M1K3Eval"],
            path: "Tests/M1K3EvalTests"
        ),
        // Agent tools backed by the knowledge layer — the bridge that makes the
        // LocalAgent able to actually search M1K3's memory. Depends on both the
        // agent (AgentTool) and knowledge (KnowledgeStore) modules.
        .target(
            name: "M1K3KnowledgeTools",
            dependencies: ["M1K3Agent", "M1K3Knowledge"],
            path: "Sources/M1K3KnowledgeTools"
        ),
        .testTarget(
            name: "M1K3KnowledgeToolsTests",
            dependencies: ["M1K3KnowledgeTools", "M1K3Inference"],
            path: "Tests/M1K3KnowledgeToolsTests"
        ),
        // Self-contained agent tools: web search (DuckDuckGo), date/time, system
        // status. Depends on M1K3Agent (the AgentTool seam), M1K3Inference (the
        // HostPlatform device noun in tool descriptions), and M1K3Preview —
        // pure parsers/formatters tested against fixtures; network/IOKit
        // adapters stay thin. The app injects these into the chat agent;
        // M1K3Chat never links this.
        .target(
            name: "M1K3AgentTools",
            // M1K3LogCore declared explicitly (2026-08-09). Several files here
            // already imported it and compiled on the transitive path through
            // M1K3Agent — pre-existing, not introduced by this change, but it
            // works by accident and would break if M1K3Agent's own deps moved.
            dependencies: ["M1K3Agent", "M1K3Inference", "M1K3LogCore", "M1K3Preview"],
            path: "Sources/M1K3AgentTools"
        ),
        .testTarget(
            name: "M1K3AgentToolsTests",
            dependencies: ["M1K3AgentTools", "M1K3Agent"],
            path: "Tests/M1K3AgentToolsTests",
            resources: [.copy("Fixtures")]
        ),
        // RAG chat: embed → hybrid search → documents-first prompt → generate.
        // The grounded-answer brain. Depends on knowledge + inference, and on
        // M1K3Agent for the always-on tool-calling responder (AgentRAGResponder).
        .target(
            name: "M1K3Chat",
            dependencies: [
                "M1K3Knowledge", "M1K3Inference", "M1K3Agent",
                // Multi-conversation chat history (GRDBChatHistoryStore) —
                // M1K3Knowledge already links GRDB, so zero new build weight.
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/M1K3Chat"
        ),
        .testTarget(
            name: "M1K3ChatTests",
            // M1K3KnowledgeTools/M1K3AgentTools are TEST-ONLY deps: the
            // self-query gate names those tools as strings (M1K3Chat cannot
            // link them — tools are injected by the app layer), so a pin test
            // guards the names against drift. Same pattern as M1K3MLXTests →
            // M1K3Chat (the 116-F1 cross-module equality pin).
            // M1K3Eval is TEST-ONLY for the same reason: the prompt-size
            // instrument's section markers (PromptMarker.live) are strings
            // duplicated out of M1K3Chat's rendered prompt, and M1K3Eval must
            // not depend on M1K3Chat. A pin test here renders the REAL prompt
            // and asserts every marker still matches, so a wording pass fails
            // loudly instead of silently zeroing a section in the report.
            dependencies: ["M1K3Chat", "M1K3KnowledgeTools", "M1K3AgentTools", "M1K3Eval"],
            path: "Tests/M1K3ChatTests"
        ),
        // Leaf bridge (Chat + Memory only): DistilledFactGraphAdapter, the
        // Chat→graph dual-write. Nothing depends back on it but the two app
        // shells, so it adds no cycle and leaks no heavy deps (both closures are
        // Foundation + GRDB). Relocated out of M1K3App so iOS/visionOS reuse it.
        .target(
            name: "M1K3MemoryChatBridge",
            dependencies: ["M1K3Chat", "M1K3Memory"],
            path: "Sources/M1K3MemoryChatBridge"
        ),
        .testTarget(
            name: "M1K3MemoryChatBridgeTests",
            dependencies: ["M1K3MemoryChatBridge"],
            path: "Tests/M1K3MemoryChatBridgeTests"
        ),
        // Voice. TTS now (AVSpeech behind SpeechProvider; Kokoro later);
        // transcription (WhisperKit) joins this module in the heavy-dep session.
        // AVFoundation is a system framework — no third-party dep.
        .target(
            name: "M1K3Voice",
            path: "Sources/M1K3Voice"
        ),
        .testTarget(
            name: "M1K3VoiceTests",
            dependencies: ["M1K3Voice"],
            path: "Tests/M1K3VoiceTests"
        ),
        // The heavy on-device backends, isolated here so nothing else links
        // MLX/Metal. MLXEmbeddingService conforms to EmbeddingService; the
        // MLXGemmaProvider conforms to InferenceProvider — both swap in behind
        // the same seams the core already tests against fakes.
        .target(
            name: "M1K3MLX",
            dependencies: [
                "M1K3Knowledge",
                "M1K3Inference",
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                // Vision spike (2026-07-14): MLXLLM's Gemma4Model strips vision
                // weights at load (`vision_tower`/`vision_embedder` sanitize) —
                // only MLXVLM's separate Gemma4 implementation actually consumes
                // UserInput.images. Both factories load the SAME HF checkpoint
                // (mlx-community/gemma-4-e4b-it-4bit) into a common ModelContainer
                // ChatSession is agnostic to; probe-first before touching the
                // production MLXGemmaProvider load path.
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "Transformers", package: "swift-transformers"),
            ],
            path: "Sources/M1K3MLX",
            // The vendored canonical gemma-4 chat template (Google's 2026-07-09
            // fix) — installed over stale mlx-community snapshots by
            // Gemma4TemplateFix before the integrity scan runs.
            resources: [.copy("Resources/gemma4-chat-template-canonical.jinja")]
        ),
        .testTarget(
            name: "M1K3MLXTests",
            dependencies: [
                "M1K3MLX",
                "M1K3Knowledge",
                "M1K3Inference",
                "M1K3Chat", // HistoryBudgetPolicy ↔ MLXGemmaProvider default-cap equality pin (116-F1)
                .product(name: "Transformers", package: "swift-transformers"),
            ],
            path: "Tests/M1K3MLXTests"
        ),
        // MCP server library: knowledge-tool handlers (pure, testable) + the
        // stdio server wiring. Split from the executable so the tools can be
        // unit-tested (executable targets are awkward to @testable import).
        .target(
            name: "M1K3MCPKit",
            dependencies: [
                "M1K3Knowledge",
                "M1K3Memory",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "Sources/M1K3MCPKit"
        ),
        .testTarget(
            name: "M1K3MCPKitTests",
            dependencies: ["M1K3MCPKit", "M1K3Knowledge", "M1K3Memory"],
            path: "Tests/M1K3MCPKitTests"
        ),
        // The thin executable Claude Desktop/Code spawns — just runs the server.
        .executableTarget(
            name: "M1K3MCP",
            dependencies: ["M1K3MCPKit"],
            path: "Sources/M1K3MCP"
        ),
        // The Agent Interaction Log: an MCPCallLogSink that persists every MCP
        // tool call (request + response) to its own GRDB store, opt-in and
        // capped at the newest 500 rows. See ConversationLogStore.swift for the
        // full design rationale.
        .target(
            name: "M1K3MCPLog",
            dependencies: [
                "M1K3MCPKit",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/M1K3MCPLog"
        ),
        .testTarget(
            name: "M1K3MCPLogTests",
            dependencies: ["M1K3MCPLog", "M1K3MCPKit"],
            path: "Tests/M1K3MCPLogTests"
        ),
        // The heartbeat: pure pulse policies (schedule/quiet-hours/skip,
        // deterministic digest composer, narrative validator) + a capped GRDB
        // store mirroring ConversationLogStore's idioms. The model render and
        // the scheduler EFFECT live in the app target; this target stays
        // fast-testable.
        .target(
            name: "M1K3Heartbeat",
            dependencies: [
                "M1K3LogCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/M1K3Heartbeat"
        ),
        .testTarget(
            name: "M1K3HeartbeatTests",
            dependencies: ["M1K3Heartbeat"],
            path: "Tests/M1K3HeartbeatTests"
        ),
        // Launch-at-login. The LaunchAtLogin policy is pure (TDD against a fake);
        // SMAppServiceLoginItem wraps the system ServiceManagement framework
        // (no third-party dep) and is verify-by-launch (needs a registered bundle).
        .target(
            name: "M1K3Launch",
            path: "Sources/M1K3Launch"
        ),
        .testTarget(
            name: "M1K3LaunchTests",
            dependencies: ["M1K3Launch"],
            path: "Tests/M1K3LaunchTests"
        ),
        // The review-panel router (ReviewTarget + ReviewTargetResolver). PURE,
        // dependency-free: file existence + home dir are injected so it tests
        // off-device. The QuickLook/WKWebView views are app-target glue.
        .target(
            name: "M1K3Preview",
            path: "Sources/M1K3Preview"
        ),
        .testTarget(
            name: "M1K3PreviewTests",
            dependencies: ["M1K3Preview"],
            path: "Tests/M1K3PreviewTests"
        ),
        // Call intelligence — the model-AGNOSTIC seam (this is the reusable IP, per
        // the challenger pass): batch-transcription + diarization + summarization
        // protocols, the pure DiarizationAligner, and a two-stage summary pipeline.
        // Concrete engines (WhisperKit-batch, FluidAudio, Gemma-shadow) plug in
        // behind the protocols; none are linked here. Depends on M1K3Inference for
        // the summary tier and M1K3Knowledge so finished calls become graph nodes.
        .target(
            name: "M1K3Calls",
            dependencies: [
                "M1K3Inference",
                "M1K3Knowledge",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/M1K3Calls"
        ),
        .testTarget(
            name: "M1K3CallsTests",
            dependencies: [
                "M1K3Calls", "M1K3Knowledge", "M1K3Inference",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/M1K3CallsTests"
        ),
        // WhisperKit transcription, isolated like M1K3MLX so only this target
        // (and the app) link the heavy CoreML/model machinery. Conforms to
        // M1K3Voice's TranscriptionProvider.
        .target(
            name: "M1K3WhisperKit",
            dependencies: [
                "M1K3Voice",
                // M1K3Calls owns the BatchTranscriptionProvider seam + CallTranscriptSegment
                // that WhisperKitBatchTranscriber conforms to / produces (light deps only).
                "M1K3Calls",
                // M1K3Inference owns SingleFlightLoader — coalesces concurrent model
                // loads so a preload racing the first transcribe shares ONE download.
                "M1K3Inference",
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/M1K3WhisperKit"
        ),
        .testTarget(
            name: "M1K3WhisperKitTests",
            dependencies: ["M1K3WhisperKit", "M1K3Voice", "M1K3Calls"],
            path: "Tests/M1K3WhisperKitTests"
        ),
        // Avatar companion: pure types (emotion, activity, state, tool→emotion
        // mapping, animation resolver) + RealityKit view + Observable controller.
        // RealityKit/SwiftUI are system frameworks — no third-party dep.
        .target(
            name: "M1K3Avatar",
            path: "Sources/M1K3Avatar",
            // Per-clip companion USDZs (Fox v1; more are a folder + spec). Copied
            // verbatim — RealityKit loads them via Bundle.module at the app layer.
            // SoundEffects: short UI earcons (AVAudioPlayer via Bundle.module).
            resources: [.copy("Companions"), .copy("SoundEffects")]
        ),
        .testTarget(
            name: "M1K3AvatarTests",
            dependencies: ["M1K3Avatar"],
            path: "Tests/M1K3AvatarTests"
        ),
        // M1K3 Voice — the premium neural TTS tier (Kokoro). Isolated like
        // M1K3MLX/M1K3WhisperKit so only this target (and the app) links the
        // heavy backend + G2P phonemizer. Backend swapped 2026-07-18: ONNX
        // Runtime → pure MLX (a vendored StyleTTS2/Kokoro port under
        // Sources/M1K3Kokoro/MLX/Vendored/, MIT, Blaizzy/mlx-audio-swift) — the
        // visionOS unlock, since onnxruntime-swift-package-manager had no xrOS
        // slice. Conforms to M1K3Voice's SpeechProviderWithLifecycle and
        // M1K3Inference's ModelPreloading.
        .target(
            name: "M1K3Kokoro",
            dependencies: [
                "M1K3LogCore", "M1K3Voice", "M1K3Inference",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFFT", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ],
            path: "Sources/M1K3Kokoro",
            // The vendoring paper trail (MLX/Vendored/README.md + LICENSE) isn't
            // Swift source and isn't a runtime resource — exclude it explicitly so
            // SwiftPM doesn't warn about unhandled files on every build.
            exclude: ["MLX/Vendored/README.md", "MLX/Vendored/LICENSE"],
            resources: [.copy("Resources/g2p-en-gb.deflate")]
        ),
        .testTarget(
            name: "M1K3KokoroTests",
            dependencies: ["M1K3Kokoro"],
            path: "Tests/M1K3KokoroTests"
        ),
    ]
)
