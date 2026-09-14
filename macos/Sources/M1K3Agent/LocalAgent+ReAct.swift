//
//  LocalAgent+ReAct.swift
//  M1K3Agent
//
//  The prompt-ReAct loop — the UNIVERSAL FLOOR that works on any model, even
//  ones with no native tool-calling dialect. Split out of LocalAgent.swift so
//  the actor shell stays small; the native loop lives in LocalAgent+Native.swift.
//  Both paths share the dispatch core, repeat-guard, iteration cap, reasoning
//  trace, and activity events (in LocalAgent.swift) — only the way a "next step"
//  is obtained differs (text-scraping here, structured ToolTurns there).
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.9,
//  Prior: internal call-pipeline project, domain ReAct agent (Kev)
//
//  Review: Kev + claude-opus-4-8, 2026-06-10, Confidence 0.85 — extracted
//  verbatim from LocalAgent.run() when the native tool-calling path landed
//  (Phase 12a). Behaviour unchanged; the loop is now one of two strategies the
//  run() dispatcher selects between.
//
//  Review: Kev + claude-opus-5, 2026-09-14, Confidence 0.8 — the initial context is
//  stable-first (ReActPrompt): tools, the caller's standing rules, the format,
//  THEN the turn's context and the goal. The head it sends is kept for the
//  end-of-turn warm, so AFM can prewarm the next turn's prefix, not only its
//  instructions. Quality gated by the live-path Mini eval, not assumed.
//
//  Review: Kev + claude-opus-5, 2026-09-14, Confidence 0.85 — a conclusion that ENDS in
//  a call to an offered tool runs the tool (`conclusionStep`). Mini opens every reply
//  with "CONCLUSION:" and, in 8 of 10 live tool turns, ended it with the ACTION it
//  decided it needed; the loop concluded and stripped the call, so tool-use was 0/30
//  on the live path. Whatever streamed before the call is now followed, a paragraph
//  apart, by the real answer — however the loop reaches it (ReActTrailingActionTests).
//  `observationCharLimit` caps what one observation carries into the next prompt.

import Foundation
import M1K3Inference
import M1K3LogCore
import os

extension LocalAgent {
    /// Iterative Thought → Action → Observation loop driven by free-text model
    /// output. Terminates on a `CONCLUSION:` thought or, at the iteration cap,
    /// by synthesising from the accumulated context.
    func runReAct(
        goal: String,
        grounding: String?,
        standing: String? = nil,
        onEvent: (@Sendable (AgentLoopEvent) -> Void)?,
        onConclusionToken: (@Sendable (String) -> Void)?
    ) async throws -> AgentResult {
        var usedTools = Set<String>()
        var executedActions = Set<String>()
        streamedLive = false
        let prefix = promptPrefix(standing: standing)
        warmPrefix = prefix
        var currentContext = prefix + ReActPrompt.tail(goal: goal, context: grounding)

        logRunStart(goal: goal, grounding: grounding)

        for iteration in 0 ..< maxIterations {
            try Task.checkCancellation()
            onEvent?(.thinking(iteration: iteration))
            let thought = try await generateThought(
                context: currentContext,
                iteration: iteration,
                onConclusionToken: onConclusionToken
            )

            let step = conclusionStep(
                from: thought, iteration: iteration, usedTools: usedTools, executedActions: executedActions
            )
            if case let .conclude(result) = step {
                return result
            }
            let chosen: Action? = if case let .act(action) = step { action } else { parseAction(from: thought) }

            guard let action = chosen else {
                reasoningTrace.append(ReasoningStep(iteration: iteration, thought: thought))
                // Small models often just answer in prose instead of emitting the
                // CONCLUSION marker. After they've had one structured chance,
                // treat substantive unstructured prose as the answer rather than
                // burning the remaining iterations re-prompting.
                if concludesOnUnstructuredThought, iteration >= 1, !thought.isEmpty {
                    M1K3Log.agentLoop.info("iteration \(iteration): implicit conclusion (prose, no markers)")
                    let result = concluded(thought, usedTools, iteration + 1)
                    carryToStream(result.conclusion, onConclusionToken: onConclusionToken)
                    return result
                }
                // No action — keep reasoning, with a format reminder (models
                // announce tools in prose without the marker; seen on Gemma).
                currentContext += Self.proseContinuation(for: thought)
                continue
            }

            let observation = await observe(
                action: action,
                iteration: iteration,
                executedActions: &executedActions,
                usedTools: &usedTools,
                onEvent: onEvent
            )

            reasoningTrace.append(ReasoningStep(
                iteration: iteration,
                thought: thought,
                action: action.description,
                observation: observation
            ))

            currentContext += """


            Thought: \(thought)
            Action: \(action.description)
            Observation: \(promptObservation(observation))
            """
        }

        // Iteration cap reached — synthesise from the accumulated context.
        logCapReached()
        let finalConclusion = try await synthesizeConclusion(context: currentContext)
        let result = concluded(finalConclusion, usedTools, maxIterations)
        carryToStream(result.conclusion, onConclusionToken: onConclusionToken)
        return result
    }

    /// A conclusion reached WITHOUT streaming (implicit prose, the cap's
    /// synthesis) after an earlier iteration already streamed live text — a
    /// preamble before a tool call. The caller treats "something streamed" as
    /// "the answer streamed" and adds nothing after the loop, so the answer must
    /// ride the stream here, a paragraph after what came before. With nothing
    /// streamed yet this does nothing: the caller shows the conclusion itself, as
    /// it always has.
    private func carryToStream(_ conclusion: String, onConclusionToken: (@Sendable (String) -> Void)?) {
        guard streamedLive, let onConclusionToken, !conclusion.isEmpty else { return }
        onConclusionToken("\n\n" + conclusion)
    }

    /// What a thought asks the loop to do: conclude, run a tool, or neither
    /// (no CONCLUSION marker — the ordinary action / prose path decides).
    enum ConclusionStep {
        case conclude(AgentResult)
        case act(Action)
        case none
    }

    /// Conclude from a CONCLUSION-marker thought — unless it is really a call:
    /// - an action in a trench coat ("CONCLUSION: ACTION: …", seen live) —
    ///   nothing survives the scaffolding strip but the thought parses as one;
    /// - a conclusion that ENDS by calling an offered tool it hasn't already
    ///   called — Mini's shape ("…so I'll use lookup_fact to confirm.\nACTION:
    ///   lookup_fact(Cork)"), 8 of 10 live tool turns on 2026-09-14. The call is
    ///   the intent; the prose before it is its thought. A call to a tool that
    ///   wasn't offered, or one it already made, concludes on the prose as before.
    private func conclusionStep(
        from thought: String, iteration: Int, usedTools: Set<String>, executedActions: Set<String>
    ) -> ConclusionStep {
        guard thought.contains("CONCLUSION:") else { return .none }
        let conclusion = extractConclusion(from: thought)
        if Self.stripScaffolding(conclusion).isEmpty, let action = parseAction(from: thought) {
            M1K3Log.agentLoop.notice(
                "iteration \(iteration): conclusion was only scaffolding — treating as action"
            )
            return .act(action)
        }
        if let action = trailingAction(in: conclusion), tools[action.toolName] != nil,
           !executedActions.contains(action.description)
        {
            M1K3Log.agentLoop.notice(
                "iteration \(iteration): conclusion ends by calling \(action.toolName, privacy: .public) — running it"
            )
            return .act(action)
        }
        reasoningTrace.append(ReasoningStep(iteration: iteration, thought: thought))
        return .conclude(concluded(conclusion, usedTools, iteration + 1))
    }

    /// The part of an observation the next prompt carries: all of it, or the
    /// first `observationCharLimit` characters and an ellipsis. On Mini a real
    /// web page (2,879 chars) took the next iteration to 4,209 of 4,096 tokens —
    /// three failed calls, then a fallback that never saw the page (installed
    /// app, 2026-09-14). The reasoning trace, which the fallback reads, keeps it whole.
    func promptObservation(_ observation: String) -> String {
        guard let limit = observationCharLimit, observation.count > limit else { return observation }
        return String(observation.prefix(limit)) + "…"
    }

    /// The call a text ENDS with: its last non-empty line, when that line is an
    /// ACTION. An ACTION mentioned mid-sentence is prose, not a call.
    func trailingAction(in text: String) -> Action? {
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: Self.decoration) }
        guard let last = lines.last(where: { !$0.isEmpty }), last.hasPrefix("ACTION:") else { return nil }
        return parseAction(from: last)
    }

    // MARK: - Prompt construction

    /// Everything the prompt holds before the turn: the persona when the
    /// backend doesn't carry it, then the stable head (ReActPrompt). Every
    /// iteration's prompt begins with it, and it is what the end-of-turn warm
    /// hands a backend that can prewarm a prefix.
    private func promptPrefix(standing: String?) -> String {
        // Only send the persona when the backend isn't already carrying it.
        // A bare completion model has nowhere else to learn who it is; AFM
        // opens every session with the same persona as standing instructions,
        // so including it here sent Mini ~890 tokens of duplicate identity per
        // generation — ~43% of its 4096-token window, before the question.
        // Not conforming to PersonaCarrying keeps the old behaviour exactly.
        let carriesPersona = (inferenceProvider as? PersonaCarrying)?.carriesStandingPersona == true
        let personaBlock = carriesPersona ? "" : "\(M1K3Persona.systemPrompt)\n\n"
        return personaBlock + ReActPrompt.head(tools: Array(tools.values), standing: standing)
    }

    /// Generate one thought. With `onConclusionToken` set, the thought streams
    /// through a ConclusionStreamSplitter so a conclusion's tail reaches the
    /// caller live; non-conclusion thoughts buffer silently.
    private func generateThought(
        context: String,
        iteration: Int,
        onConclusionToken: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let start = ContinuousClock.now
        let thought = try await rawThought(
            context: context, iteration: iteration, onConclusionToken: onConclusionToken
        )
        logThought(thought, iteration: iteration, start: start)
        return thought
    }

    private func rawThought(
        context: String,
        iteration: Int,
        onConclusionToken: (@Sendable (String) -> Void)?
    ) async throws -> String {
        let prompt = context + "\n\nThought \(iteration + 1):"
        guard let onConclusionToken else {
            let response = try await inferenceProvider.generate(prompt: prompt)
            return response.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var splitter = ConclusionStreamSplitter()
        // A later iteration's first live text follows what an earlier one
        // streamed (a preamble before a tool call) a paragraph apart.
        var needsBreak = streamedLive
        func emit(_ text: String) {
            guard !text.isEmpty else { return }
            if needsBreak {
                onConclusionToken("\n\n")
                needsBreak = false
            }
            onConclusionToken(text)
            streamedLive = true
        }
        for await chunk in inferenceProvider.generateStreaming(prompt: prompt) {
            emit(splitter.feed(chunk))
        }
        // Release the splitter's guard window now the stream is over.
        emit(splitter.flush())
        return splitter.thought.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func synthesizeConclusion(context: String) async throws -> String {
        let prompt = context + "\n\n\nYou have reached the maximum iterations. "
            + "Based on the information gathered, answer the user directly in "
            + "plain language. Do not write ACTION: and do not call tools:"
        return try await inferenceProvider.generate(prompt: prompt)
    }

    // MARK: - Action parsing

    struct Action: Equatable {
        let toolName: String
        let argument: String
        var description: String {
            "\(toolName)(\(argument))"
        }
    }

    func parseAction(from thought: String) -> Action? {
        guard let actionRange = thought.range(of: "ACTION:\\s*", options: .regularExpression) else {
            return nil
        }
        let actionString = String(thought[actionRange.upperBound...])
        guard let openParen = actionString.firstIndex(of: "("),
              let closeParen = actionString.lastIndex(of: ")")
        else { return nil }

        let toolName = String(actionString[..<openParen])
            .trimmingCharacters(in: Self.decoration)
        let argument = String(actionString[actionString.index(after: openParen) ..< closeParen])
            .trimmingCharacters(in: Self.decoration)
        guard !toolName.isEmpty else { return nil }
        return Action(toolName: toolName, argument: argument)
    }

    func extractConclusion(from thought: String) -> String {
        guard let range = thought.range(of: "CONCLUSION:\\s*", options: .regularExpression) else {
            return thought
        }
        return String(thought[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Action dispatch

    /// Resolve one parsed action to its observation: repeat-guard first, then
    /// dispatch, with unknown tools steered back toward the real tool list.
    private func observe(
        action: Action,
        iteration: Int,
        executedActions: inout Set<String>,
        usedTools: inout Set<String>,
        onEvent: (@Sendable (AgentLoopEvent) -> Void)?
    ) async -> String {
        let start = ContinuousClock.now
        let observation = await dispatchCall(
            ToolCallSite(
                toolName: action.toolName,
                displayDescription: action.description,
                eventArgument: action.argument
            ),
            executedActions: &executedActions,
            usedTools: &usedTools,
            onEvent: onEvent
        ) { tool in
            // ReAct supplies one positional argument → the first declared parameter.
            let paramName = tool.parameters.first?.name ?? "input"
            return try await tool.execute(input: [paramName: action.argument]).output
        }
        logObservation(observation, callDescription: action.description, iteration: iteration, start: start)
        return observation
    }

    /// Continuation block for a markerless thought: record it AND teach the
    /// format — one nudge before implicit-conclusion can swallow the intent.
    static func proseContinuation(for thought: String) -> String {
        """


        Thought: \(thought)
        (Reminder: to use a tool, reply with exactly "ACTION: tool_name(argument)". \
        To give your final answer, start with "CONCLUSION:".)
        """
    }
}
