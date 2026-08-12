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
import M1K3Inference
import M1K3LogCore
import os

public struct DelegateDeepTool: AgentTool {
    /// Same `delegate_deep …` grammar the manager emits, so ONE grep over the
    /// unified log catches every invocation — including the ones that never
    /// reach the manager at all. Without this, a model calling with a blank
    /// task looks identical to a model that never called.
    private static let log = Logger(subsystem: M1K3Log.subsystem, category: "mlx-load")

    public let name = "delegate_deep"
    /// Describes what the plumbing ACTUALLY does. The previous wording promised
    /// "the deeper brain" — but the manager passes `swappableMLX`, the brain
    /// already resident, which under an eligible call is the very brain reading
    /// this description; `selectBrain` refuses mid-dive, so nothing heavier can
    /// be swapped in. This tool buys TIME, not intelligence, and it spends the
    /// conversation's quality to do it (interactive turns route to Mini while
    /// the slot is held). Both halves are stated so the model can make that
    /// trade knowingly on the user's behalf.
    public let description =
        "Run a long task in the background instead of answering it now. It goes to "
            + "the brain already in use — this buys time, not extra intelligence — and "
            + "while it runs, chat replies come from Mini: faster, but the weakest "
            + "tier. Returns immediately; the result lands in this chat later with a "
            + "notification. Use ONLY for work that genuinely takes minutes — answer "
            + "ordinary questions yourself."
    public let parameters = [
        // "the deep brain" survived here when the tool description above was
        // truthed-up (#117): a parameter description renders into the system
        // block exactly like the tool's own, so the promise the description
        // stopped making was still being made one line below it.
        ToolParameter(
            name: "task", description: "The full task to run in the background, self-contained."
        ),
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
            Self.log.notice(
                "\(DeepDelegationOutcome.declined(reason: .emptyTask).logLine, privacy: .public)"
            )
            return ToolResult(output: "Error: delegate_deep needs a task — describe what to dig into.")
        }
        return await ToolResult(output: startDelegation(task))
    }
}
