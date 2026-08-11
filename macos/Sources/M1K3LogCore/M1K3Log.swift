//
//  M1K3Log.swift
//  M1K3LogCore
//
//  The single source of truth for unified logging across EVERY M1K3 module.
//
//  Watch a whole session live:
//
//      log stream --predicate 'subsystem == "app.m1k3"' --level debug
//
//  (or filter the subsystem in Console.app). Content is logged as bounded,
//  single-line PREVIEWS, deliberately `.public` so Kev can diagnose his own
//  machine — these logs never leave the device, same trust boundary as the
//  knowledge store itself. Drop to `.private` before any telemetry ever exists
//  (it shouldn't).
//
//  WHY ITS OWN TARGET: this used to live in `M1K3Agent`, which depends on
//  `M1K3Inference` + `M1K3LanguageModel`. The heavy seam targets (M1K3MLX,
//  M1K3Kokoro, M1K3WhisperKit, M1K3Voice, …) can't import M1K3Agent just for a
//  logging constant without dragging the agent stack into their build. So the
//  subsystem constant + the category CATALOG live here, dependency-free, and
//  every target can reference them. This is what makes the `SubsystemGuard`
//  test enforceable: one allowed subsystem, one catalogue of categories, no
//  scattered string literals to drift (a Kokoro logger on "dev.m1k3.kokoro"
//  was silently dropped from issue reports for weeks — never again).
//
//  Signed: Kev + claude-opus-4-8, 2026-06-30, Confidence 0.9 (pure + TDD-pinned;
//  the catalogue + guard are the durable drift-prevention layer). Prior: Kev +
//  claude-fable-5 (the original AgentLog M1K3Log/LogPreview, 2026-06-10).
//

import Foundation
import os

/// One subsystem for every M1K3 module, so a single predicate catches all, plus
/// the canonical category catalogue. Reference `M1K3Log.logger(_:)` instead of
/// constructing `Logger(subsystem:category:)` by hand — that keeps the subsystem
/// uniform and the category set discoverable + typo-proof.
public enum M1K3Log {
    /// The ONE subsystem. `IssueReporter` filters on this exact value and the
    /// documented `log stream` recipe predicates on it — anything else is invisible.
    public static let subsystem = "app.m1k3"

    /// The canonical category catalogue. Adding a category here (rather than
    /// inlining a string literal at the call site) keeps related log lines
    /// correlated and prevents the duplicate/typo drift the guard test forbids.
    public enum Category: String, CaseIterable, Sendable {
        /// The ReAct / native-tool agent loop: thoughts, actions, observations.
        case agentLoop = "agent-loop"
        /// RAG chat brain (embed → search → ground → generate).
        case responder
        /// Conversation persistence lifecycle (GRDB save, conversation identity,
        /// history revision) — kept separate from `responder` so retrieval/
        /// grounding events and persistence events are each isolable in a stream.
        case chatSession = "chat-session"
        /// Background memory distillation from conversations.
        case memoryDistill = "memory-distill"
        /// Chat route selection (which brain / path a turn takes).
        case route
        /// Call recording, transcription, and summarisation.
        case calls
        /// Security-sensitive surfaces (MCP auth, canary, intelligence gate).
        case security
        /// MLX model load / brain swap.
        case mlxLoad = "mlx-load"
        /// Time-to-first-token and decode throughput.
        case ttft
        /// Model weight download (HuggingFace bridge).
        case modelDownload = "model-download"
        /// Downloaded-weight verification against the pinned digest manifest.
        /// Its `.fault` lines are the supply-chain tripwire firing — a refused
        /// load, not a retryable failure.
        case weightIntegrity = "weight-integrity"
        /// User-initiated import of weights already on disk, verified against
        /// the same pinned manifest as a download (`WeightImport`).
        case weightImport = "weight-import"
        /// MLX Metal memory budget / ceiling.
        case mlxMemory = "mlx-memory"
        /// Embedding service load + reindex.
        case embeddings
        /// Text-to-speech (neural Kokoro + Apple fallback).
        case voice
        /// Speech-to-text (WhisperKit + Apple Speech).
        case stt
        /// Earcons / sound effects.
        case sfx
        /// Knowledge corpus retrieval primitives (FTS / vector / fusion).
        case knowledge
        /// Temporal memory graph reads/writes.
        case memoryGraph = "memory-graph"
        /// The web-search agent tool.
        case webSearch = "web-search"
        /// The fetch-page agent tool.
        case fetchPage = "fetch-page"
        /// The Wikipedia agent tool.
        case wikipedia
        /// UserNotifications (long-think / tool-turn completion).
        case notify
        /// Artifact / review-panel preview rendering.
        case artifactPreview = "artifact-preview"
        /// The CRT phosphor avatar material/shader.
        case phosphor
        /// The in-app MCP server (request lifecycle, tool errors).
        case mcp
        /// Launch-at-login (SMAppService).
        case launch
        /// OS (CoreSpotlight) index donation/reconcile.
        case spotlight
        /// The 3D companion creature surface (USDZ load/reload lifecycle).
        case companion
        /// MetricKit: on-device MXDiagnosticPayload/MXMetricPayload collection
        /// (crash/hang/cpu/disk-write diagnostics + daily metrics). Payload
        /// KIND + count only, never the payload's own content.
        case metricKit = "metric-kit"
        /// The heartbeat: the 2-hourly narrative pulse (schedule decisions,
        /// gather/render lifecycle, store writes). Skip reasons, tier picked,
        /// and entry COUNTS only — never digest or narrative content (the
        /// pulse text summarizes memories/chat and must not leak into logs).
        case heartbeat
        /// Apple Foundation Models (the Mini tier): session lifecycle, prompt
        /// SIZE, and the throws that were previously swallowed whole. Mini had
        /// no logger at all, so a context overflow, a guardrail refusal and a
        /// model that simply said nothing were indistinguishable — on the
        /// default brain. Sizes and error text only, never prompt content.
        case afm
        /// The headless CHATEVAL harness: fixture boundaries and phase marks.
        /// Exists because a 2026-08-10 run showed 177 SECONDS of total log
        /// silence between one fixture ending and the next producing its first
        /// line — the single largest latency contributor in the run, and
        /// completely unattributable. Fixture IDs and timings only, never
        /// prompt or answer text.
        case eval
    }

    /// Build a `Logger` on the M1K3 subsystem for a catalogued category.
    /// Prefer this over `Logger(subsystem:category:)` so the subsystem stays
    /// uniform and the `SubsystemGuard` test can prove it.
    public static func logger(_ category: Category) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }

    /// The ReAct loop logger — a named convenience for the highest-traffic site.
    public static let agentLoop = logger(.agentLoop)
}

/// Bounded, single-line content previews for log lines. Collapse whitespace runs
/// to single spaces and cap the length so a log line is one tidy row and large
/// model output never floods the store.
public enum LogPreview {
    /// Compiled once — this runs on every agent log line (thoughts, observations,
    /// conclusions); per-call `NSRegularExpression` compilation via the
    /// `.regularExpression` option would be pure overhead. `nonisolated(unsafe)`:
    /// this toolchain still treats `Regex<Substring>` as non-Sendable (verified:
    /// the bare `static let` is a compile error). A literal with no transform
    /// closures is immutable, so unsafe is sound.
    private nonisolated(unsafe) static let whitespaceRun = /\s+/

    /// Collapse all whitespace runs to single spaces and cap the length.
    public static func preview(_ text: String, max cap: Int = 120) -> String {
        let flattened = text
            .replacing(whitespaceRun, with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard flattened.count > cap else { return flattened }
        return flattened.prefix(cap).trimmingCharacters(in: .whitespaces) + "…"
    }
}
