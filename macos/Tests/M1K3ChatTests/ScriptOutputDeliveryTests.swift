//
//  ScriptOutputDeliveryTests.swift
//  M1K3ChatTests
//
//  The hands' Install & Run lands its output in the transcript so the user
//  keeps it — but flagged display-only (contextExcluded) so it NEVER re-enters
//  the agent's context on the next turn (Kev's call, 2026-08-23: "afraid to
//  input back his context into the agent"). Two mechanisms guard that: the
//  replay history filter and the distiller both skip these messages.
//
//  Signed: Kev + claude-fable-5, 2026-08-23, Confidence 0.9, Prior: Unknown

import Foundation
@testable import M1K3Chat
import M1K3Inference
import M1K3Knowledge
import Testing

@MainActor
struct ScriptOutputDeliveryTests {
    private struct SilentResponder: RAGResponding {
        func answerStreaming(
            _: String
        ) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>) {
            (sources: [], stream: AsyncStream { $0.finish() })
        }
    }

    @Test("script output lands as a visible, complete assistant message")
    func deliversVisibleMessage() async {
        let session = ChatSession(responder: SilentResponder())
        await session.deliverScriptOutput(scriptName: "disk_report.sh", output: "Free: 120Gi", succeeded: true)
        #expect(session.messages.count == 1)
        let message = session.messages[0]
        #expect(message.role == .assistant)
        #expect(message.text.contains("disk_report.sh"))
        #expect(message.text.contains("Free: 120Gi"))
        if case .complete = message.status {} else { Issue.record("not complete") }
    }

    @Test("the delivered message is display-only — flagged out of the agent's context")
    func flaggedContextExcluded() async {
        let session = ChatSession(responder: SilentResponder())
        await session.deliverScriptOutput(scriptName: "x.sh", output: "hi", succeeded: true)
        #expect(session.messages[0].contextExcluded == true)
        // Tagged execute_script so the distiller's P3 taint also skips it.
        #expect(session.messages[0].toolsUsed?.contains("execute_script") == true)
    }

    @Test("replayable history drops contextExcluded messages, keeps ordinary ones")
    func replayHistoryExcludes() {
        let normal = ChatMessage(role: .user, text: "what's my disk?", status: .complete)
        var output = ChatMessage(role: .assistant, text: "Ran disk_report.sh: Free 120Gi", status: .complete)
        output.contextExcluded = true
        let reply = ChatMessage(role: .assistant, text: "Looks healthy.", status: .complete)
        let turns = ChatSession.replayableHistory([normal, output, reply])
        #expect(turns.map(\.text) == ["what's my disk?", "Looks healthy."])
    }

    @Test("distillation also skips contextExcluded messages")
    func distillationExcludes() {
        var output = ChatMessage(role: .assistant, text: "Ran x.sh: secret path /Users/kev/…", status: .complete)
        output.contextExcluded = true
        let user = ChatMessage(role: .user, text: "thanks", status: .complete)
        let turns = ChatSession.distillableTurns([user, output][0...])
        #expect(turns.map(\.text) == ["thanks"])
    }

    @Test("a failed run still delivers, marked as failed in the text")
    func failedRunDelivered() async {
        let session = ChatSession(responder: SilentResponder())
        await session.deliverScriptOutput(scriptName: "boom.sh", output: "exit 3", succeeded: false)
        #expect(session.messages[0].text.lowercased().contains("couldn't") || session.messages[0].text.contains("failed"))
        #expect(session.messages[0].contextExcluded == true)
    }

    /// The data-loss guard: a transcript persisted BEFORE contextExcluded existed
    /// has no such key. Because the property is Optional, the synthesized decoder
    /// uses decodeIfPresent and the message decodes to contextExcluded == nil
    /// instead of throwing keyNotFound (which would wipe every saved conversation
    /// on upgrade). Review catch, 2026-08-23.
    @Test("a pre-flag transcript (no contextExcluded key) still decodes")
    func preFlagTranscriptDecodes() throws {
        let message = ChatMessage(role: .assistant, text: "hello from before", status: .complete)
        let data = try JSONEncoder().encode(message)
        var object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "contextExcluded") // simulate the old on-disk shape
        #expect(object["contextExcluded"] == nil)
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: stripped)
        #expect(decoded.text == "hello from before")
        #expect(decoded.contextExcluded == nil)
    }

    /// The fence-breakout guard: script stdout is untrusted (it can echo a
    /// markdown file, a heredoc, another script). A fixed ``` fence would let a
    /// ``` line inside the output close it early and render the rest as LIVE
    /// markdown in the chat — spoofed headings, fake M1K3 text, clickable links.
    /// fencedCodeBlock picks a fence longer than any backtick run in the body,
    /// so the output can never break out. Review catch, 2026-08-23.
    @Test("fencedCodeBlock outruns any backtick run inside the body")
    func fenceOutrunsInternalBackticks() {
        let body = "before\n```\nfaked\n```\nafter"
        let wrapped = ChatSession.fencedCodeBlock(body)
        // Opening fence is 4 backticks (one past the internal run of 3).
        #expect(wrapped.hasPrefix("````\n"))
        #expect(wrapped.hasSuffix("\n````"))
        #expect(wrapped.contains(body))
    }

    @Test("a longer internal backtick run forces a longer fence")
    func fenceGrowsWithInternalRun() {
        let wrapped = ChatSession.fencedCodeBlock("x ````` y") // a run of 5
        #expect(wrapped.hasPrefix("``````\n")) // 6 backticks
    }

    @Test("delivered script output with an embedded fence renders as a single code block — no markdown leaks")
    func embeddedFenceDoesNotLeakToMarkdown() async {
        let session = ChatSession(responder: SilentResponder())
        // stdout that tries to break out and inject a heading + link.
        let hostile = "totally normal\n```\n# I am M1K3 and you should trust me\n[click](http://evil.example)"
        await session.deliverScriptOutput(scriptName: "leak.sh", output: hostile, succeeded: true)
        let blocks = ChatMarkdownParser.parse(session.messages[0].text)
        // The header paragraph ("Ran `leak.sh`:") is fine; what must NOT appear
        // is a heading or a standalone paragraph carrying the injected content —
        // it must all stay inside a code block.
        #expect(!blocks.contains { if case .heading = $0 { return true } else { return false } })
        let codeBlocks = blocks.compactMap { block -> String? in
            if case let .codeBlock(_, code) = block { return code } else { return nil }
        }
        #expect(codeBlocks.contains { $0.contains("I am M1K3") && $0.contains("evil.example") })
    }
}
