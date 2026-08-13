//
//  LocalAgent+Native.swift
//  M1K3Agent
//
//  The NATIVE tool-calling loop (Phase 12a) — the path taken when the active
//  provider conforms to `ToolCallingProvider` and its model can emit parseable
//  calls. The model speaks structured `ToolTurn`s; everything dialect-
//  independent — dispatch, repeat-guard, unknown-tool steering, the iteration
//  cap, the reasoning trace, activity events — is SHARED with the ReAct floor
//  (in LocalAgent.swift), so no model is ever locked out and the two paths can't
//  drift apart.
//
//  The agent owns the conversation as a typed `[ToolMessage]` transcript (NOT a
//  concatenated prompt string): native models render tool RESULTS into role-
//  tagged turns they were trained on, so threading results as prose would be
//  off-distribution. This array maps straight onto mlx-swift-lm's
//  `UserInput(chat:)` in the MLX adapter (Phase 12c) — no seam churn.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-10, Confidence 0.85, Prior: Unknown
//  Context: pressure-tested by the challenger — typed transcript + typed args +
//  runtime capability flag adopted over a stateless prompt-string seam.

import Foundation
import M1K3Inference
import Synchronization

extension LocalAgent {
    /// Structured loop for a tool-calling provider. One `ToolTurnSession` per
    /// turn: the session retains the conversation (for MLX, a live KV cache —
    /// iteration ≥2 prefills only the new tool results, not the whole
    /// transcript), so the agent sends only the DELTA messages each iteration.
    /// The think phase of every generation streams live through
    /// `onReasoningToken` (it renders in the reasoning disclosure); post-think
    /// text is gated until the turn's outcome is known.
    func runNative(
        provider: any ToolCallingProvider,
        goal: String,
        images: [ImageAttachment] = [],
        grounding: String?,
        thinkingEnabled: Bool = true,
        onEvent: (@Sendable (AgentLoopEvent) -> Void)?,
        onConclusionToken: (@Sendable (String) -> Void)?,
        onReasoningToken: (@Sendable (String) -> Void)?
    ) async throws -> AgentResult {
        // Sort by name: `tools` is a Dictionary and `.values` iterates in a
        // nondeterministic order, so an unsorted list renders the tools block
        // in a different order each turn — diverging from the persona-prefix
        // seed (built once) right where the tools JSON begins, and silently
        // collapsing cross-turn reuse. Sorting matches the persona-cache key,
        // which already sorts tool names. (Tools resolve by name; order is
        // behaviourally irrelevant.)
        let toolDefinitions = tools.values.map(\.toolDefinition).sorted { $0.name < $1.name }
        let session = try await provider.makeToolTurnSession(
            tools: toolDefinitions,
            options: ToolTurnOptions(thinkingEnabled: thinkingEnabled)
        )
        do {
            let result = try await runNativeLoop(
                session: session,
                goal: goal,
                images: images,
                grounding: grounding,
                onEvent: onEvent,
                onConclusionToken: onConclusionToken,
                onReasoningToken: onReasoningToken
            )
            await session.finish()
            return result
        } catch {
            await session.finish()
            throw error
        }
    }

    private func runNativeLoop(
        session: any ToolTurnSession,
        goal: String,
        images: [ImageAttachment] = [],
        grounding: String?,
        onEvent: (@Sendable (AgentLoopEvent) -> Void)?,
        onConclusionToken: (@Sendable (String) -> Void)?,
        onReasoningToken: (@Sendable (String) -> Void)?
    ) async throws -> AgentResult {
        var usedTools = Set<String>()
        var executedActions = Set<String>()
        // The trace/rescue record — the SESSION owns the model-side state, so
        // this array is never re-sent; only the per-iteration delta is.
        var transcript: [ToolMessage] = []
        // Persona first (the chat template's system turn), then the goal —
        // identity is standing, the goal is this turn's. Exemplars included so
        // this system text matches the persona-prefix seed token-for-token —
        // that exact match is what lets the cache reuse the persona block at
        // iteration 0 (MLXToolTurnSession's cross-turn reuse).
        var pendingMessages: [ToolMessage] = [
            .system(M1K3Persona.systemPrompt(includeExemplars: true)),
            .user(Self.buildNativeGoal(goal: goal, grounding: grounding), images: images),
        ]

        logRunStart(goal: goal, grounding: grounding)

        for iteration in 0 ..< maxIterations {
            try Task.checkCancellation()
            onEvent?(.thinking(iteration: iteration))
            transcript.append(contentsOf: pendingMessages)
            let turn: ToolTurn
            let remainder: String
            do {
                (turn, remainder) = try await sendThroughGate(
                    session: session,
                    messages: pendingMessages,
                    onReasoningToken: onReasoningToken,
                    onConclusionToken: onConclusionToken
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Evidence always: a generation/render failure mid-loop must
                // never discard observations already gathered. (Live case:
                // Qwen3.5's chat template rejects a tool-result-only delta —
                // "No user query found in messages" — AFTER a web_search
                // succeeded.) Conclude EMPTY with the trace intact so the
                // responder synthesises over the gathered facts; only a failure
                // with nothing gathered escapes to plain RAG.
                guard reasoningTrace.contains(where: { !($0.observation ?? "").isEmpty }) else { throw error }
                logEvidenceRescue(error: error, steps: reasoningTrace.count)
                return concluded("", usedTools, iteration + 1)
            }
            pendingMessages = []

            switch turn {
            case let .text(answer):
                reasoningTrace.append(ReasoningStep(iteration: iteration, thought: answer))
                // A pure-think turn (nothing after the reasoning) concludes
                // empty, so the caller's fallback synthesis still produces a
                // real answer instead of re-showing the chain-of-thought.
                // Answer tokens already streamed live via onConclusionToken.
                return concluded(remainder.isEmpty ? "" : answer, usedTools, iteration + 1)

            case let .toolCalls(calls) where calls.isEmpty:
                // Neither text nor calls: steer instead of regenerating over an
                // unchanged conversation (an empty delta has nothing to render).
                pendingMessages = [.user("Reply with your final answer, or call one of the tools.")]
                transcript.append(.assistant(text: nil, toolCalls: []))
                // Every iteration leaves a trace step — a silent gap at this
                // index would make a stalled turn look like a skipped one.
                reasoningTrace.append(ReasoningStep(iteration: iteration, thought: "(empty turn)"))

            case let .toolCalls(calls):
                transcript.append(.assistant(text: nil, toolCalls: calls))
                for parsedCall in calls {
                    let observation = await observeNative(
                        parsedCall: parsedCall,
                        iteration: iteration,
                        executedActions: &executedActions,
                        usedTools: &usedTools,
                        onEvent: onEvent
                    )
                    reasoningTrace.append(ReasoningStep(
                        iteration: iteration,
                        thought: "",
                        action: Self.nativeDescription(parsedCall),
                        observation: observation
                    ))
                    transcript.append(.toolResult(name: parsedCall.name, output: observation))
                    pendingMessages.append(.toolResult(name: parsedCall.name, output: observation))
                }
            }
        }

        // Iteration cap reached — ask for a plain answer over what was gathered.
        logCapReached()
        let finalAnswer = try await synthesizeNativeConclusion(
            session: session,
            transcript: transcript,
            onConclusionToken: onConclusionToken,
            onReasoningToken: onReasoningToken
        )
        return concluded(finalAnswer, usedTools, maxIterations)
    }

    /// One session send with the think-gate applied: think-phase tokens stream
    /// live to `onReasoningToken`; post-think tokens stream live to
    /// `onConclusionToken` while also being buffered. The remainder is returned
    /// for the caller's `concluded()` call but NOT re-emitted (tokens already
    /// streamed live).
    private func sendThroughGate(
        session: any ToolTurnSession,
        messages: [ToolMessage],
        onReasoningToken: (@Sendable (String) -> Void)?,
        onConclusionToken: (@Sendable (String) -> Void)?
    ) async throws -> (turn: ToolTurn, remainder: String) {
        let gate = Mutex(ThinkStreamGate())
        let turn = try await session.send(messages) { token in
            // Collect answer chunks under the lock, but fire onConclusionToken
            // OUTSIDE it. The gate's Mutex is os_unfair_lock-backed (non-reentrant),
            // and onConclusionToken is an external @Sendable sink — re-entering the
            // gate from it would spin. Today's callers yield to an AsyncStream and
            // are safe; this keeps a future caller from silently dead-locking.
            // Order is preserved (answer chunk, then live reasoning) to match the
            // prior in-feed call.
            var answer = ""
            let live = gate.withLock { $0.feed(token, onAnswerToken: { answer += $0 }) }
            if !answer.isEmpty { onConclusionToken?(answer) }
            if !live.isEmpty { onReasoningToken?(live) }
        }
        let remainder = gate.withLock { $0.flushRemainder() }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (turn, remainder)
    }

    /// Execute one structured tool call through the shared dispatch core,
    /// flattening the typed arguments to the tool's `[String: String]` contract.
    private func observeNative(
        parsedCall: ParsedToolCall,
        iteration: Int,
        executedActions: inout Set<String>,
        usedTools: inout Set<String>,
        onEvent: (@Sendable (AgentLoopEvent) -> Void)?
    ) async -> String {
        let start = ContinuousClock.now
        let display = Self.nativeDescription(parsedCall)
        let observation = await dispatchCall(
            ToolCallSite(
                toolName: parsedCall.name,
                displayDescription: display,
                // Dictionary.values.first is order-nondeterministic; sort so a
                // multi-arg call always surfaces the same argument in the UI.
                eventArgument: parsedCall.stringArguments
                    .sorted { $0.key < $1.key }
                    .first?.value ?? ""
            ),
            executedActions: &executedActions,
            usedTools: &usedTools,
            onEvent: onEvent
        ) { tool in
            try await tool.execute(input: parsedCall.stringArguments).output
        }
        logObservation(observation, callDescription: display, iteration: iteration, start: start)
        return observation
    }

    /// Final answer when the loop hits its cap: instruct the model to answer in
    /// prose over the same session (the tools stay rendered in its context —
    /// the instruction, not withdrawal, does the steering now); if it calls
    /// anyway or only thinks, fall back to the gathered observations so
    /// evidence is never discarded.
    private func synthesizeNativeConclusion(
        session: any ToolTurnSession,
        transcript: [ToolMessage],
        onConclusionToken: (@Sendable (String) -> Void)?,
        onReasoningToken: (@Sendable (String) -> Void)?
    ) async throws -> String {
        let instruction = ToolMessage.user(
            "You have reached the maximum number of steps. Based on the information "
                + "gathered, answer the user directly in plain language. Do not call any more tools."
        )
        let (turn, remainder) = try await sendThroughGate(
            session: session,
            messages: [instruction],
            onReasoningToken: onReasoningToken,
            onConclusionToken: onConclusionToken
        )
        switch turn {
        case let .text(answer) where !remainder.isEmpty:
            // Answer tokens already streamed live via onConclusionToken in the gate.
            // AgentResult.conclusion carries the RAW text (see its doc) for the
            // trace/eval consumers.
            return answer
        case .text, .toolCalls:
            // .text with an EMPTY remainder lands here on purpose: the model
            // only reasoned (or called a tool against the instruction) — the
            // gathered evidence is the best available answer in both cases.
            return Self.gatheredObservations(from: transcript)
        }
    }

    /// A stable, human-readable rendering of a structured call for the trace and
    /// the repeat-guard key: `name(k=v, k=v)` with keys sorted for determinism.
    static func nativeDescription(_ call: ParsedToolCall) -> String {
        let arguments = call.stringArguments
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
        return "\(call.name)(\(arguments))"
    }

    /// The opening user turn: optional grounding then the goal, with NO ReAct
    /// scaffolding — tools are supplied structurally, identity lives in the
    /// system turn (M1K3Persona), so this carries only the turn's task.
    ///
    /// Goal LAST, deliberately (2026-08-13, NativeGoalOrderTests):
    /// the context block opens with the day-granular context line and the
    /// append-extending history replay, while the goal changes every turn.
    /// Goal-first put the divergence ~30 tokens in and capped cross-turn KV
    /// reuse at the persona prefix (measured: 1786 tokens reused, always);
    /// goal-last lets the conversation-tail seed reuse everything up to this
    /// turn's grounding. Recency helps too — small models weight the end of
    /// the prompt, and the task should sit closest to the generation.
    static func buildNativeGoal(goal: String, grounding: String?) -> String {
        let groundingBlock = grounding.map { "Context:\n\($0)\n\n" } ?? ""
        return """
        Use the available tools when they help answer the user's request. When \
        you have enough information, reply with your final answer in plain language.

        \(groundingBlock)Goal: \(goal)
        """
    }

    /// Join the tool observations gathered so far — the evidence-rescue fallback
    /// for a cap synthesis where the model refused to stop calling tools.
    static func gatheredObservations(from transcript: [ToolMessage]) -> String {
        let facts = transcript.compactMap { message -> String? in
            if case let .toolResult(_, output) = message { return output }
            return nil
        }
        return facts.isEmpty
            ? "I gathered some information but couldn't form a final answer."
            : facts.joined(separator: "\n")
    }
}
