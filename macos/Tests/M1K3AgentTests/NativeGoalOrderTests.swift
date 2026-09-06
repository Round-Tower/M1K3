//
//  NativeGoalOrderTests.swift
//  M1K3AgentTests
//
//  The native user message is rendered context-first, goal-LAST — and that
//  order is load-bearing twice over:
//
//  1. **KV prefix stability.** The context block opens with the day-granular
//     context line and the append-extending history replay; the goal changes
//     every turn. Goal-first put the divergence ~30 tokens into the message and
//     capped cross-turn cache reuse at the persona prefix (measured 2026-08-13:
//     1786 tokens reused, always, exactly the persona). Goal-last lets the
//     conversation-tail seed reuse everything up to this turn's grounding.
//  2. **Recency.** Small models weight the end of the prompt; the task should
//     sit closest to the generation, not the retrieved context.
//

@testable import M1K3Agent
import M1K3Inference
import Testing

struct NativeGoalOrderTests {
    @Test("the goal comes AFTER the context block")
    func goalIsLast() throws {
        let message = LocalAgent.buildNativeGoal(
            goal: "what's the tallest mountain in Ireland?",
            grounding: "Right now: it's Thursday.\n\nKNOWLEDGE:\nCarrauntoohil is 1,038m."
        )
        let contextAt = try #require(message.range(of: "Context:"))
        let goalAt = try #require(message.range(of: "Goal:"))
        #expect(contextAt.lowerBound < goalAt.lowerBound)
        #expect(message.hasSuffix("Goal: what's the tallest mountain in Ireland?"))
    }

    @Test("grounding renders verbatim inside the context block")
    func groundingCarriedWhole() {
        let message = LocalAgent.buildNativeGoal(goal: "hi", grounding: "FACT A\nFACT B")
        #expect(message.contains("Context:\nFACT A\nFACT B"))
    }

    @Test("no grounding → no empty Context header, goal still last")
    func noGroundingNoHeader() {
        let message = LocalAgent.buildNativeGoal(goal: "hello there", grounding: nil)
        #expect(!message.contains("Context:"))
        #expect(message.hasSuffix("Goal: hello there"))
    }

    @Test("groundingInUser reproduces today's two messages byte-for-byte")
    func shapeUserMatchesLegacy() {
        let persona = "PERSONA"
        let messages = LocalAgent.buildNativeMessages(
            persona: persona, goal: "hi", grounding: "FACT A", shape: .groundingInUser
        )
        #expect(messages.count == 2)
        guard case let .system(system) = messages[0], case let .user(user, _) = messages[1] else {
            Issue.record("expected system then user"); return
        }
        #expect(system == persona)
        #expect(user == LocalAgent.buildNativeGoal(goal: "hi", grounding: "FACT A"))
    }

    @Test("groundingInSystem moves the context into the system turn; the user turn carries only the goal (#LFM 0/5→5/5)")
    func shapeSystemMovesGrounding() {
        let messages = LocalAgent.buildNativeMessages(
            persona: "PERSONA", goal: "hi", grounding: "FACT A\nRULES:\n- x", shape: .groundingInSystem
        )
        guard case let .system(system) = messages[0], case let .user(user, _) = messages[1] else {
            Issue.record("expected system then user"); return
        }
        #expect(system.hasPrefix("PERSONA"))
        #expect(system.contains("FACT A\nRULES:\n- x"))
        #expect(!user.contains("Context:"))
        #expect(!user.contains("FACT A"))
        #expect(user.hasSuffix("Goal: hi"))
        #expect(user.hasPrefix("Use the available tools"))
    }

    @Test("groundingInSystem with EMPTY grounding is the persona alone too")
    func shapeSystemEmptyGrounding() {
        let messages = LocalAgent.buildNativeMessages(
            persona: "PERSONA", goal: "hi", grounding: "", shape: .groundingInSystem
        )
        guard case let .system(system) = messages[0] else { Issue.record("expected system"); return }
        #expect(system == "PERSONA")
    }

    @Test("groundingInSystem with no grounding is the persona alone — no dangling separator")
    func shapeSystemNoGrounding() {
        let messages = LocalAgent.buildNativeMessages(
            persona: "PERSONA", goal: "hi", grounding: nil, shape: .groundingInSystem
        )
        guard case let .system(system) = messages[0] else { Issue.record("expected system"); return }
        #expect(system == "PERSONA")
    }

    @Test("the preamble still opens the message — it is part of the stable prefix")
    func preambleFirst() {
        let message = LocalAgent.buildNativeGoal(goal: "hi", grounding: "x")
        #expect(message.hasPrefix("Use the available tools"))
    }
}
