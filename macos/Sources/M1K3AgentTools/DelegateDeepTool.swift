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
//  Review: Kev + claude-fable-5, 2026-08-15 — description truthed up again for
//  the wired escalation (conditional, DeepDiveTarget-gated; see the test's
//  history note pinning both flips). Confidence 0.9.
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
    /// Spawns MLX generation on the slot — so it takes the serial exclusive
    /// lane in a multi-call batch. Honest scope (review, #131): execute()
    /// returns as soon as the manager DISPATCHES the dive, so the lane bounds
    /// only that quick dispatch — the background generation itself outlives it
    /// and can overlap a later batch-mate's MLX work (fire-and-forget is the
    /// tool's pre-existing 2026-07-25 design). The flag still buys correct
    /// ORDERING (the dive is dispatched before a batch-mate's embed starts),
    /// not a hard mutual exclusion.
    public let requiresExclusiveCompute = true
    /// P1 same-turn exclusion (Finding 1): a dive spins up a SEPARATE agent
    /// whose palette carries the web tools, so delegate_deep is an off-Mac
    /// egress path — classed `.network` so it is steered away once a
    /// local-sensitive tool (execute_script) has fired this turn, and vice
    /// versa. Closes the script→delegate_deep→web same-turn exfil chain.
    public let exclusionClass: ToolExclusionClass? = .network
    /// Describes what the plumbing ACTUALLY does — third revision of this
    /// string, each tracking the plumbing (see the test's history note). Since
    /// 2026-08-15 the manager runs DeepDiveTarget.plan and, where this Mac
    /// allows it (Big installed + the 24GB comfort bar), swaps the MLX slot to
    /// Big for the dive — real escalation, conditionally. Elsewhere the dive
    /// stays on the resident brain (time, not intelligence). The per-call
    /// observation (DeepDiveObservation) tells the model which shape it got;
    /// the standing cost is stated so the model chooses knowingly: interactive
    /// turns route to Mini while the slot is held.
    public let description =
        "Run a long or genuinely hard task in the background instead of answering "
            + "it now. Where this Mac allows it, the task escalates to the deepest "
            + "installed brain; otherwise it runs on the brain already in use (buying "
            + "time, not extra intelligence). While it runs, chat replies come from "
            + "Mini: faster, but the weakest tier. Returns immediately; the result "
            + "lands in this chat later with a notification. Use ONLY for work that "
            + "genuinely takes minutes or needs the deepest reasoning — answer "
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
