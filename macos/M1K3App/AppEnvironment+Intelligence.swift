//
//  AppEnvironment+Intelligence.swift
//  M1K3App
//
//  The shared intelligence surface — ask / speak / remember — used by BOTH the
//  in-process MCP server (MCPHostController) AND the macOS App Intents
//  (Ask · Speak · Remember). One implementation, N adapters: the single-flight
//  guard, the runaway ask backstop, the shared canary tripwire, the memory-graph
//  dual-write all live here once, so a Siri/Shortcuts ask gets the exact same
//  protections a visiting agent's `ask_m1k3` does.
//
//  App-glue (verify-by-launch): the tested core is HeadlessAsk (M1K3Chat) +
//  IntentInput (M1K3Chat) + the package seams this assembles. The registry below
//  also gives an App Intent's perform() — which runs outside SwiftUI's
//  @Environment — a way to reach the live, warm environment.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-17, Confidence 0.8, Prior: Unknown
//

import Foundation
import M1K3Avatar // AvatarEmotion
import M1K3Chat // HeadlessAsk, RAGResponding, CanaryGuard, MemoryDistillationCoordinator
import M1K3MCPKit // MCPVoiceError, withTimeout, TimeoutError
import M1K3Memory // Memory — the temporal memory graph the dual-write seeds
import os

extension AppEnvironment {
    // MARK: - Shared instance registry (for App Intents)

    /// The live environment, registered once at launch so an App Intent's
    /// perform() can reach the warm model. MainActor-isolated → no data race.
    private static var sharedInstance: AppEnvironment?

    /// Register the live environment. Called from the app launch path; the menu-bar
    /// + launch-at-login design means M1K3 is normally already resident when an
    /// intent fires, so this is set well before perform() runs. Explicitly
    /// @MainActor so the isolation contract is visible at the call site, not just
    /// implied by the enclosing @MainActor class.
    @MainActor
    static func registerShared(_ environment: AppEnvironment) {
        sharedInstance = environment
    }

    /// The live environment, waiting up to `seconds` for it to appear (a
    /// background-serviced intent can race app launch). Returns nil if it never
    /// comes up in time. Poll-based on purpose: the state is MainActor-isolated, so
    /// there's no continuation to leak across the timeout. Bails immediately if the
    /// intent (and thus this task) is cancelled, rather than spinning to the deadline.
    @MainActor
    static func current(waitingUpTo seconds: Double) async -> AppEnvironment? {
        if let sharedInstance { return sharedInstance }
        let deadline = Date().addingTimeInterval(max(0, seconds))
        while Date() < deadline {
            guard !Task.isCancelled else { return nil }
            try? await Task.sleep(for: .milliseconds(100))
            if let sharedInstance { return sharedInstance }
        }
        return sharedInstance
    }

    // MARK: - Shared logger

    /// Loud, PERSISTED alert channel for a canary trip (debug/info aren't kept by
    /// the log store). Logs the match COUNT only — never the value, which re-leaks it.
    private nonisolated static let securityLog = Logger(subsystem: "app.m1k3", category: "security")

    /// Ask-path lifecycle (the MCP `ask_m1k3` / Ask App Intent core). Logs question
    /// LENGTH + brain, never the text — these lines are harvested by IssueReporter.
    private nonisolated static let askLog = Logger(subsystem: "app.m1k3", category: "responder")

    /// Memory-graph writes from the ask path — a storage failure is NOT a security
    /// event, so it must not surface under the [security] canary channel.
    private nonisolated static let memoryLog = Logger(subsystem: "app.m1k3", category: "memory-graph")

    // MARK: - Ask

    /// One grounded, cited answer with no transcript — the core behind the MCP
    /// `ask_m1k3` tool and the Ask App Intent. Single-flight (shared lock) + the
    /// runaway backstop + the shared canary tripwire. Throws `MCPVoiceError` on
    /// the blocked / busy / timeout paths; callers surface its message.
    ///
    /// `deadline` defaults to the MCP job path's 600s runaway backstop (no
    /// client waits on it — answers redeem via `get_answer`). A DIRECT-await
    /// caller (the Siri/Shortcuts intent) passes its own shorter deadline, so
    /// a hung generation can't hold the single-flight lock for 10 minutes
    /// against every other surface (PR #136 review fold).
    func intelligenceAsk(
        _ question: String,
        deadline: TimeInterval = MCPHostController.askDeadlineSeconds
    ) async throws -> String {
        // The same gate the chat surface uses (not a bare isReady): while the
        // selected MLX brain downloads, the interim bridge fronts turns on Mini
        // — the responder below rides the runtime façade, so `.interim` serves
        // a real (Mini) answer instead of refusing visiting agents for the
        // whole cold start (~6 min on a torn-cache Big heal). Only `.blocked`
        // (nothing can serve) refuses.
        let gate = chatGate
        guard gate.canTakeTurn else {
            throw MCPVoiceError("M1K3 is still getting its brain ready — try again in a moment")
        }
        guard voiceLoop == nil, !chat.isResponding else {
            throw MCPVoiceError("M1K3 is in a conversation right now — try again shortly")
        }
        guard !intelligenceAskInFlight else {
            Self.askLog.notice("ask rejected: already answering")
            throw MCPVoiceError("M1K3 is already answering a question")
        }
        intelligenceAskInFlight = true
        defer { intelligenceAskInFlight = false }
        // Hoist members into locals before the Logger interpolation: the message is
        // an autoclosure, so a `self.` member there requires explicit self, which
        // swiftformat then strips → a build break (the documented logging landmine).
        let askChars = question.count
        let askBrain = selectedBrain.rawValue
        Self.askLog.notice("ask: \(askChars) chars, brain=\(askBrain, privacy: .public)")
        avatar.setActivity(.thinking)
        defer { avatar.resetToIdle() }

        // Capture Sendable values so the @Sendable timeout closure needn't touch self.
        let responder = intelligenceResponder
        let tripwire = CanaryGuard.fromLocalConfig()
        do {
            let answer = try await withTimeout(seconds: deadline) {
                try await HeadlessAsk.answer(
                    question, using: responder, canary: tripwire,
                    onCanaryTrip: { count in
                        Self.securityLog.fault(
                            "canary tripwire fired in ask output: \(count, privacy: .public) honeypot(s) redacted"
                        )
                    }
                )
            }
            // Honest provenance on an interim (Mini-fronted) answer, pinned at
            // send time: the caller asked the selected brain and got Mini.
            guard gate == .interim else { return answer }
            return answer
                + "\n\n(Mini answered this while \(selectedBrain.displayName) finishes loading.)"
        } catch is TimeoutError {
            // Backstop hit — a genuinely hung generation, not a slow answer
            // (those ride the job path): cancel, release the lock (defer),
            // tell the caller honestly rather than hang.
            let deadlineSeconds = Int(deadline)
            Self.askLog.error("ask hit the runaway backstop after \(deadlineSeconds)s")
            throw MCPVoiceError(
                "M1K3's answer ran past the \(deadlineSeconds)s backstop and was "
                    + "stopped — that usually means something hung. Try a more specific question, or ask again."
            )
        }
    }

    // MARK: - Speak

    /// Speak text aloud — the core behind the MCP `speak` tool and the Speak App
    /// Intent. `wait: false` fires and returns immediately; `wait: true` awaits
    /// FULL playback (the MCP tool layer bounds that wait — the server handles
    /// requests concurrently, so a blocking speak no longer starves status
    /// polls; the stale "serial server" rationale was corrected 2026-08-19).
    /// Deliberately no readiness guard (unlike `intelligenceAsk`): TTS is
    /// model-independent — it needs only the speech pipeline, which is always
    /// available.
    func intelligenceSpeak(text: String, emotion: String?, wait: Bool) async throws {
        guard voiceLoop == nil, !chat.isResponding else {
            throw MCPVoiceError("M1K3 is in a conversation right now — try again shortly")
        }
        if let emotion {
            avatar.setEmotion(AvatarEmotion.from(emotion))
        }
        if wait {
            await speak(text)
        } else {
            Task { @MainActor in await self.speak(text) }
        }
    }

    // MARK: - Remember

    /// Persist a fact to memory — the core behind the MCP `remember` tool and the
    /// Remember App Intent: KnowledgeStore (`.memory`) ingest + best-effort
    /// dual-write into the temporal memory graph. `provenance` tags the graph
    /// fact's source (`mcp:remember` / `intent:remember`); `kind` is the caller's
    /// classification for the graph node (defaults `.note` — the App Intent
    /// doesn't classify yet). Returns a human confirmation. Dedup-safe:
    /// remembering identical text collapses to one row.
    func intelligenceRemember(
        title: String, text: String, provenance: String, kind: MemoryKind = .note
    ) async throws -> String {
        let result = try await ingester.ingest(
            title: title,
            text: text,
            sourceRef: MemoryDistillationCoordinator.factSourceRef(text),
            kind: .memory,
            source: .user
        )
        refreshCounts()
        // A genuinely-new memory earns the save earcon + a graph entry; a dedup
        // retry stays silent and skips the (additive, best-effort) dual-write.
        if !result.wasDeduped {
            soundEffects.play(.save)
            await dualWriteRememberedFact(title: title, text: text, provenance: provenance, kind: kind)
        }
        let dedup = result.wasDeduped ? " (already remembered)" : ""
        return "Remembered “\(title)”\(dedup)."
    }

    /// Best-effort write of a remembered fact into the temporal memory graph.
    /// Embeds via the SAME embedder the recall tools query with (shared space).
    /// Swallows every error — never a gate on the proven KnowledgeStore remember.
    /// The graph node keeps the caller's TITLE (B5 layer 3, graph lane): the
    /// vector embeds `embeddingText` (title-composed), so keyword queries can
    /// find long facts the way the corpus twin already allows.
    private func dualWriteRememberedFact(title: String, text: String, provenance: String, kind: MemoryKind) async {
        guard let memoryStore else { return }
        do {
            let fact = Memory(kind: kind, text: text, title: title, source: provenance)
            let vector = try await embedder.embed(fact.embeddingText)
            try memoryStore.rememberConnected(fact, embedding: vector)
        } catch {
            // "error", not "skipped" — a MemoryGraphPartialWriteError means the
            // node WAS written and only edges were lost; the error text says so.
            Self.memoryLog.error(
                "memory-graph dual-write error (corpus write stands): \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

// DistilledFactGraphAdapter moved to the M1K3MemoryChatBridge package target
// (2026-07-07) so the iOS/visionOS shell reuses the same Chat→graph dual-write.
