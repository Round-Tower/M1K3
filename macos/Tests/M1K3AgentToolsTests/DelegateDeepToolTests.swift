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
}

private actor TaskRecorder {
    var tasks: [String] = []
    func record(_ task: String) {
        tasks.append(task)
    }
}
