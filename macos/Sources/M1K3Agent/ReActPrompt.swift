//
//  ReActPrompt.swift
//  M1K3Agent
//
//  The prompt-ReAct floor's layout: the parts that stay the same for a given
//  tool palette first, then what this turn brings, then the goal.
//
//  Why (2026-09-14): the floor is, in production, Mini — Apple Foundation
//  Models, which builds a fresh session per call and re-reads the whole prompt
//  every time. AFM can process a prompt PREFIX ahead of need
//  (`LanguageModelSession.prewarm(promptPrefix:)`), but only if the live prompt
//  begins with it. The old layout opened with "Your goal: <question>", so no
//  two turns shared a first byte and the prewarm could only cover the
//  instructions. Measured on this Mac (AC, n=3–4 per arm, a plain-process
//  probe): turn-1 first token 7.2 s with no prewarm, 6.7 s instructions-only
//  (what shipped), 2.1 s with the tool + rules head prewarmed.
//
//  Goal-last is also the order the MLX tiers already use (the 08-13 prefill
//  day): a small model weights the end of its prompt, and the question is the
//  thing it most needs in view.
//
//  Signed: Kev + claude-opus-5, 2026-09-14, Confidence 0.8 (pure and pinned by
//  ReActPromptLayoutTests + ReActStableFirstResponderTests; the quality of the
//  new order is gated by a live-path Mini eval, the timing by the installed
//  app). Prior: the goal-first body in LocalAgent+ReAct.swift (Kev + claude-opus-4-8).
//

import Foundation

/// The ReAct floor's prompt, in two halves: a `head` that depends only on the
/// tool palette and the caller's standing rules, and a `tail` that carries the
/// turn. A backend that can prewarm a prompt prefix processes the head before
/// the question exists; both the prewarm and the live turn build it here, so
/// the two cannot drift by a byte.
public enum ReActPrompt {
    /// "name: description", one per line, sorted — the order the floor has
    /// always used (a Dictionary's `.values` order would change per process).
    public static func toolLines(_ tools: [any AgentTool]) -> String {
        tools.map { "\($0.name): \($0.description)" }.sorted().joined(separator: "\n")
    }

    /// The format the loop parses — word for word what the floor has always sent.
    static let format = """
    Use ReAct reasoning:
    - Think step-by-step about what information you need.
    - To use a tool, write: "ACTION: ToolName(argument)"
    - When you have enough information, reply starting with "CONCLUSION:"
    """

    /// The stable head: the tool list, the standing rules when the caller has
    /// any, then the format. Ends on a blank line — the tail follows directly.
    public static func head(tools: [any AgentTool], standing: String?) -> String {
        let rules = standing.map { "\($0)\n\n" } ?? ""
        return "Available Tools:\n\(toolLines(tools))\n\n\(rules)\(format)\n\n"
    }

    /// The turn: its context (when there is any), then the goal, then the cue.
    public static func tail(goal: String, context: String?) -> String {
        let contextBlock = context.map { "Context:\n\($0)\n\n" } ?? ""
        return "\(contextBlock)Your goal: \(goal)\n\nBegin your analysis:"
    }
}
