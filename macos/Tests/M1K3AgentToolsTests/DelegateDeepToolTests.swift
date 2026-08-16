//
//  DelegateDeepToolTests.swift
//  M1K3AgentToolsTests
//
//  The delegate_deep tool is a thin shim: it validates the task string and
//  hands it to the injected start closure (the app's DeepDelegation manager
//  owns eligibility, single-flight, execution, and delivery). What's pinned
//  here: the observation passthrough, the empty-task guard, and that the tool
//  NEVER throws (the "Error: …" observation contract).
//
//  Signed: Kev + claude-fable-5, 2026-07-25, Confidence 0.9, Prior: Unknown
//  Review: Kev + claude-fable-5, 2026-08-15 — the no-escalation description
//  pin was deliberately inverted to a conditional-escalation pin when the
//  DeepDiveTarget wiring landed (PR #130); the replacement test carries the
//  history of both flips. Confidence 0.9.
//

import M1K3AgentTools
import Testing

struct DelegateDeepToolTests {
    @Test("passes the task through and returns the manager's observation")
    func passesTaskThrough() async throws {
        let recorder = TaskRecorder()
        let tool = DelegateDeepTool(startDelegation: { task in
            await recorder.record(task)
            return "Delegated. I'll ping you when it lands."
        })
        let result = try await tool.execute(input: ["task": "write a deep dive on RRF fusion"])
        #expect(result.output == "Delegated. I'll ping you when it lands.")
        #expect(await recorder.tasks == ["write a deep dive on RRF fusion"])
    }

    @Test("an empty or whitespace task is refused without reaching the manager")
    func emptyTaskRefused() async throws {
        let recorder = TaskRecorder()
        let tool = DelegateDeepTool(startDelegation: { task in
            await recorder.record(task)
            return "should never happen"
        })
        let result = try await tool.execute(input: ["task": "   "])
        #expect(result.output.hasPrefix("Error:"))
        #expect(await recorder.tasks.isEmpty)
    }

    @Test("tool metadata: name, one task parameter")
    func metadata() {
        let tool = DelegateDeepTool(startDelegation: { _ in "" })
        #expect(tool.name == "delegate_deep")
        #expect(tool.parameters.count == 1)
        #expect(tool.parameters.first?.name == "task")
    }

    // MARK: - The description must describe what the tool actually does

    @Test("the description promises escalation CONDITIONALLY — it happens where this Mac allows it")
    func descriptionPromisesConditionalEscalation() {
        // History, so nobody reverts this to either absolute: the description
        // originally promised "the deeper brain" while the plumbing ran the dive
        // on the resident one (fixed #117 — a tool that lies to the model is
        // worse than no tool). On 2026-08-15 the escalation was actually WIRED
        // (DeepDiveTarget → slot swap), so the honest description changed again:
        // escalation is real but conditional (Big installed + 24GB comfort bar,
        // see DeepDiveTarget's refusals). The per-call observation
        // (DeepDiveObservation) tells the model which shape it actually got.
        let description = DelegateDeepTool(startDelegation: { _ in "" }).description.lowercased()
        #expect(description.contains("escalat"))
        #expect(description.contains("where") || description.contains("when") || description.contains("if"))
    }

    @Test("the description names the real trade: background time, and a weaker front meanwhile")
    func descriptionNamesTheTrade() {
        // Delegating is not free. While the dive holds the one MLX slot, every
        // interactive turn is routed to Mini (refreshInterimBridge) — faster, but
        // the weakest tier. The model is choosing on the user's behalf, so it has
        // to be told what it's spending, not just what it's buying.
        let description = DelegateDeepTool(startDelegation: { _ in "" }).description.lowercased()
        #expect(description.contains("background"))
        #expect(description.contains("mini"))
    }
}

private actor TaskRecorder {
    var tasks: [String] = []
    func record(_ task: String) {
        tasks.append(task)
    }
}
