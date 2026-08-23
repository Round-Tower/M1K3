//
//  DistillationTaintTests.swift
//  M1K3ChatTests
//
//  P3 of the context-tools charter: an answer shaped by execute_script must
//  never reach the memory distiller — distilled facts have no provenance, so
//  script output would otherwise become a permanent memory-graph fact that
//  outlives the toggle, the approval, and the script itself.
//
//  Signed: Kev + claude-fable-5, 2026-08-23, Confidence 0.9, Prior: Unknown

import Foundation
@testable import M1K3Chat
import Testing

struct DistillationTaintTests {
    private func message(
        _ role: ChatMessage.Role, _ text: String, tools: [String]? = nil
    ) -> ChatMessage {
        var message = ChatMessage(role: role, text: text, status: .complete)
        message.toolsUsed = tools
        return message
    }

    @Test("execute_script taints; other tools and nil do not")
    func taintRule() {
        #expect(DistillationTaint.isTainted(toolsUsed: ["execute_script"]))
        #expect(DistillationTaint.isTainted(toolsUsed: ["web_search", "execute_script"]))
        #expect(!DistillationTaint.isTainted(toolsUsed: ["web_search", "datetime"]))
        #expect(!DistillationTaint.isTainted(toolsUsed: []))
        #expect(!DistillationTaint.isTainted(toolsUsed: nil))
    }

    @Test("a script-shaped answer is dropped from the distillable turns; the rest survive")
    func taintedTurnSkipped() {
        let messages = [
            message(.user, "how full is the disk?"),
            message(.assistant, "Your disk is 82% full.", tools: ["execute_script"]),
            message(.user, "thanks — remember I prefer weekly backups"),
            message(.assistant, "Noted: weekly backups.", tools: ["search_knowledge"]),
        ]
        let turns = ChatSession.distillableTurns(messages[0...])
        #expect(turns.map(\.text) == [
            "how full is the disk?",
            "thanks — remember I prefer weekly backups",
            "Noted: weekly backups.",
        ])
    }

    @Test("incomplete and empty messages still never distill (the existing rule holds)")
    func existingRulesHold() {
        var streaming = message(.assistant, "half an ans")
        streaming.status = .streaming
        let messages = [message(.user, "hi"), streaming, message(.assistant, "")]
        let turns = ChatSession.distillableTurns(messages[0...])
        #expect(turns.map(\.text) == ["hi"])
    }
}
