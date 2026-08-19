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
    /// Window is 4096 tokens ≈ 18k chars at the measured ~4.4 chars/token.
    private func logTurnStart(promptChars: Int, streaming: Bool, prewarmed: Bool) {
        let instructionChars = instructions().count
        Self.log.notice(
            """
            afm turn: body=\(promptChars, privacy: .public) \
            instructions=\(instructionChars, privacy: .public) \
            total=\(promptChars + instructionChars, privacy: .public) chars, \
            streaming=\(streaming, privacy: .public), \
            prewarmed=\(prewarmed, privacy: .public)
            """
        )
    }

    // MARK: - Prewarm

    /// Single-slot prewarmed session, keyed by the exact instructions text that
    /// built it (a persona that changed since prewarm must never be served
    /// stale — the slot drops mismatches by construction). A reference held by
    /// this struct, so provider copies share one slot.
    private let prewarmSlot = PrewarmSlot<LanguageModelSession>()

    /// Build a session ahead of need and ask the framework to load assets +
    /// process the instructions now, so the NEXT turn doesn't pay cold-start.
    /// Mini opens a fresh `LanguageModelSession` per call (no KV prefix reuse,
    /// unlike the MLX tiers — the 2026-08-10 finding behind Mini's 37s live
    /// median), which makes this the one warm-up the tier can have.
    public func prewarm() {
        let text = instructions()
        let session = LanguageModelSession(instructions: text)
        session.prewarm()
        prewarmSlot.store(session, key: text)
        Self.log.notice("afm prewarm: armed (\(text.count, privacy: .public) instruction chars)")
    }

    /// The session for this generation: the prewarmed one when its instructions
    /// still match, else a cold one. Optionally re-arms afterwards (see
    /// `prewarmsBetweenTurns`).
    private func takeSession(instructions text: String) -> (session: LanguageModelSession, prewarmed: Bool) {
        if let warm = prewarmSlot.take(matching: text) {
            return (warm, true)
        }
        return (LanguageModelSession(instructions: text), false)
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
    private func rearmIfWanted() {
        guard prewarmsBetweenTurns else { return }
        Task.detached(priority: .utility) { self.prewarm() }
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
        instructions: @escaping @Sendable () -> String = { M1K3Persona.systemPrompt },
        nativeToolCalling: Bool = false,
        prewarmsBetweenTurns: Bool = false
    ) {
        self.instructions = instructions
        self.nativeToolCalling = nativeToolCalling
        self.prewarmsBetweenTurns = prewarmsBetweenTurns
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
        let (session, prewarmed) = takeSession(instructions: instructions())
        logTurnStart(promptChars: prompt.count, streaming: false, prewarmed: prewarmed)
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
            throw error
        }
    }

    public func generateStreaming(prompt: String) -> AsyncStream<String> {
        AsyncStream { continuation in
            let (session, prewarmed) = takeSession(instructions: instructions())
            logTurnStart(promptChars: prompt.count, streaming: true, prewarmed: prewarmed)
            let task = Task { [self] in
                do {
                    let stream = session.streamResponse(to: prompt)
                    for try await snapshot in stream {
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
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Standing persona

// MARK: - Turn warming

/// The agent turn concluded — re-arm the prewarmed session for the next one
/// (no-op unless `prewarmsBetweenTurns` opted in).
extension AppleFoundationModelsProvider: TurnWarmable {
    public func prepareForNextTurn() {
        rearmIfWanted()
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
    public var carriesStandingPersona: Bool {
        instructions().contains(M1K3Persona.corePrompt)
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
