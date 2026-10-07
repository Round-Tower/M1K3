//
//  Qwen35CallRepairTests.swift
//  M1K3MLXTests
//
//  The orphan-`</parameter>` repair for Qwen3.5 tool calls. The shape is the one root-caused at
//  launch (docs/GEMMA_1_1_PLAN.md Stream B): `<function=datetime>`, a stray close, then the real
//  parameter. Upstream's processor does the re-parse, so its validation still governs.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-07, Confidence 0.8, Prior: none (new file).
//  Review: Kev + claude-opus-5-5, 2026-10-08, Confidence 0.85 — #511 review: pins that the repair never
//  re-emits an earlier, already-streamed call, and the unterminated-shape pass-throughs.
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

private let offered: Set<String> = ["datetime", "web_search"]

private func rejected(_ raw: String) -> RejectedToolCall {
    RejectedToolCall(reason: .malformedSyntax, format: .qwen35, rawText: raw)
}

struct Qwen35CallRepairTests {
    @Test("the recorded shape really is rejected by the live path's processor — something to fix")
    func upstreamRejectsTheOrphan() {
        let processor = ToolCallProcessor(format: .qwen35)
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

    @Test("a value that contains `<function=` is copied verbatim, never read as a header")
    func valuesAreNeverStructure() throws {
        let tricky = """
        <tool_call>
        <function=web_search>
        </parameter>
        <parameter=query>
        what does <function=y> mean
        </parameter>
        </function>
        </tool_call>
        """
        let repaired = try #require(Qwen35CallRepair.strippingOrphanCloses(tricky))
        #expect(repaired.contains("<parameter=query>\nwhat does <function=y> mean\n</parameter>"))
        let calls = try #require(Qwen35CallRepair.recover(rejected(tricky), offered: offered))
        #expect(calls.first?.function.arguments["query"] == .string("what does <function=y> mean"))
    }

    @Test("each function in a multi-call output is repaired on its own, and both calls parse")
    func repairsEveryFunction() throws {
        let two = orphaned + "\n" + orphaned
        let repaired = try #require(Qwen35CallRepair.strippingOrphanCloses(two))
        #expect(repaired.components(separatedBy: "</parameter>").count - 1 == 2)
        let calls = try #require(Qwen35CallRepair.recover(rejected(two), offered: offered))
        #expect(calls.map(\.function.name) == ["datetime", "datetime"])
    }

    @Test("a rejected orphan call is recovered with its argument, exactly as live would carry it")
    func recoversTheCall() throws {
        let calls = try #require(Qwen35CallRepair.recover(rejected(orphaned), offered: offered))
        #expect(calls.map(\.function.name) == ["datetime"])
        #expect(calls.first?.function.arguments["query"] == .string("now"))
    }

    @Test("trailing prose after the call doesn't block the repair or become a call")
    func trailingProse() throws {
        let calls = try #require(
            Qwen35CallRepair.recover(rejected(orphaned + "\nLet me check that for you."), offered: offered)
        )
        #expect(calls.map(\.function.name) == ["datetime"])
    }

    @Test("the gate: another format, another reason, or a truncated preview stays rejected")
    func gateHolds() {
        let json = RejectedToolCall(reason: .malformedSyntax, format: .json, rawText: orphaned)
        #expect(Qwen35CallRepair.recover(json, offered: offered) == nil)
        let undeclared = RejectedToolCall(reason: .undeclaredTool, format: .qwen35, rawText: orphaned)
        #expect(Qwen35CallRepair.recover(undeclared, offered: offered) == nil)
        let truncated = RejectedToolCall(
            reason: .malformedSyntax, format: .qwen35, rawText: orphaned + String(repeating: "x", count: 200),
            previewByteLimit: 64
        )
        #expect(truncated.isPreviewTruncated)
        #expect(Qwen35CallRepair.recover(truncated, offered: offered) == nil)
    }

    @Test("a repaired call naming a tool that wasn't offered stays rejected — the repair never widens the set")
    func repairNeverWidensTheToolSet() {
        #expect(Qwen35CallRepair.recover(rejected(orphaned), offered: ["web_search"]) == nil)
        #expect(Qwen35CallRepair.recover(rejected(orphaned), offered: []) == nil)
    }

    @Test("a buffer with one repairable and one still-malformed call is not half-repaired")
    func mixedBufferStaysRejected() {
        let broken = "<tool_call>\n<function=web_search>\n<parameter=query>\nx\n</tool_call>"
        #expect(Qwen35CallRepair.recover(rejected(orphaned + "\n" + broken), offered: offered) == nil)
    }

    /// #511 review (both passes): could a well-formed call EARLIER in the same output be re-emitted?
    /// Run the live path's processor over the whole output and repair what it rejected: the earlier
    /// call leaves the buffer when emitted, so the rejection's preview holds only what came after it.
    @Test("a valid call then an orphaned one: the live stream emits the first, the repair only the second")
    func noDuplicateOfAnEarlierCall() throws {
        let valid = "<tool_call>\n<function=web_search>\n<parameter=query>\ncork\n</parameter>\n"
            + "</function>\n</tool_call>"
        let live = ToolCallProcessor(format: .qwen35)
        _ = live.processChunk(valid + "\n" + orphaned)
        live.processEOS()
        #expect(live.toolCalls.map(\.function.name) == ["web_search"])
        let rejection = try #require(live.rejectedToolCalls.first)
        #expect(!rejection.rawTextPreview.contains("function=web_search"))
        let repaired = try #require(Qwen35CallRepair.recover(rejection, offered: offered))
        #expect(repaired.map(\.function.name) == ["datetime"])
    }

    @Test("a header with no `>`, or a function with no close, passes through without a repair")
    func unterminatedShapesPassThrough() {
        #expect(Qwen35CallRepair.strippingOrphanCloses("<tool_call>\n<function=datetime\n</parameter>") == nil)
        let unclosed = "<tool_call>\n<function=datetime>\n<parameter=query>\nnow\n</parameter>\n</parameter>"
        #expect(Qwen35CallRepair.strippingOrphanCloses(unclosed) == nil)
    }

    @Test("offered names read the ToolSpec shape; nil specs offer nothing")
    func offeredNamesFromSpecs() {
        #expect(Qwen35CallRepair.offeredNames([datetimeSchema]) == ["datetime"])
        #expect(Qwen35CallRepair.offeredNames(nil).isEmpty)
    }
}
