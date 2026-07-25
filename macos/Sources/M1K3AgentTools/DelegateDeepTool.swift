//
//  DelegateDeepTool.swift
//  M1K3AgentTools
//
//  Hands a long-form task to the resident deep brain to run in the background
//  while the conversation stays quick (Kev, 2026-07-25). Thin by design: the
//  injected closure is the app's DeepDelegation manager, which owns
//  eligibility (DeepDelegationPolicy), single-flight, execution on the MLX
//  slot, and delivery (transcript message + notification). The tool just
//  validates and forwards — same closure-injection shape as open_link.
//
//  Signed: Kev + claude-fable-5, 2026-07-25, Confidence 0.9, Prior: Unknown
//

import Foundation
import M1K3Agent

public struct DelegateDeepTool: AgentTool {
    public let name = "delegate_deep"
    public let description =
        "Hand a genuinely long-form task (a deep dive, a long document, heavy "
            + "analysis) to the deeper brain to work on in the background. Returns "
            + "immediately — the result arrives in the chat later with a "
            + "notification. Use ONLY when the user asks for something big; answer "
            + "ordinary questions yourself."
    public let parameters = [
        ToolParameter(name: "task", description: "The full task for the deep brain, self-contained."),
    ]

    /// The app's delegation manager: returns the observation for the model
    /// ("Delegated…" / "Error: already working on…" / an eligibility refusal).
    private let startDelegation: @Sendable (String) async -> String

    public init(startDelegation: @escaping @Sendable (String) async -> String) {
        self.startDelegation = startDelegation
    }

    public func execute(input: [String: String]) async throws -> ToolResult {
        let task = (input["task"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else {
            return ToolResult(output: "Error: delegate_deep needs a task — describe what to dig into.")
        }
        return await ToolResult(output: startDelegation(task))
    }
}
