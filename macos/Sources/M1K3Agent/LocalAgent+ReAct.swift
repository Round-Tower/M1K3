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
        onEvent: (@Sendable (AgentLoopEvent) -> Void)?,
        onConclusionToken: (@Sendable (String) -> Void)?
    ) async throws -> AgentResult {
        var usedTools = Set<String>()
        var executedActions = Set<String>()
        var currentContext = buildInitialContext(goal: goal, grounding: grounding)

        logRunStart(goal: goal, grounding: grounding)

        for iteration in 0 ..< maxIterations {
            try Task.checkCancellation()
            onEvent?(.thinking(iteration: iteration))
            let thought = try await generateThought(
                context: currentContext,
                iteration: iteration,
                onConclusionToken: onConclusionToken
            )

            if let result = markerConclusion(from: thought, iteration: iteration, usedTools: usedTools) {
                return result
            }

            guard let action = parseAction(from: thought) else {
                reasoningTrace.append(ReasoningStep(iteration: iteration, thought: thought))
                // Small models often just answer in prose instead of emitting the
                // CONCLUSION marker. After they've had one structured chance,
                // treat substantive unstructured prose as the answer rather than
                // burning the remaining iterations re-prompting.
                if concludesOnUnstructuredThought, iteration >= 1, !thought.isEmpty {
                    M1K3Log.agentLoop.info("iteration \(iteration): implicit conclusion (prose, no markers)")
                    return concluded(thought, usedTools, iteration + 1)
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
            Observation: \(observation)
            """
        }

        // Iteration cap reached — synthesise from the accumulated context.
        logCapReached()
        let finalConclusion = try await synthesizeConclusion(context: currentContext)
        return concluded(finalConclusion, usedTools, maxIterations)
    }

    /// Conclude from a CONCLUSION-marker thought — unless the "conclusion" is
    /// an action in a trench coat ("CONCLUSION: ACTION: …", seen live): when
    /// nothing survives the scaffolding strip but the thought parses as an
    /// action, return nil so the loop falls through to the action path.
    private func markerConclusion(
        from thought: String, iteration: Int, usedTools: Set<String>
    ) -> AgentResult? {
        guard thought.contains("CONCLUSION:") else { return nil }
        let conclusion = extractConclusion(from: thought)
        if Self.stripScaffolding(conclusion).isEmpty, parseAction(from: thought) != nil {
            M1K3Log.agentLoop.notice(
                "iteration \(iteration): conclusion was only scaffolding — treating as action"
            )
            return nil
        }
        reasoningTrace.append(ReasoningStep(iteration: iteration, thought: thought))
        return concluded(conclusion, usedTools, iteration + 1)
    }

    // MARK: - Prompt construction

    private func buildInitialContext(goal: String, grounding: String?) -> String {
        let toolDescriptions = tools.values
            .map { "\($0.name): \($0.description)" }
            .sorted()
            .joined(separator: "\n")

        let groundingBlock = grounding.map { "\n\nContext:\n\($0)" } ?? ""

        // Only send the persona when the backend isn't already carrying it.
        // A bare completion model has nowhere else to learn who it is; AFM
        // opens every session with the same persona as standing instructions,
        // so including it here sent Mini ~890 tokens of duplicate identity per
        // generation — ~43% of its 4096-token window, before the question.
        // Not conforming to PersonaCarrying keeps the old behaviour exactly.
        let carriesPersona = (inferenceProvider as? PersonaCarrying)?.carriesStandingPersona == true
        let personaBlock = carriesPersona ? "" : "\(M1K3Persona.systemPrompt)\n\n"

        return """
        \(personaBlock)Your goal: \(goal)\(groundingBlock)

        Available Tools:
        \(toolDescriptions)

        Use ReAct reasoning:
        - Think step-by-step about what information you need.
        - To use a tool, write: "ACTION: ToolName(argument)"
        - When you have enough information, reply starting with "CONCLUSION:"

        Begin your analysis:
        """
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
        for await chunk in inferenceProvider.generateStreaming(prompt: prompt) {
            let live = splitter.feed(chunk)
            if !live.isEmpty {
                onConclusionToken(live)
            }
        }
        // Release the splitter's guard window now the stream is over.
        let guarded = splitter.flush()
        if !guarded.isEmpty {
            onConclusionToken(guarded)
        }
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
