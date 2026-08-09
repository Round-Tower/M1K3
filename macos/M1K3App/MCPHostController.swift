//
//  MCPHostController.swift
//  M1K3App
//
//  Hosts the M1K3 MCP server IN-PROCESS over loopback HTTP (default OFF —
//  privacy first), serving the live KnowledgeStore plus the voice tools.
//  All tool logic lives in tested packages (M1K3MCPKit); this controller is
//  the MainActor glue: handler closures over speech / avatar / transcription
//  and the Settings-facing lifecycle.
//
//  Client config (Settings shows this): one MCP client at a time (v1 —
//  stateless transport; a new client's initialize rebuilds the session).
//
//      claude mcp add --transport http m1k3 http://127.0.0.1:4242/mcp
//
//  Signed: Kev + claude-fable-5, 2026-06-11, Confidence 0.8 (registry/wire
//  layers test-pinned in M1K3MCPKit; this glue is verify-at-⌘R against a real
//  claude session). Prior: Unknown.
//
//  Review: Kev + claude-opus-4-8, 2026-06-17, Confidence 0.85 — extracted the
//  ask/speak/remember logic (askBrain, beginSpeak, rememberText,
//  dualWriteToMemoryGraph + the single-flight lock + canary wiring) into the shared
//  AppEnvironment+Intelligence surface so the App Intents reuse the exact same
//  core; this controller is now the MCP adapter that delegates to it. Behaviour
//  preserved (provenance parameterised to "mcp:remember"); dropped the now-unused
//  `os` + `M1K3Chat` imports.
//

import Foundation
import M1K3Avatar
import M1K3Chat // HeadlessAsk + RAGResponding (the ask_m1k3 core)
import M1K3Knowledge // KnowledgeStore — forget_memory deletes the dual-written corpus twin too
import M1K3MCPKit
import M1K3Memory // MemoryStore, Memory — the temporal memory graph the new tools expose
import M1K3Preview // ReviewTargetResolver — validate the open_link URL (web-only)
import M1K3Voice
import MCP // StatelessHTTPServerTransport (the SDK type the session factory builds)
import Observation
import os // Logger — forget_memory's corpus-twin audit channel

@MainActor
@Observable
final class MCPHostController {
    nonisolated static let enabledKey = "mcpServer.enabled"
    nonisolated static let portKey = "mcpServer.port"
    nonisolated static let defaultPort: UInt16 = 4242
    // Leak-tripwire honeypots. Stored in local config only — never in source —
    // so the repo never carries the bait:
    //   `defaults write app.m1k3 canaryTripwire "the passphrase"`
    // Pipe-separate for several (so a honeypot value must not itself contain
    // `|`). Unset → an inert guard. Plaintext in the sandboxed container is an
    // accepted v1 trade-off — the boundary guarded is the MCP OUTPUT surface,
    // not canary storage; migrate to the Keychain if the threat model widens to
    // a compromised container read. The key string lives once, in
    // `CanaryGuard.localConfigKey` — shared with the menu-bar Ask + App Intent
    // surfaces. The ask/speak/remember logic (single-flight, deadline, the canary
    // wiring, the memory-graph dual-write) lives once in AppEnvironment+Intelligence;
    // this controller is now just the MCP adapter over it.

    /// Audit channel for forget_memory's corpus-twin delete (the ask/speak/remember
    /// canary logging now lives in AppEnvironment+Intelligence; this stays for the
    /// MCP-only forget path). Persisted; logs outcomes, never canary values.
    private nonisolated static let securityLog = Logger(
        subsystem: "app.m1k3", category: "security"
    )

    private unowned let env: AppEnvironment
    private var server: LocalMCPHTTPServer?
    /// Ceiling on a single ask_m1k3 generation. Legit answers run tens of
    /// seconds even on the big brains; past this the generation is cancelled
    /// and the single-flight lock released, so one runaway question can't wedge
    /// the tool for the whole session (test-report F1 — observed ~5-min wedge).
    nonisolated static let askDeadlineSeconds: Double = 120

    private(set) var isRunning = false
    private(set) var statusText: String?

    var port: UInt16 {
        let stored = UserDefaults.standard.integer(forKey: Self.portKey)
        guard stored > 1023, stored <= 65535 else { return Self.defaultPort }
        return UInt16(stored)
    }

    /// Stored (not computed off UserDefaults) so @Observable actually tracks
    /// it — the Settings Toggle re-renders on this, not by coincidence of
    /// isRunning changing nearby.
    private(set) var isEnabled: Bool

    init(environment: AppEnvironment) {
        env = environment
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    func startIfEnabled() {
        guard isEnabled else { return }
        Task { await start() }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        Task { enabled ? await start() : await stop() }
    }

    func start() async {
        guard server == nil else { return }
        // One job store for the server's lifetime — captured in the ask_m1k3 /
        // get_answer closures so a long turn submitted on one request is fetchable
        // on a later one (the HTTP transport is stateless per-request).
        let intelligenceJobStore = AskJobStore()
        let registry = MCPToolRegistry(
            makeKnowledgeToolDefinitions(store: env.store, embedder: env.embedder)
                + makeVoiceToolDefinitions(handlers: makeVoiceHandlers())
                + makeIntelligenceToolDefinitions(handlers: makeIntelligenceHandlers(), jobStore: intelligenceJobStore)
                + makeOpenLinkToolDefinitions(handlers: makeOpenLinkHandlers())
                + memoryToolDefinitions(),
            // Opt-in Agent Interaction Log (Settings toggle, OFF by default —
            // the store self-gates on every call). Only this in-app HTTP
            // surface is wired for v1; the stdio M1K3MCP binary's registry
            // carries no sink — a follow-up if that surface wants the log too.
            logSink: env.conversationLog
        )
        let host = LocalMCPHTTPServer(
            port: port,
            onAbnormalStop: { [weak self] reason in
                Task { @MainActor [weak self] in
                    self?.server = nil
                    self?.isRunning = false
                    self?.statusText = "Stopped: \(reason)"
                }
            }
        ) {
            let transport = StatelessHTTPServerTransport()
            let mcpServer = await makeM1K3Server(registry: registry)
            try await mcpServer.start(transport: transport)
            return (mcpServer, transport)
        }
        do {
            try await host.start()
            server = host
            isRunning = true
            statusText = "Running on 127.0.0.1:\(port)"
        } catch {
            server = nil
            isRunning = false
            statusText = "Couldn’t start: \(error.localizedDescription)"
        }
    }

    func stop() async {
        await server?.stop()
        server = nil
        isRunning = false
        statusText = nil
    }

    // MARK: - Voice tool handlers

    /// The bridge between the Sendable tool closures (called on the server
    /// actor) and the MainActor app surfaces. Guards keep MCP from talking
    /// over a live voice conversation or an in-flight chat turn.
    private func makeVoiceHandlers() -> VoiceToolHandlers {
        VoiceToolHandlers(
            speak: { [weak self] text, emotion, wait in
                guard let self else { throw MCPVoiceError("M1K3 is shutting down") }
                try await self.env.intelligenceSpeak(text: text, emotion: emotion, wait: wait)
            },
            stopSpeaking: { [weak self] in
                await self?.env.stopSpeaking()
            },
            status: { [weak self] in
                await self?.voiceStatus() ?? VoiceStatus(providerName: "none", tier: "none", isSpeaking: false)
            },
            listen: { [weak self] timeout in
                guard let self else { throw MCPVoiceError("M1K3 is shutting down") }
                return try await self.listenForTranscript(timeout: timeout)
            }
        )
    }

    private func voiceStatus() async -> VoiceStatus {
        // speaking covers the Kokoro synthesis gap too: the highlight's
        // utterance text is set at utterance start and cleared on end.
        let speaking = await env.speech.isSpeaking() || env.speechHighlight.utteranceText != nil
        return VoiceStatus(
            providerName: env.speech.active.name,
            tier: env.selectedVoiceTier.displayName,
            brain: env.selectedBrain.displayName,
            isSpeaking: speaking,
            inConversation: env.voiceLoop != nil || env.chat.isResponding,
            micInUse: env.voiceLoop != nil || env.isListening || env.isRecording,
            answering: env.intelligenceAskInFlight
        )
    }

    // MARK: - Intelligence tool handlers

    /// The MCP adapter over the shared intelligence surface: ask_m1k3 and remember
    /// run on AppEnvironment's one dedicated responder + single-flight lock + canary
    /// + memory-graph dual-write — the same core the App Intents use. See
    /// AppEnvironment+Intelligence.swift.
    private func makeIntelligenceHandlers() -> IntelligenceToolHandlers {
        IntelligenceToolHandlers(
            ask: { [weak self] question in
                guard let self else { throw MCPVoiceError("M1K3 is shutting down") }
                return try await self.env.intelligenceAsk(question)
            },
            remember: { [weak self] title, text, kind in
                guard let self else { throw MCPVoiceError("M1K3 is shutting down") }
                return try await self.env.intelligenceRemember(
                    title: title, text: text, provenance: "mcp:remember", kind: kind
                )
            }
        )
    }

    // MARK: - Open-link tool handler

    /// The MCP adapter over the review panel: a visiting agent opens a web page in
    /// M1K3's on-screen panel. Validated web-only through the shared resolver (the
    /// same routing the panel and the local agent use); a non-web string is
    /// refused rather than silently dropped.
    private func makeOpenLinkHandlers() -> OpenLinkToolHandlers {
        OpenLinkToolHandlers(
            open: { [weak self] raw in
                guard let self else { throw MCPVoiceError("M1K3 is shutting down") }
                return try await self.openLinkInPanel(raw)
            }
        )
    }

    private func openLinkInPanel(_ raw: String) throws -> String {
        guard case let .web(url) = ReviewTargetResolver.resolve(raw) else {
            throw MCPVoiceError("\"\(raw)\" isn't a web link M1K3 can open.")
        }
        // A visiting agent must not drive the embedded WebView at the user's local
        // network — the fetch runs on the user's Mac (SSRF-lite). Public web only.
        guard !WebURLPolicy.isLocalOrPrivate(url) else {
            throw MCPVoiceError("M1K3 won't open local or private-network addresses.")
        }
        env.review.open(url: url)
        return "Opened \(url.host ?? url.absoluteString) in M1K3's review panel."
    }

    // MARK: - Memory-graph tool handlers

    /// recall_memory / related_memory / memory_stats over the temporal memory
    /// graph. Each closure embeds the query with `env.embedder` (the same space
    /// the dual-write stores into) and reads the live MemoryStore. Inert when no
    /// MemoryStore opened (best-effort, like the dual-write) — recall returns
    /// empty, stats returns zero.
    private func memoryToolDefinitions() -> [MCPToolDefinition] {
        let embedder = env.embedder
        let memoryStore = env.memoryStore
        let knowledgeStore = env.store // forget_memory clears the dual-written corpus twin too
        let environment = env // captured for the MainActor count refresh after a forget
        let handlers = MemoryToolHandlers(
            recall: { query in
                guard let memoryStore else { return [] }
                let vector = try await embedder.embedQuery(query)
                // Recall bar follows the ACTIVE embedder's cone (the Settings
                // toggle can put the Mac on hashing) — EmbedderFloors, PR #89.
                // forget's threshold-0 candidate search below is deliberate
                // and stays (its 0.6 confidence bar gates, not the floor).
                return try memoryStore.recall(
                    query: query, queryVector: vector,
                    threshold: EmbedderFloors.forFingerprint(embedder.fingerprint).memory
                )
            },
            related: { query in
                guard let memoryStore else { return nil }
                let vector = try await embedder.embedQuery(query)
                guard let seed = try memoryStore.recall(
                    query: query, queryVector: vector, limit: 1,
                    threshold: EmbedderFloors.forFingerprint(embedder.fingerprint).memory
                ).first else {
                    return nil
                }
                return try (seed.memory, memoryStore.related(to: seed.memory.id))
            },
            stats: {
                guard let memoryStore else { return MemoryStatsSummary(liveCount: 0) }
                return try MemoryStatsSummary(liveCount: memoryStore.liveCount())
            },
            forget: { query in
                guard let memoryStore else { return .notConfident(closest: nil) }
                // Forget is FACT-TO-FACT matching, not retrieval: the caller
                // repeats the remembered text, so the query embeds BARE (a
                // verbatim repeat is cosine ≈ 1.0; the instruction would only
                // depress it) and the ForgetResolver 0.6 confidence bar keeps
                // its bare-tuned meaning. Candidates search with threshold 0 —
                // recall (instructed) and forget (bare) rank differently near
                // the floor, and the graceful chain (surface closest → invite
                // word-for-word repeat) must never sever just because the
                // bare cosine dipped under the recall floor. The 0.6 bar, not
                // this candidate search, gates the actual delete.
                let vector = try await embedder.embed(query)
                // limit raised 3 → 12 on 2026-08-09: the resolver now requires the caller
                // to have NAMED the fact, so the exact row has to be IN the candidate
                // set to be deletable at all. At 3 a verbatim request routinely missed
                // its own target and the old rank-1 rule deleted a neighbour instead.
                let hits = try memoryStore.recall(query: query, queryVector: vector, limit: 12, threshold: 0)
                switch ForgetResolver.resolve(hits: hits, query: query) {
                case let .forget(memory):
                    try memoryStore.forget(id: memory.id)
                    // Forget the dual-written twin in the document corpus too, matched by
                    // the SAME content-identity the remember dedup uses — else
                    // search_knowledge/ask keep a ghost and "forget" is a half-truth
                    // (this is the consent promise, and the canary's leak surface).
                    // Indexed `source_ref` lookup, NOT a capped scan — the "no residue"
                    // claim must hold regardless of how many facts are stored.
                    // (A superseded predecessor revived by memoryStore.forget keeps its
                    // own corpus twin — correct: it's live again.)
                    let ref = MemoryDistillationCoordinator.factSourceRef(memory.text)
                    if let twinID = try? knowledgeStore.itemID(forSourceRef: ref) {
                        // Graph delete already committed; if the corpus twin survives a
                        // write hiccup, log it so "no residue" stays auditable rather
                        // than a silent half-truth (mirrors the dual-write error channel).
                        let deleted = (try? knowledgeStore.deleteItem(id: twinID)) ?? false
                        if !deleted {
                            Self.securityLog.error("forget_memory: corpus twin NOT deleted (graph delete stood)")
                        }
                    }
                    await MainActor.run { environment.refreshCounts() }
                    return .forgotten(text: memory.text)
                case let .notConfident(closest):
                    return .notConfident(closest: closest?.text)
                }
            }
        )
        return makeMemoryToolDefinitions(handlers: handlers)
    }

    /// Pull-model transcription for the `listen` tool: open the active STT
    /// stream, return once the speaker pauses (~2 s of no new words) or the
    /// timeout passes. Mirrors dictation's accumulator; never touches
    /// dictation's own state.
    private func listenForTranscript(timeout: Double) async throws -> String {
        guard env.voiceLoop == nil, !env.isListening, !env.isRecording else {
            throw MCPVoiceError("M1K3's microphone is already in use")
        }
        guard let provider = env.transcription.activeProvider else {
            throw MCPVoiceError("no speech recognizer is available")
        }
        // Don't open the mic over our own voice (the speak→listen race):
        // wait, bounded, for any in-progress utterance to finish.
        let quietDeadline = Date().addingTimeInterval(20)
        while Date() < quietDeadline,
              await env.speech.isSpeaking() || env.speechHighlight.utteranceText != nil
        {
            try? await Task.sleep(for: .milliseconds(150))
        }
        env.avatar.setActivity(.listening)
        defer { env.avatar.resetToIdle() }

        let stream = try provider.startListening()
        let session = ListenProgress()
        let consumer = Task { @MainActor in
            var accumulator = TranscriptAccumulator()
            for await segment in stream {
                accumulator.ingest(segment)
                session.update(text: accumulator.text)
            }
            return accumulator.text
        }
        // Watchdog: endpoint on silence-after-speech or the hard timeout.
        let watchdog = Task { @MainActor in
            let started = Date()
            while !session.finished {
                try? await Task.sleep(for: .milliseconds(200))
                let waited = Date().timeIntervalSince(started)
                let quiet = Date().timeIntervalSince(session.lastChange)
                if waited >= timeout || (!session.text.isEmpty && quiet >= 2.0) {
                    provider.stopListening() // stream drains → consumer returns
                    break
                }
            }
        }
        // Bound the drain itself: stopListening() SHOULD end the stream, but a
        // misbehaving provider must not hang the MCP call forever (and leak
        // the listening avatar state). AsyncStream iteration honours task
        // cancellation, so cancelling the consumer ends the for-await.
        let drainDeadline = Task { @MainActor in
            try? await Task.sleep(for: .seconds(timeout + 5))
            consumer.cancel()
        }
        let text = await consumer.value
        drainDeadline.cancel()
        session.finished = true
        watchdog.cancel()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Mutable listen-session state shared between the consumer and watchdog
/// tasks — both run on the MainActor, so plain vars are race-free.
@MainActor
private final class ListenProgress {
    var text = ""
    var lastChange = Date()
    var finished = false

    func update(text newText: String) {
        guard newText != text else { return }
        text = newText
        lastChange = Date()
    }
}
