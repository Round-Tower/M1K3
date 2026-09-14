//
//  AppleFoundationModelsProvider.swift
//  M1K3Inference
//
//  InferenceProvider backed by Apple's on-device Foundation Models. M1K3's
//  cheap/fast tier — short turns, the Tier-1 call summary, anything that
//  doesn't need Gemma 4's depth. Thin OS adapter: runtime selection lives in
//  the app's RuntimeInferenceProvider, so this file is verified by compiling
//  against the macOS 26 SDK + a name check, not by invoking the model (which
//  needs Apple Intelligence hardware).
//
//  Mirrors the prior call-pipeline's AppleFoundationModelsProvider.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.75,
//  Prior: internal call-pipeline project, AppleFoundationModelsProvider (Kev)
//  Review: Kev + claude-opus-5, 2026-08-03, Confidence 0.85 — NO functional
//  change; recording a measured NEGATIVE result so it isn't re-tried blind.
//
//  Mini keeps the COMPACT persona (no `voiceExemplars`). The standing reason
//  for withholding them is cost, and cost is not the reason: measured, they are
//  ~187 tokens of Mini's 4096-token window (4.5%) on top of a ~875-token
//  persona (MiniPromptBudgetTests). They were switched ON and the same 8-probe
//  MCP interview re-run — the register did not improve, and a new failure
//  appeared. Asked "Long day, I'm wrecked", Mini answered "Honey never spoils,
//  and there are edible jars in 3,000-year-old Egyptian tombs": exemplar 3,
//  verbatim, as CONTENT — the exact risk `voiceExemplars`' own header documents
//  for weak models. Abstention degraded too. So Mini's flat register is NOT an
//  exemplar-starvation problem; try shorter/abstract voice guidance in the CORE
//  instead. The turn-by-turn detail sits on the `instructions` default below.
//
//  Review: Kev + claude-opus-5, 2026-09-14, Confidence 0.9 — `carriesStandingPersona`
//  reads `miniCorePrompt`. The 09-12 trim made Mini's instructions a strict prefix
//  of `corePrompt`, the old `contains(corePrompt)` check went false, and the ReAct
//  floor re-sent the full persona in the body: every Mini agent turn overflowed
//  4096 (09-13 logs: 1409 + 3905 = 5314 tokens, four failed calls, RAG fallback).
//
//  Review: Kev + claude-opus-5, 2026-09-14, Confidence 0.8 — `prewarm(promptPrefix:)`.
//  The ReAct floor now opens every prompt with a stable head (ReActPrompt: tools,
//  rules, format), and the prewarm processes that head too, not only the
//  instructions: the launch warm computes it from the palette, the end-of-turn warm
//  takes the head the turn just sent. `afm turn` logs `warm=prefix-hit|held|…`;
//  a prefix-warm session serves only a prompt that begins with its prefix, so the
//  conversation titler no longer takes the session prewarmed for the next turn.
//  Plain-process probe (AC): turn-1 first token 6.7 s instructions-only → 2.1 s.
//  Off with `-afm.prefixPrewarm NO` (AFMPrefixPrewarm). The per-turn `afm budget`
//  token count moved to failures only: counting beside a turn spoiled its prewarm.
//
//  Note this provider builds a FRESH `LanguageModelSession(instructions:)` per
//  call, so anything in the persona is re-sent every turn — the reason persona
//  length is a real cost here and free on the KV-cached MLX tiers.

import Foundation
import M1K3LogCore
import os

// Weak-linked: FoundationModels is an OPTIONAL framework for M1K3 — every call
// here is already gated behind `SystemLanguageModel.default.availability`, and
// the `@Generable` macro below strong-references symbols (e.g. the macOS-26.0
// `Generable.promptRepresentation` getter) that an OLDER OS *seed* than our SDK
// may not export. Strong-linking aborts `dlopen` of any test bundle that links
// this module the instant dyld binds the missing symbol (the Xcode Cloud VM,
// whose runtime FoundationModels lags its Xcode-beta SDK). Weak-linking binds
// the absent symbol to NULL so the bundle/app loads; the guarded AFM path is the
// only thing that would ever touch it, and never on a runtime that lacks it.
@_weakLinked import FoundationModels

public struct AppleFoundationModelsProvider: InferenceProvider {
    public let name = "apple-foundation-models"

    /// Mini's first logger. `.notice` and `.error` only — `.info`/`.debug` do
    /// not persist in OSLogStore, and a breadcrumb that evaporates cannot
    /// diagnose a failure the user reports hours later.
    ///
    /// Sizes, error CLASSES, and a BOUNDED preview of error text — never prompt
    /// or answer content. The turn's text is the user's own conversation and the
    /// diagnostic partition this lands in is the one attached to issue reports,
    /// so the error description is capped rather than emitted whole: a guardrail
    /// throw that echoed the offending span would otherwise put that span into
    /// `.public` OSLogStore verbatim. `FoundationModels` is closed-source, so
    /// what its errors carry is an assumption we decline to make.
    private static let log = M1K3Log.logger(.afm)

    /// Cap on logged error text. Long enough to recognise a NEW error shape
    /// (the known overflow string is ~90 chars) and short enough that an
    /// unexpectedly chatty payload can't dump a conversation into the log.
    private static let errorPreviewCap = 200

    /// One breadcrumb per generation, before the call.
    ///
    /// Logs BODY, INSTRUCTIONS and TOTAL separately, and that split is the
    /// whole point. Mini's context is the SUM of both — the persona rides in
    /// `LanguageModelSession(instructions:)`, never in `prompt`. The first cut
    /// of this logged only the body, and was therefore blind to ~3.8k chars of
    /// the very context it exists to diagnose: an overflow instrument that
    /// cannot see the thing that overflows. Caught by reading its own first
    /// live output, which is the argument for running an instrument before
    /// trusting it.
    ///
    /// The split also keeps the persona-duplication class visible for good: if
    /// body and instructions ever both carry the persona again, `total` jumps
    /// by ~3.8k chars and the line says so on every turn.
    ///
    /// Window is 4096 tokens. Since macOS 26.4 we can log exact token counts
    /// via `SystemLanguageModel.tokenCount(for:)`.
    private func logTurnStart(promptChars: Int, streaming: Bool, warmth: AFMPrefixPrewarm.Warmth) {
        let instructionChars = instructions().count
        Self.log.notice(
            """
            afm turn: body=\(promptChars, privacy: .public) \
            instructions=\(instructionChars, privacy: .public) \
            total=\(promptChars + instructionChars, privacy: .public) chars, \
            streaming=\(streaming, privacy: .public), \
            prewarmed=\(warmth != .cold, privacy: .public) \
            warm=\(warmth.rawValue, privacy: .public)
            """
        )
    }

    /// The model's own first token, separate from the chat's `turn first chunk`
    /// (the ReAct floor streams only after its CONCLUSION: marker, so the chat
    /// line also counts the words before it). Read beside `warm=`, this is how
    /// much a prewarm actually bought.
    private static func logFirstToken(after elapsed: Duration, warmth: AFMPrefixPrewarm.Warmth) {
        let parts = elapsed.components
        let ms = Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
        log.notice("afm first token: \(ms, privacy: .public)ms warm=\(warmth.rawValue, privacy: .public)")
    }

    /// Exact token budget line — the [SPIKE] data the HistoryBudgetPolicy
    /// comments asked for. Logs instructions and prompt token counts via the
    /// macOS 26.4+ API.
    ///
    /// On a FAILED generation only (2026-09-14). It ran on every turn, fired
    /// beside the generation, and a `tokenCount` on the daemon mid-turn costs the
    /// turn its prewarm: plain-process probe, AC, n=3 — prefix-warm first token
    /// 2.0 s alone, 5.8 s with the two counts alongside (instructions-only 4.5 s).
    /// A failure is when the number matters (an overflow's `total=N/4096`); on
    /// success the `afm turn` char counts carry the size.
    private func logTokenBudget(instructionText: String, promptText: String) {
        if #available(macOS 26.4, iOS 26.4, visionOS 26.4, *) {
            Task.detached(priority: .utility) {
                do {
                    let model = SystemLanguageModel.default
                    let instrTokens = try await model.tokenCount(for: Instructions(instructionText))
                    let promptTokens = try await model.tokenCount(for: Prompt(promptText))
                    let total = instrTokens + promptTokens
                    Self.log.notice(
                        """
                        afm budget: instructions=\(instrTokens, privacy: .public) \
                        prompt=\(promptTokens, privacy: .public) \
                        total=\(total, privacy: .public)/\(model.contextSize, privacy: .public) tokens
                        """
                    )
                } catch {
                    // Token counting failed — not worth blocking the turn for.
                }
            }
        }
    }

    // MARK: - Prewarm

    /// A prewarmed session and the prompt prefix it processed (nil: the
    /// instructions only).
    private struct WarmSession {
        let session: LanguageModelSession
        let prefix: String?
    }

    /// Single-slot prewarmed session, keyed by the exact instructions text that
    /// built it (a persona that changed since prewarm must never be served
    /// stale — the slot drops mismatches by construction). A reference held by
    /// this struct, so provider copies share one slot.
    private let prewarmSlot = PrewarmSlot<WarmSession>()

    /// Build a session ahead of need and ask the framework to load assets +
    /// process the instructions now, so the NEXT turn doesn't pay cold-start.
    /// Mini opens a fresh `LanguageModelSession` per call (no KV prefix reuse,
    /// unlike the MLX tiers — the 2026-08-10 finding behind Mini's 37s live
    /// median), which makes this the one warm-up the tier can have.
    ///
    /// `promptPrefix`: how the next prompt will begin (the ReAct floor's stable
    /// head). The framework processes it too, so a turn that begins with it
    /// skips that prefill; a turn that doesn't still gets warm instructions.
    /// Ignored when `prewarmsPromptPrefix` is off.
    public func prewarm(promptPrefix: String? = nil) {
        let text = instructions()
        let prefix = prewarmsPromptPrefix ? promptPrefix.flatMap { $0.isEmpty ? nil : $0 } : nil
        let session = LanguageModelSession(instructions: text)
        if let prefix {
            session.prewarm(promptPrefix: Prompt(prefix))
        } else {
            session.prewarm()
        }
        prewarmSlot.store(WarmSession(session: session, prefix: prefix), key: text)
        Self.log.notice(
            """
            afm prewarm: armed (\(text.count, privacy: .public) instruction chars, \
            \(prefix?.count ?? 0, privacy: .public) prefix chars)
            """
        )
    }

    /// The session for this generation: the prewarmed one when its instructions
    /// still match and it may serve this prompt (`AFMPrefixPrewarm.accepts` —
    /// a prefix-warm session waits for the turn it was built for), else a fresh
    /// one. Optionally re-arms afterwards (see `prewarmsBetweenTurns`).
    private func takeSession(
        instructions text: String, prompt: String
    ) -> (session: LanguageModelSession, warmth: AFMPrefixPrewarm.Warmth) {
        if let warm = prewarmSlot.take(
            matching: text, accepting: { AFMPrefixPrewarm.accepts(prefix: $0.prefix, prompt: prompt) }
        ) {
            return (warm.session, .taken(prefix: warm.prefix))
        }
        return (LanguageModelSession(instructions: text), prewarmSlot.isArmed ? .held : .cold)
    }

    /// Re-arm for the next turn once this one has settled. Gated on the opt-in
    /// so batch users of this provider (the distiller, eval harnesses that
    /// didn't ask) never generate daemon work they don't want.
    ///
    /// Called via the `TurnWarmable` seam — once per AGENT TURN, never from
    /// inside `generate`/`generateStreaming`: Mini's ReAct floor makes several
    /// rapid provider calls per turn, and a per-call re-arm interleaves prewarm
    /// daemon round-trips between them (the logged rate-collapse shape,
    /// pkill-poisons-afm-daemon 2026-08-03).
    /// Detached AT THE SOURCE (review, PR #133): `session.prewarm()` is a
    /// closed-SDK call with no latency contract, and this fires on the tail of
    /// EVERY opted-in turn — inline it would delay turn completion (spinner,
    /// stream close) by whatever the daemon feels like. Detaching here fixes
    /// all forwarding paths at once instead of asking each caller to remember.
    private func rearmIfWanted(promptPrefix: String?) {
        guard prewarmsBetweenTurns else { return }
        Task.detached(priority: .utility) { self.prewarm(promptPrefix: promptPrefix) }
    }

    /// A failure, classified. The class is what makes this countable across a
    /// day of logs — "Mini overflowed 40 times" is actionable in a way that
    /// forty copies of an error sentence are not.
    /// NEVER call this for a `CancellationError` — the user cancelling is
    /// expected, and routing it here would classify it `.unknown` and log it at
    /// `.error`, poisoning the one signal `AFMFailure.unknown` exists to carry
    /// (a rising unknown count meaning "an error shape we don't recognise").
    /// All three call sites catch cancellation first.
    private func logFailure(_ error: any Error, streaming: Bool) {
        let described = String(describing: error)
        // Classify from the FULL text — the markers can sit anywhere — but emit
        // only a bounded, flattened preview (see `errorPreviewCap`).
        let failure = AFMFailure.classify(described)
        let preview = LogPreview.preview(described, max: Self.errorPreviewCap)
        Self.log.error(
            """
            afm failed: \(failure.rawValue, privacy: .public) \
            (streaming=\(streaming, privacy: .public)) — \
            \(preview, privacy: .public)
            """
        )
    }

    /// System instructions for every session this provider opens, evaluated
    /// fresh per call (the persona tracks profile edits). Defaults to the
    /// persona; secondary jobs (the memory distiller, future judges) pass
    /// neutral instructions so they don't speak as M1K3.
    private let instructions: @Sendable () -> String

    /// Opt-in for the Phase-15 AFM-native tool-calling path. Default OFF: the
    /// provider reports `supportsToolCalls == false`, so `LocalAgent` keeps the
    /// prompt-ReAct floor and launch routing is unchanged. Flipped on only by the
    /// eval harness (and, later, a Settings toggle) to exercise the spike.
    private let nativeToolCalling: Bool

    /// Opt-in: after each generation settles, arm a fresh prewarmed session so
    /// the NEXT turn skips cold-start. Default OFF — batch users (the
    /// distiller, availability probes) must not generate idle daemon work.
    private let prewarmsBetweenTurns: Bool

    /// Whether a prewarm also processes the prompt prefix it's handed. On by
    /// default; the app passes `AFMPrefixPrewarm.isEnabled(in:)`.
    private let prewarmsPromptPrefix: Bool

    public init(
        // Mini keeps the COMPACT core — no voiceExemplars. TRIED AND MEASURED
        // 2026-08-03, not assumed: the standing reason for withholding them was
        // cost, and cost turns out not to be the reason. They are ~187 tokens
        // against Mini's 4096-token window (4.5%), on top of a ~875-token
        // persona — affordable. See MiniPromptBudgetTests.
        //
        // They were switched ON and the same 8-probe MCP interview re-run. The
        // register did not improve; one new failure mode appeared. Asked "Long
        // day, I'm wrecked", Mini answered:
        //
        //     "Honey never spoils, and there are edible jars in 3,000-year-old
        //      Egyptian tombs."
        //
        // — exemplar 3, verbatim, as CONTENT. That is precisely the risk
        // `voiceExemplars`' own header documents ("a weak 4B reads a
        // turn-formatted exemplar as a pattern to CONTINUE and parrots the next
        // line verbatim"); the quoted-illustration framing mitigates it on the
        // 4B MLX tiers but not on this ~3B one. Abstention also got WORSE — the
        // seawater probe went from a false "102.5°C" to a false "100.5°C …
        // derived from the Clausius-Clapeyron equation", confidently sourced.
        //
        // So: reverted, and the real lesson is that Mini's flat register is not
        // an exemplar-starvation problem. Don't re-try this without new
        // evidence — try shorter/abstract voice guidance in the CORE instead.
        //
        // Golden Gate (2026-09-12): Mini uses the TRIMMED prompt — the standard
        // core WITHOUT the FOLLOW-UPS section. On a 4,096-token window, that
        // section costs ~315 tokens (7.7%) for tap-to-send chips the MLX tiers
        // (32K+) can afford and Mini cannot. Every token saved goes directly to
        // conversation replay depth (+41% measured).
        instructions: @escaping @Sendable () -> String = { M1K3Persona.miniSystemPrompt },
        nativeToolCalling: Bool = false,
        prewarmsBetweenTurns: Bool = false,
        prewarmsPromptPrefix: Bool = true
    ) {
        self.instructions = instructions
        self.nativeToolCalling = nativeToolCalling
        self.prewarmsBetweenTurns = prewarmsBetweenTurns
        self.prewarmsPromptPrefix = prewarmsPromptPrefix
    }

    public var isAvailable: Bool {
        switch SystemLanguageModel.default.availability {
        case .available:
            return true
        default:
            return false
        }
    }

    /// The product-facing availability (FirstRunBrainPolicy's input). Unlike the
    /// Bool above, this keeps the WHY: `.modelNotReady` is a transient asset sync
    /// (wait, don't download), `.appleIntelligenceNotEnabled` is user-fixable in
    /// System Settings, `.deviceNotEligible` is a hard block. Case names verified
    /// against the macOS 26 SDK swiftinterface (2026-07-03); unknown future
    /// reasons map to the hard block — a settings pointer could mislead there.
    public var availabilityState: AFMAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case let .unavailable(reason):
            switch reason {
            case .modelNotReady:
                return .notReady
            case .appleIntelligenceNotEnabled:
                return .blocked(userFixable: true)
            case .deviceNotEligible:
                return .blocked(userFixable: false)
            @unknown default:
                return .blocked(userFixable: false)
            }
        }
    }

    public func generate(prompt: String) async throws -> String {
        let instrText = instructions()
        let (session, warmth) = takeSession(instructions: instrText, prompt: prompt)
        logTurnStart(promptChars: prompt.count, streaming: false, warmth: warmth)
        do {
            let response = try await session.respond(to: prompt)
            return response.content
        } catch is CancellationError {
            // The user cancelled — expected, not a failure, and this is the
            // MOST COMMON throw on this path: `generate(prompt:)` is what the
            // ReAct floor calls for Mini, so every cancelled Mini turn lands
            // here. Classifying it would score `.unknown` and log `.error`,
            // making the unknown-count tripwire noise from day one.
            throw CancellationError()
        } catch {
            // This path DOES rethrow, so the caller isn't blind — but the log is
            // where the pattern shows up across a day, and the classification is
            // the whole point (overflow and guardrail need opposite fixes).
            logFailure(error, streaming: false)
            logTokenBudget(instructionText: instrText, promptText: prompt)
            throw error
        }
    }

    public func generateStreaming(prompt: String) -> AsyncStream<String> {
        AsyncStream { continuation in
            let instrText = instructions()
            let (session, warmth) = takeSession(instructions: instrText, prompt: prompt)
            logTurnStart(promptChars: prompt.count, streaming: true, warmth: warmth)
            let task = Task { [self] in
                do {
                    let clock = ContinuousClock()
                    let start = clock.now
                    var firstLogged = false
                    let stream = session.streamResponse(to: prompt)
                    for try await snapshot in stream {
                        if !firstLogged, !snapshot.content.isEmpty {
                            firstLogged = true
                            Self.logFirstToken(after: clock.now - start, warmth: warmth)
                        }
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    // The user cancelled — expected, not a failure. Logging it as
                    // one would bury the real errors in noise.
                    continuation.finish()
                } catch {
                    // THE SILENT ONE. `AsyncStream` cannot throw, so this error
                    // reached the caller as an ordinary empty stream — which the
                    // ReAct floor reads as "the model said nothing", re-prompts
                    // (growing the context that just overflowed), burns the
                    // iteration cap, and falls through to an ungrounded
                    // generation. That cascade is the #102 confabulation, and it
                    // began here, unlogged.
                    logFailure(error, streaming: true)
                    logTokenBudget(instructionText: instrText, promptText: prompt)
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Standing persona

// MARK: - Turn warming

/// The agent turn concluded — re-arm the prewarmed session for the next one,
/// on the head this turn began with (no-op unless `prewarmsBetweenTurns`
/// opted in).
extension AppleFoundationModelsProvider: TurnWarmable {
    public func prepareForNextTurn(promptPrefix: String?) {
        rearmIfWanted(promptPrefix: promptPrefix)
    }
}

extension AppleFoundationModelsProvider: PersonaCarrying {
    /// Every session this provider opens is constructed with `instructions()`,
    /// so when those instructions ARE the persona the ReAct floor must not
    /// prepend it a second time (it did, costing ~890 of Mini's 4096 tokens per
    /// generation — see PersonaCarrying's header).
    ///
    /// DERIVED, not declared: `instructions` is injectable precisely so
    /// secondary jobs — the memory distiller, future judges — can pass NEUTRAL
    /// instructions and not speak as M1K3. Those sessions really aren't
    /// carrying the persona, and a hardcoded `true` would strip identity from a
    /// ReAct run that needed it. Asking the live closure can't drift from what
    /// is actually sent; the cost is one substring check against a ~4KB string,
    /// set beside a multi-second inference call.
    ///
    /// The check reads `miniCorePrompt`, the part every standing persona shares
    /// (the core up to FOLLOW-UPS). Mini's own instructions are that trimmed
    /// core, and a `contains(corePrompt)` check can never match a strict prefix:
    /// from 2026-09-12 to this fix it read false, the ReAct floor re-sent the full
    /// persona in the body, and every Mini agent turn overflowed 4096.
    public var carriesStandingPersona: Bool {
        instructions().contains(M1K3Persona.miniCorePrompt)
    }
}

// MARK: - AFM-native tool calling (Phase 15 spike)

/// The structured decision AFM is FORCED to emit each agent turn. AFM speaks no
/// per-model tool dialect, so `respond(generating:)` does constrained decoding
/// against this schema — the model can only return well-formed `{isFinal,
/// toolName, toolInput, finalAnswer}`. The provider extracts the scalars and
/// hands them to the pure `AFMToolMapping`; OUR `LocalAgent` keeps the loop
/// (iteration cap, repeat-guard, unknown-tool steering), so AFM never auto-loops
/// to the context-overflow melt the Apple-driven `LanguageModelSession(tools:)`
/// path does.
@Generable
private struct AFMToolDecision {
    @Guide(description: "True ONLY if you can fully answer now without calling any tool.")
    var isFinal: Bool
    @Guide(description: "Exact name of the single tool to call. Leave empty when isFinal is true.")
    var toolName: String
    @Guide(description: "The input/query to pass to that tool. Leave empty when isFinal is true.")
    var toolInput: String
    @Guide(description: "Your complete final answer to the user. Fill only when isFinal is true.")
    var finalAnswer: String
}

/// Same-file extension so the conformance keeps reading the provider's `private`
/// `instructions` + `nativeToolCalling` without widening their visibility.
extension AppleFoundationModelsProvider: ToolCallingProvider {
    /// Runtime capability: only when the spike is opted IN *and* the on-device
    /// model is actually available. Default-OFF flag ⇒ ReAct floor ⇒ launch
    /// routing unchanged.
    public var supportsToolCalls: Bool {
        nativeToolCalling && isAvailable
    }

    /// Spike-scoped costs to retire before any production wiring (review
    /// 2026-06-15): (1) a FRESH `LanguageModelSession` per call + the default
    /// `StatelessToolTurnSession` re-sending the whole transcript ⇒ no KV reuse,
    /// iteration ≥2 re-prefills the persona (a chunk of the ~20–30s/call). A real
    /// `ToolTurnSession` holding one AFM session across the turn would cut it. (2)
    /// the cap-reached `synthesizeNativeConclusion` turn is a plain `.user`, but
    /// this path still forces the `AFMToolDecision` schema — the `isFinal=true`
    /// branch absorbs it (toolName/toolInput wasted), a non-obvious coupling.
    /// Both are acceptable for a spike whose verdict is "don't route agentic to
    /// AFM" regardless; named so they aren't inherited silently.
    public func continueToolTurn(messages: [ToolMessage], tools: [ToolDefinition]) async throws -> ToolTurn {
        let body = AFMToolPrompt.render(messages: messages, tools: tools)
        let standing = AFMToolPrompt.systemInstructions(from: messages) ?? instructions()
        let session = LanguageModelSession(instructions: standing)
        do {
            let decision = try await session.respond(to: body, generating: AFMToolDecision.self).content
            return AFMToolMapping.toolTurn(
                isFinal: decision.isFinal,
                toolName: decision.toolName,
                toolInput: decision.toolInput,
                finalAnswer: decision.finalAnswer
            )
        } catch is CancellationError {
            // A cancelled turn MUST propagate — the native loop's
            // `catch is CancellationError { throw }` (LocalAgent+Native) depends on
            // it reaching up. Swallowing it here would silently conclude with an
            // empty answer instead of honouring Cancel (the `try? Task.sleep`
            // family of bug). Re-throw before the catch-all backstop.
            throw CancellationError()
        } catch {
            // Non-melt backstop: a guardrail / decode / context-overflow throw
            // becomes a fast, empty text conclusion — LocalAgent ends the turn
            // immediately rather than thrashing. The latency band proves the
            // difference from the 337s Apple-driven auto-loop.
            //
            // Logged because an empty conclusion is indistinguishable from a
            // model that chose to say nothing, and this backstop deliberately
            // manufactures exactly that shape.
            logFailure(error, streaming: false)
            return .text("")
        }
    }
}

// MARK: - Raw (persona-free) completion — Brain at Home /v1/generate

/// A fresh, instruction-FREE session per call: no persona, no prewarm slot,
/// no tools — the Brain at Home raw contract (2026-08-19 audit, finding 1).
/// AFM's own snapshots are CUMULATIVE partials; this seam converts them to
/// deltas so the wire contract matches the MLX tiers' token stream.
extension AppleFoundationModelsProvider: RawCompletionProviding {
    /// The raw route's response cap — the seam's "shorten, never lengthen"
    /// contract needs an explicit ceiling because AFM has no caller-visible
    /// default the way MLX's `defaultMaxTokens` is. Half the 4096-token
    /// window: a remote completion may fill at most the half the prompt
    /// doesn't, so one request can't monopolize the single-flight slot for
    /// the longest generation AFM could physically produce (PR #139 review).
    public static let rawResponseTokenCap = 2048

    /// Pure clamp, pinned by tests (the forwarding tests only prove the
    /// value ARRIVES; this proves the ceiling holds): nil = the cap itself.
    public static func clampedRawResponseTokens(_ requested: Int?) -> Int {
        guard let requested else { return rawResponseTokenCap }
        return min(max(1, requested), rawResponseTokenCap)
    }

    public func generateRawStreaming(prompt: String, maxTokens: Int?) -> AsyncStream<String>? {
        AsyncStream { continuation in
            let session = LanguageModelSession()
            let options = GenerationOptions(
                maximumResponseTokens: Self.clampedRawResponseTokens(maxTokens)
            )
            let task = Task { [self] in
                do {
                    var previous = ""
                    for try await snapshot in session.streamResponse(to: prompt, options: options) {
                        let content = snapshot.content
                        if content.hasPrefix(previous) {
                            let delta = String(content.dropFirst(previous.count))
                            if !delta.isEmpty { continuation.yield(delta) }
                        } else if content.count > previous.count {
                            // Diverged mid-stream (a revision). A token wire
                            // can't retract what's sent, so NEVER re-emit the
                            // whole content (the client would assemble
                            // duplicated text — PR #139 review); emit only the
                            // length-based tail and accept the revision loss.
                            continuation.yield(String(content.dropFirst(previous.count)))
                        }
                        // Shrank: nothing safe to emit — just track it.
                        previous = content
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    logFailure(error, streaming: true)
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Token counting (macOS 26.4+ — the [SPIKE] resolved)

@available(macOS 26.4, iOS 26.4, visionOS 26.4, *)
extension AppleFoundationModelsProvider: TokenCountable {
    public func tokenCount(forInstructions text: String) async throws -> Int {
        try await SystemLanguageModel.default.tokenCount(for: Instructions(text))
    }

    public func tokenCount(forPrompt text: String) async throws -> Int {
        try await SystemLanguageModel.default.tokenCount(for: Prompt(text))
    }
}
