//
//  ChatSession.swift
//  M1K3Chat
//
//  The chat state the SwiftUI shell binds to. @MainActor + @Observable so views
//  observe `messages`/`isResponding` directly; all mutation is main-actor hopped,
//  which is also where SwiftUI wants its updates. The logic that actually carries
//  bugs — folding a streamed answer into displayable state — lives here under
//  test, not in a View, so the shell stays dumb (per the app-shell plan).
//
//  Streaming normalisation: the InferenceProvider contract is "cumulative-or-delta
//  (backend-defined)". Apple Foundation Models yields cumulative snapshots; the
//  lighter providers yield deltas. `fold` detects which per-chunk — if the chunk
//  extends what we have (`hasPrefix`), it's a snapshot and replaces; otherwise
//  it's a delta and appends. One reducer renders both correctly.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.85, Prior: Unknown
//  Review: Kev + claude-opus-4-8, 2026-06-30, Confidence 0.85 — distillation
//  gained a ROLLING trigger (was exit/launch only, "never per turn"). Once the
//  undistilled backlog outgrows the live HistoryWindow it distils mid-session, so
//  a long live conversation's early turns become retrievable facts before they
//  fall out of context — the other half of the context-headroom work. The
//  isResponding guard moved to the exit/launch path; the rolling path runs at
//  end-of-send (streaming done) so it can't contend with a live response.
//  Review: Kev + claude-fable-5, 2026-07-16, Confidence 0.85 (concurrency deep
//  pass, findings 25/30) — persistActiveConversation no longer runs the
//  O(conversation) JSON encode + SQLite write ON the MainActor at the end of
//  every send. It now calls a NEW `ChatHistoryPersisting.saveAsync`, which the
//  GRDB store implements with a native `dbQueue.write { }` (encode + write on the
//  DB's own queue — the codebase precedent in MemoryStore/KnowledgeStore), AWAITED
//  inline so every persistence invariant holds (row present when send returns,
//  ordering, no delete-resurrection under the isResponding guard). The synchronous
//  `save` is KEPT: it is driven by the one-time TranscriptMigrator inside
//  AppEnvironment's SYNCHRONOUS init(), so async-ifying it would have forced init()
//  async (a composition-root ripple into a parked-WIP file). A protocol-default
//  saveAsync hops the sync save off-caller for the non-GRDB conformers; a
//  Thread.isMainThread probe pins the default off-main. Named residual: a
//  DatabaseQueue serialises reads with writes, so the unguarded History-drawer read
//  can still block main behind a write (narrower than the original; full fix is a
//  DatabasePool/WAL split). switchTo's decode + init restore stay sync (follow-ups).

import Foundation
import M1K3Inference
import M1K3Knowledge
import Observation
import os

/// The seam ChatSession drives. RAGResponder conforms; tests inject fakes so the
/// reducer is exercised without a model, store, or embedder.
///
/// Default chain is strictly ONE-WAY (history → activity → plain): the richer
/// variants fall through to the plain one, which has NO default — so every
/// conformer must ground the chain, and a half-implemented conformer is a
/// compile error, never a mutual-default infinite recursion (the PR #15
/// review's blocking finding).
public protocol RAGResponding: Sendable {
    /// Stream the answer. The stream is the model's RAW output — citation validation
    /// can't happen mid-stream, so the CALLER must validate the accumulated text once
    /// the stream finishes (see `ChatSession.send`, which runs `CitationValidator`
    /// against `sources`). This is the deliberate counterpart to the blocking
    /// `RAGResponder.answer()`, which validates internally before returning.
    func answerStreaming(
        _ question: String
    ) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>)

    /// As above, additionally reporting progress (retrieval, agent thinking,
    /// tool use) so the UI can show what's happening before tokens arrive.
    func answerStreaming(
        _ question: String,
        onActivity: @escaping @Sendable (ResponderActivity) -> Void
    ) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>)

    /// As above, with a capped replay of recent turns so follow-up questions
    /// carry their context ("and in Fahrenheit?"). Responders that don't use
    /// history fall through to the history-free variant.
    func answerStreaming(
        _ question: String,
        history: [ChatTurn],
        onActivity: @escaping @Sendable (ResponderActivity) -> Void
    ) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>)

    /// As above, with images the user attached to this turn. Only a
    /// vision-capable responder consumes them (Big via the VLM load path);
    /// the default drops them and falls through to the history variant, so
    /// text-only responders behave exactly as before.
    func answerStreaming(
        _ question: String,
        images: [ImageAttachment],
        history: [ChatTurn],
        onActivity: @escaping @Sendable (ResponderActivity) -> Void
    ) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>)

    /// Sources gathered DURING the turn by tools the model called (e.g.
    /// search_knowledge). DESTRUCTIVE: this is a draining read — a second call
    /// returns empty. Call exactly once, after the stream completes; the hits
    /// merge into the message's sources and the citation validator's allow-list.
    /// Defaults to empty for responders without tools.
    func collectedSources() -> [ChunkHit]
}

public extension RAGResponding {
    func answerStreaming(
        _ question: String,
        onActivity _: @escaping @Sendable (ResponderActivity) -> Void
    ) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>) {
        try await answerStreaming(question)
    }

    func answerStreaming(
        _ question: String,
        history _: [ChatTurn],
        onActivity: @escaping @Sendable (ResponderActivity) -> Void
    ) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>) {
        try await answerStreaming(question, onActivity: onActivity)
    }

    func answerStreaming(
        _ question: String,
        images _: [ImageAttachment],
        history: [ChatTurn],
        onActivity: @escaping @Sendable (ResponderActivity) -> Void
    ) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>) {
        try await answerStreaming(question, history: history, onActivity: onActivity)
    }

    func collectedSources() -> [ChunkHit] {
        []
    }
}

/// The plain-text provenance line appended when an answer leaves the app via a
/// share sheet. One constant for both platform share surfaces (MessageView on
/// Mac, MessageBubble on iOS) so the wording can't drift between them.
public enum ShareSignature {
    public static let answerSuffix = "\n\n— Shared from M1K3 · m1k3.app"
}

/// One turn in the transcript. `sources` are the chunks the answer was grounded
/// in (attached before tokens arrive, so the UI can show provenance up front).
public struct ChatMessage: Identifiable, Sendable, Equatable, Codable {
    public enum Role: Sendable, Equatable, Codable { case user, assistant }
    public enum Status: Sendable, Equatable, Codable {
        case complete
        case streaming
        case failed(String)
    }

    public let id: UUID
    public let role: Role
    public var text: String
    public var sources: [ChunkHit]
    /// Citations the model made that were validated against `sources` (hallucinated
    /// ones are stripped from `text`). Derived at response time — deliberately omitted
    /// from `CodingKeys` so it isn't persisted and old transcripts still decode.
    public var citations: [Citation] = []
    /// What the responder is doing right now ("Searching the web…"), shown while
    /// `.streaming` and no tokens have arrived. Transient — omitted from
    /// `CodingKeys` like `citations`.
    public var activityLabel: String?
    /// A reasoning model's `<think>…</think>` chain-of-thought, separated from
    /// the answer and surfaced (collapsibly) for transparency. Persisted as an
    /// optional key, so old transcripts (without it) still decode to nil.
    public var reasoning: String?
    /// Per-turn generation stats (context tokens, throughput) for the in-app
    /// testing readout. Transient — omitted from `CodingKeys` like `activityLabel`,
    /// so it isn't persisted and old transcripts still decode. MLX tiers only
    /// (Apple Foundation Models / Mini reports no throughput).
    public var metrics: GenerationMetrics?
    /// Up to 3 tap-to-send follow-up questions, parsed from the model's
    /// trailing "FOLLOWUPS: [...]" line (see FollowUpSplit). Deliberately NOT
    /// persisted (Kev's call, 2026-07-14): a reloaded old conversation showing
    /// stale suggested questions for a topic the chat has moved past would
    /// read as odd, not helpful. Transient — omitted from `CodingKeys` like
    /// `citations`/`activityLabel`/`metrics`, so old transcripts still decode.
    public var followUps: [String] = []
    /// Images the user attached to this turn — file URLs inside the app
    /// container (the composer copies attachments in before sending, so
    /// history replay can re-open them). Optional so pre-vision transcripts
    /// decode to nil (the `reasoning` precedent); nil and empty mean the same.
    public var attachments: [ImageAttachment]?
    public var status: Status

    enum CodingKeys: String, CodingKey {
        case id, role, text, sources, status, reasoning, attachments
    }

    public init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        sources: [ChunkHit] = [],
        citations: [Citation] = [],
        reasoning: String? = nil,
        attachments: [ImageAttachment]? = nil,
        status: Status
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.sources = sources
        self.citations = citations
        self.reasoning = reasoning
        self.attachments = attachments
        self.status = status
    }
}

/// Persists the chat transcript to a JSON file so a relaunch keeps the
/// conversation. Pure file I/O over Codable messages — no AppKit, fully testable.
public struct ChatTranscriptStore: Sendable {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> [ChatMessage] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ChatMessage].self, from: data)) ?? []
    }

    public func save(_ messages: [ChatMessage]) {
        guard let data = try? JSONEncoder().encode(messages) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

@MainActor
@Observable
public final class ChatSession {
    private static let log = Logger(subsystem: "app.m1k3", category: "chat-session")
    /// `security`, not `chat-session`: a prompt leak reaching the user is a
    /// security event, and it belongs with the other leak tripwires in an
    /// issue-report capture rather than buried in conversation lifecycle.
    private static let leakLog = Logger(subsystem: "app.m1k3", category: "security")
    public private(set) var messages: [ChatMessage] = []
    public private(set) var isResponding = false

    /// The conversation the transcript belongs to. Rows are created LAZILY —
    /// only `send` writes — so empty conversations never reach the store.
    public private(set) var activeConversationID = UUID()
    /// nil until auto-titled (UI shows "New chat").
    public private(set) var activeTitle: String?
    /// Bumped on every persist/title/delete — the history drawer reads this
    /// observable counter to re-fetch summaries (the CallsView callCount trick).
    public private(set) var historyRevision = 0

    private let responder: any RAGResponding
    /// Internal (not private): ChatSession+Conversations.swift is a cross-file
    /// same-module extension and needs the seams.
    let history: (any ChatHistoryPersisting)?
    let titler: (any ConversationTitling)?
    /// nil = memory auto-capture not wired (feature off, tests unaffected).
    let distillation: MemoryDistillationCoordinator?
    /// Read fresh at every trigger — the Settings toggle applies immediately
    /// (the thinkingModeProvider pattern).
    let autoCaptureEnabled: @Sendable () -> Bool
    /// Test hook — `await titlingTask?.value` makes fire-and-forget titling
    /// deterministic in tests.
    private(set) var titlingTask: Task<Void, Never>?
    /// Test hook, same contract as titlingTask. Single-flight: a skipped
    /// trigger is caught at the next exit because the watermark didn't move.
    private(set) var distillationTask: Task<Void, Never>?

    /// Launch catch-up waits this long so it never contends with the user's
    /// first turn for the model.
    nonisolated static let launchCatchUpDelay: Duration = .seconds(5)
    /// A monster legacy transcript distills at most this many recent turns
    /// (DEFAULT-0 watermarks mean old conversations distill once, in full).
    nonisolated static let maxDistillationTurns = 40

    /// Rolling-distillation trigger: fire mid-session once the UN-distilled
    /// backlog (messages past the watermark) outgrows what the live
    /// `HistoryWindow` can replay, plus a small batch so it fires ~every few
    /// exchanges rather than every turn. Below this, distillation stays on the
    /// exit/launch path; above it, a long live session's early turns become
    /// retrievable facts shortly after they fall out of context — closing the
    /// mid-session amnesia gap the wider window alone can't.
    nonisolated static let rollingDistillBacklog = HistoryWindow.maxTurns + 4

    /// Pure policy (so it's TDD'd without the async machinery): is the
    /// undistilled backlog large enough to distill now?
    nonisolated static func shouldRollingDistill(messageCount: Int, watermark: Int) -> Bool {
        messageCount - watermark >= rollingDistillBacklog
    }

    public init(
        responder: any RAGResponding,
        history: (any ChatHistoryPersisting)? = nil,
        titler: (any ConversationTitling)? = nil,
        distillation: MemoryDistillationCoordinator? = nil,
        autoCaptureEnabled: @escaping @Sendable () -> Bool = { true }
    ) {
        self.responder = responder
        self.history = history
        self.titler = titler
        self.distillation = distillation
        self.autoCaptureEnabled = autoCaptureEnabled
        // Relaunch restores the most recent conversation — the same feel the
        // single-transcript file gave, now one of many.
        if let history,
           let recent = try? history.list().first,
           let restored = try? history.loadMessages(id: recent.id)
        {
            messages = restored
            activeConversationID = recent.id
            activeTitle = recent.title
        }
        // Launch catch-up: a quit-without-switching leaves undistilled turns
        // behind; distill the restored conversation's backlog now (delayed —
        // never racing the user's first turn). App-quit-time distillation was
        // rejected: a fire-and-forget task racing termination loses silently.
        if distillation != nil, !messages.isEmpty {
            Task { [weak self] in
                try? await Task.sleep(for: Self.launchCatchUpDelay)
                self?.scheduleDistillationIfNeeded()
            }
        }
    }

    /// Send a user turn and stream the grounded answer into a new assistant
    /// message. Blank input and re-entrant sends are no-ops.
    public func send(_ text: String, images: [ImageAttachment] = []) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isResponding else { return }

        // Capture the replayable history BEFORE this turn joins the transcript:
        // completed turns only, answer text only (reasoning/sources never leave
        // the message). HistoryWindow caps how much of it reaches the prompt.
        let history = messages.compactMap { message -> ChatTurn? in
            guard case .complete = message.status, !message.text.isEmpty else { return nil }
            return ChatTurn(role: message.role == .user ? .user : .assistant, text: message.text)
        }

        messages.append(ChatMessage(
            role: .user, text: trimmed,
            attachments: images.isEmpty ? nil : images,
            status: .complete
        ))
        let assistantID = UUID()
        messages.append(ChatMessage(id: assistantID, role: .assistant, text: "", status: .streaming))

        isResponding = true
        defer { isResponding = false }

        do {
            let (sources, stream) = try await responder.answerStreaming(
                trimmed,
                images: images,
                history: history,
                onActivity: { [weak self] activity in
                    Task { @MainActor in
                        self?.update(assistantID) {
                            $0.activityLabel = ActivityLabeler.label(for: activity)
                        }
                    }
                }
            )
            update(assistantID) { $0.sources = sources }
            // Route chunks to reasoning vs answer LIVE, so chain-of-thought
            // streams into the disclosure as it happens instead of flashing
            // raw <think> text in the bubble until the stream ends.
            var splitter = StreamingReasoningSplitter()
            // Chained onto the reasoning splitter's live answer: hides the
            // "FOLLOWUPS: [...]" trailer as it streams in, same reasoning as
            // the think-tag split — a raw JSON fragment flashing in the
            // bubble for a frame is the exact leak class this project has
            // repeatedly hardened against. Fed the CUMULATIVE splitter.answer
            // each iteration; StreamFold.delta normalises it like any other
            // cumulative-or-delta source. Known theoretical gap (named, not
            // fixed): StreamingReasoningSplitter's lone-</think> retro-move
            // can shrink splitter.answer back to "" (Qwen3.5's pre-opened-
            // think quirk) — this splitter has no "un-feed" and would go
            // stale until real growth resumes. Zero live exposure today: Lil
            // and Big both moved off Qwen3.5 to dense Qwen3 / gemma-4
            // (2026-06-22), neither of which hits this path.
            var followUpSplitter = StreamingFollowUpSplitter()
            // Coalesce token updates to ~display rate: a fast model emits chunks
            // faster than the eye (or the transcript ForEach) can keep up, and
            // invalidating @Observable state per token is the visible-reasoning
            // jank. The settled state is always flushed by the authoritative
            // update after the loop, so a coalesced-out tail loses nothing.
            var flushGate = StreamFlushGate()
            for await chunk in stream {
                splitter.feed(chunk)
                followUpSplitter.feed(splitter.answer)
                guard flushGate.shouldFlush(at: .now) else { continue }
                let liveAnswer = followUpSplitter.answer
                let liveReasoning = splitter.reasoning
                update(assistantID) {
                    $0.text = liveAnswer
                    $0.reasoning = liveReasoning.isEmpty ? nil : liveReasoning
                    // Real tokens replace the activity label.
                    $0.activityLabel = nil
                }
            }
            splitter.finish()
            // Now the full text is in hand. Re-split the RAW stream as the
            // final authority (the live splitters only drive rendering), then
            // strip invented citations from the ANSWER and record the
            // validated ones. The allow-list covers BOTH the injected sources
            // and whatever the model retrieved itself via search_knowledge.
            let (reasoning, answerWithFollowUps) = ReasoningSplit.split(splitter.raw)
            let (answer, followUps) = FollowUpSplit.split(answerWithFollowUps)
            let mergedSources = Self.mergeSources(sources, responder.collectedSources())
            let validation = await CitationValidator.validate(responseText: answer, against: mergedSources)
            // Prompt-leak guard (#111): the model reproduced its own wiring.
            // Persona rule 1 forbids it, but a prompt cannot enforce itself and
            // Mini does it unprompted (2026-08-08 scorecard). Applied to the
            // FINAL text — streaming already showed tokens, so this is the last
            // point that can stop it being persisted, spoken, or distilled into
            // a memory. Sources and citations are dropped with it: a leak cites
            // nothing real.
            let leaked = PersonaLeakGuard.leaks(validation.cleanedText)
            if leaked {
                Self.leakLog.error("prompt-leak guard: chat answer reproduced the persona")
            }
            update(assistantID) {
                $0.sources = leaked ? [] : mergedSources
                // Tidy whitespace once the full text is in hand. Markdown
                // markup survives on purpose — ReadingText renders it as real
                // blocks now; SpeechTextPolish owns the flatten for TTS.
                $0.text = leaked
                    ? PersonaLeakGuard.refusal
                    : MessageTextPolish.polish(validation.cleanedText)
                $0.citations = leaked ? [] : validation.validated
                $0.reasoning = leaked ? nil : reasoning
                $0.followUps = leaked ? [] : followUps
                $0.activityLabel = nil
                $0.status = .complete
            }
        } catch {
            update(assistantID) { msg in
                msg.status = .failed(String(describing: error))
                msg.activityLabel = nil
                if msg.text.isEmpty {
                    msg.text = ChatFailureMessage.userFacing(for: error)
                }
            }
        }
        await persistActiveConversation()
        scheduleTitlingIfNeeded(question: trimmed)
        // Rolling distillation: a no-op until the backlog outgrows the window,
        // then it captures the long tail mid-session so it stays recoverable.
        scheduleRollingDistillationIfNeeded()
    }

    /// Deliver a BACKGROUND answer (delegate_deep's landing pad, 2026-07-25)
    /// as a completed assistant message: no user bubble, no streaming
    /// placeholder, no responder call — the delegated agent already ran on the
    /// deep lane. Gets the same FOLLOWUPS split + text polish an ordinary turn
    /// gets so chips and house formatting behave identically, and persists at
    /// once. Citations arrive as plain text in this path (the delegated run's
    /// tool sources aren't threaded through — a named v1 gap, not an
    /// oversight: CitationValidator needs the sources list to validate
    /// against, and the background lane doesn't collect one yet).
    public func deliverBackgroundAnswer(_ text: String) async {
        let (answer, followUps) = FollowUpSplit.split(text)
        let polished = MessageTextPolish.polish(answer)
        guard !polished.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Same guard as the live path (#111). The delegated lane runs the same
        // persona through the same models, so it can leak the same way — and it
        // arrives unattended, which is worse.
        guard !PersonaLeakGuard.leaks(polished) else {
            Self.leakLog.error("prompt-leak guard: background answer reproduced the persona")
            messages.append(ChatMessage(role: .assistant, text: PersonaLeakGuard.refusal, status: .complete))
            await persistActiveConversation()
            return
        }
        var message = ChatMessage(role: .assistant, text: polished, status: .complete)
        message.followUps = followUps
        messages.append(message)
        await persistActiveConversation()
    }

    /// Save the live transcript to the active conversation's row and tell the
    /// drawer to refresh. Lazy row creation happens here — nowhere else writes.
    ///
    /// ChatSession is `@MainActor`, so the O(conversation) JSON encode + SQLite
    /// write this drives used to land ON the main thread at the end of every
    /// send — a hitch exactly at answer completion, competing with the final
    /// message re-render and the avatar transition, and growing linearly with
    /// conversation length (finding 25/30). It now goes through
    /// `ChatHistoryPersisting.saveAsync`, which the GRDB store implements with a
    /// native `dbQueue.write { }` (encode + write on the DB's own queue, off the
    /// MainActor). Awaited inline (not fire-and-forget): the row is present the
    /// instant `send` returns (the ~10 pinned persistence tests rely on it),
    /// `switchTo`'s "current one is already persisted" precondition still holds,
    /// and no detached upsert can resurrect a row a racing `deleteConversation`
    /// removed. The `isResponding` `defer` in `send` has not fired at the call
    /// site, so the existing switch/delete/new-conversation guards keep excluding
    /// overlap and write ordering is preserved. `historyRevision` bumps on the
    /// MainActor after the write completes.
    ///
    /// Residual (named, not fixed): `GRDBChatHistoryStore` is a `DatabaseQueue`,
    /// which serialises reads and writes on one queue. The unguarded
    /// `conversationSummaries()` read (the History drawer, usable mid-send) can
    /// therefore still block the MainActor behind an in-flight write. This is a
    /// NARROWER stall than the original (only when the drawer is open during a
    /// send, and net-lower main-thread time than the old always-on-main write),
    /// but its full fix is a `DatabasePool`/WAL read-write split — a separate
    /// store change. (Encode now runs inside the write closure, so on the rare
    /// contended read the main-thread wait covers encode+insert, not just insert
    /// — longer per hit, but far rarer than the old every-turn on-main cost.)
    /// The mirror-image blocking decode in `switchTo` and the one-time init
    /// restore likewise stay synchronous (follow-ups).
    func persistActiveConversation() async {
        guard let history else { return }
        do {
            try await history.saveAsync(
                id: activeConversationID, messages: messages, updatedAt: Date()
            )
        } catch {
            // The transcript silently failed to persist while the UI looks saved —
            // record it (GRDB redacts SQL args by default, so this is PII-safe).
            Self.log.error("conversation save failed: \(error.localizedDescription, privacy: .public)")
        }
        historyRevision += 1
    }

    /// The one mutation point ChatSession+Conversations routes through —
    /// private(set) setters are file-scoped, so the cross-file extension
    /// cannot (and must not) touch the stored properties directly.
    func setActiveConversation(id: UUID, messages: [ChatMessage], title: String?) {
        self.messages = messages
        activeConversationID = id
        activeTitle = title
    }

    func noteHistoryChanged() {
        historyRevision += 1
    }

    /// Fire-and-forget auto-titling after a successful exchange of an untitled
    /// conversation. Never blocks send; failure or garbage output just means
    /// "retry after the next exchange". The conversation id is captured at
    /// spawn so a title resolving after a switch/new lands on the RIGHT row.
    private func scheduleTitlingIfNeeded(question: String) {
        guard let history, let titler, activeTitle == nil, titlingTask == nil else { return }
        guard let answer = messages.last, answer.role == .assistant,
              case .complete = answer.status, !answer.text.isEmpty else { return }
        let conversationID = activeConversationID
        let answerText = answer.text
        titlingTask = Task { [weak self] in
            defer { self?.titlingTask = nil }
            guard let raw = try? await titler.title(forUser: question, assistant: answerText),
                  let title = TitleSanitizer.sanitize(raw) else { return }
            try? history.setTitle(id: conversationID, title: title)
            guard let self else { return }
            if self.activeConversationID == conversationID {
                self.activeTitle = title
            }
            self.historyRevision += 1
        }
    }

    /// Fire-and-forget memory distillation over the transcript content the
    /// watermark hasn't covered. Driven from three places: conversation EXIT
    /// (new/switch, BEFORE the swap), the launch catch-up, and — once the
    /// backlog outgrows the window — mid-session via the rolling trigger. Never
    /// on delete (deletion is discard intent). The titling blueprint throughout:
    /// id + count captured at spawn, defer cleanup, task exposed for tests.
    /// Watermark advances ONLY on success (a throw leaves the slice for the
    /// next trigger to retry).
    func scheduleDistillationIfNeeded() {
        // Exit/launch path: never distil while a response is actively streaming
        // (it would contend with the user's turn for the model). The rolling
        // path runs at end-of-send when streaming is already done, so it goes
        // through `spawnDistillation` directly.
        guard !isResponding else { return }
        spawnDistillation()
    }

    /// Mid-session ("rolling") trigger: when the undistilled backlog has outgrown
    /// the live window, capture it now so a long session's early turns survive as
    /// facts. Called at the tail of `send` — streaming has COMPLETED by then, but
    /// note the `isResponding` latch is still up (send's defer hasn't fired), so
    /// the no-contention guarantee is positional (end-of-send), not latch-derived
    /// (112 review nit: the old comment claimed the latch was already down).
    /// Single-flight + watermark guards in `spawnDistillation` keep it from
    /// over-firing.
    func scheduleRollingDistillationIfNeeded() {
        guard let history, distillation != nil, autoCaptureEnabled() else { return }
        let watermark = (try? history.distilledWatermark(id: activeConversationID)) ?? 0
        guard Self.shouldRollingDistill(messageCount: messages.count, watermark: watermark) else { return }
        spawnDistillation()
    }

    /// The distillation worker, deliberately WITHOUT an `isResponding` guard.
    /// ⚠️ Contract: callers must guarantee no response is actively streaming —
    /// `scheduleDistillationIfNeeded` enforces it via the latch for the
    /// exit/launch path; the rolling path calls in at end-of-send, where
    /// streaming is done but `isResponding` is STILL TRUE (so a latch check
    /// here would wrongly reject it — the guarantee is positional). A new
    /// call site MUST uphold this or distillation will contend with a live turn.
    private func spawnDistillation() {
        guard let history, let distillation, autoCaptureEnabled() else { return }
        guard distillationTask == nil else { return }
        let conversationID = activeConversationID
        let snapshotCount = messages.count
        let watermark = (try? history.distilledWatermark(id: conversationID)) ?? 0
        guard watermark < snapshotCount else { return }
        let fresh = messages[min(watermark, snapshotCount)...].compactMap { message -> ChatTurn? in
            guard case .complete = message.status, !message.text.isEmpty else { return nil }
            return ChatTurn(role: message.role == .user ? .user : .assistant, text: message.text)
        }
        // At least one full new exchange — never distill a lone dangling turn.
        guard fresh.contains(where: { $0.role == .user }),
              fresh.contains(where: { $0.role == .assistant }) else { return }
        let turns = Array(fresh.suffix(Self.maxDistillationTurns))
        distillationTask = Task { [weak self] in
            defer { self?.distillationTask = nil }
            guard (try? await distillation.distillAndStore(turns: turns)) != nil else { return }
            try? history.setDistilledWatermark(id: conversationID, count: snapshotCount)
        }
    }

    /// Fold a streamed chunk into the accumulated answer — the shared
    /// snapshot-vs-delta rule (StreamFold owns the contract).
    nonisolated static func fold(_ current: String, _ chunk: String) -> String {
        StreamFold.fold(current: current, chunk: chunk)
    }

    /// Injected sources + what the model retrieved itself, deduped by chunk
    /// (injection order first, so the UI's source rows stay stable).
    nonisolated static func mergeSources(_ injected: [ChunkHit], _ collected: [ChunkHit]) -> [ChunkHit] {
        var seen = Set<UUID>()
        return (injected + collected).filter { seen.insert($0.chunkID).inserted }
    }

    private func update(_ id: UUID, _ mutate: (inout ChatMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        mutate(&messages[index])
    }

    /// Stamp the most recent assistant message with a completed turn's generation
    /// stats (the in-app testing readout). Called as each MLX generation within a
    /// turn finishes — an agent turn can generate several times (think, tool call,
    /// answer), so the LAST call wins: the badge shows the peak prompt/context and
    /// the answer's throughput. A no-op if there's no assistant message yet.
    public func recordMetrics(_ metrics: GenerationMetrics) {
        guard let index = messages.lastIndex(where: { $0.role == .assistant }) else { return }
        messages[index].metrics = metrics
    }

    /// Replace any <artifact>…</artifact> blocks in the last assistant message with a
    /// breadcrumb — call AFTER the document has been detected + opened in the panel, so
    /// the transcript stays clean while the document lives in the panel.
    public func stripArtifactTagsFromLastMessage() {
        guard let index = messages.lastIndex(where: { $0.role == .assistant }) else { return }
        messages[index].text = ChatArtifactDisplay.stripArtifactTags(messages[index].text)
    }
}
