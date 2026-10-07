//
//  Qwen35CallRepairTests.swift
//  M1K3MLXTests
//
//  The orphan-`</parameter>` repair for Qwen3.5 tool calls. The shape is the one root-caused at
//  launch (docs/GEMMA_1_1_PLAN.md Stream B): `<function=datetime>`, a stray close, then the real
//  parameter. Upstream's processor does the re-parse, so its validation still governs.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-07, Confidence 0.8, Prior: none (new file).
//

import Foundation
@testable import M1K3MLX
import MLXLMCommon
import Testing

private let datetimeSchema: [String: any Sendable] = [
    "type": "function",
    "function": [
        "name": "datetime",
        "description": "The current date and time.",
        "parameters": [
            "type": "object",
            "properties": ["query": ["type": "string", "description": "Ignored."] as [String: any Sendable]],
            "required": ["query"],
        ] as [String: any Sendable],
    ] as [String: any Sendable],
]

private let orphaned = """
<tool_call>
<function=datetime>
</parameter>
<parameter=query>
now
</parameter>
</function>
</tool_call>
"""

struct Qwen35CallRepairTests {
    @Test("the recorded shape really is rejected upstream — the repair has something to fix")
    func upstreamRejectsTheOrphan() {
        let processor = ToolCallProcessor(format: .qwen35, tools: [datetimeSchema])
        _ = processor.processChunk(orphaned)
        processor.processEOS()
        #expect(processor.toolCalls.isEmpty)
        #expect(processor.rejectedToolCalls.first?.reason == .malformedSyntax)
    }

    @Test("the orphan close before the first parameter is dropped; the real parameter survives")
    func stripsOnlyTheOrphan() throws {
        let repaired = try #require(Qwen35CallRepair.strippingOrphanCloses(orphaned))
        #expect(!repaired.contains("<function=datetime>\n</parameter>"))
        #expect(repaired.contains("<parameter=query>\nnow\n</parameter>"))
    }

    @Test("a well-formed call has no orphan: nothing to repair")
    func wellFormedIsUntouched() {
        let clean = "<tool_call>\n<function=datetime>\n<parameter=query>\nnow\n</parameter>\n</function>\n</tool_call>"
        #expect(Qwen35CallRepair.strippingOrphanCloses(clean) == nil)
    }

    @Test("a close AFTER a parameter is that parameter's own — never touched")
    func closesAfterParametersStay() {
        let twoParams = "<function=web_search>\n<parameter=query>\nx\n</parameter>\n</parameter>\n</function>"
        #expect(Qwen35CallRepair.strippingOrphanCloses(twoParams) == nil)
    }

    @Test("each function in a multi-call output is repaired on its own")
    func repairsEveryFunction() throws {
        let two = orphaned + "\n" + orphaned
        let repaired = try #require(Qwen35CallRepair.strippingOrphanCloses(two))
        #expect(repaired.components(separatedBy: "</parameter>").count - 1 == 2)
    }

    @Test("a rejected orphan call is recovered through upstream's own parser, with its argument")
    func recoversTheCall() throws {
        let rejection = RejectedToolCall(
            reason: .malformedSyntax, format: .qwen35, toolName: "datetime", rawText: orphaned
        )
        let calls = try #require(Qwen35CallRepair.recover(rejection, tools: [datetimeSchema]))
        #expect(calls.map(\.function.name) == ["datetime"])
        #expect(calls.first?.function.arguments["query"] == .string("now"))
    }

    @Test("the gate: another format, another reason, or a truncated preview stays rejected")
    func gateHolds() {
        let json = RejectedToolCall(reason: .malformedSyntax, format: .json, rawText: orphaned)
        #expect(Qwen35CallRepair.recover(json, tools: [datetimeSchema]) == nil)
        let unknown = RejectedToolCall(reason: .undeclaredTool, format: .qwen35, rawText: orphaned)
        #expect(Qwen35CallRepair.recover(unknown, tools: [datetimeSchema]) == nil)
        let truncated = RejectedToolCall(
            reason: .malformedSyntax, format: .qwen35, rawText: orphaned + String(repeating: "x", count: 200),
            previewByteLimit: 64
        )
        #expect(truncated.isPreviewTruncated)
        #expect(Qwen35CallRepair.recover(truncated, tools: [datetimeSchema]) == nil)
    }

    @Test("a repaired call naming a tool that isn't offered still fails upstream's own check")
    func repairNeverWidensTheToolSet() {
        let rejection = RejectedToolCall(reason: .malformedSyntax, format: .qwen35, rawText: orphaned)
        let parameters: [String: any Sendable] = ["type": "object", "properties": [:] as [String: any Sendable]]
        let function: [String: any Sendable] = ["name": "web_search", "parameters": parameters]
        let other: [String: any Sendable] = ["type": "function", "function": function]
        #expect(Qwen35CallRepair.recover(rejection, tools: [other]) == nil)
    }
}
