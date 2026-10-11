import Foundation
@testable import M1K3Inference
import Testing

/// Pins the full-conversation accumulator a tool session replays when
/// delta-rendering fails (templates that re-validate the whole array reject a
/// tool-result-only delta — Qwen3.5's "No user query found in messages"). The
/// rebuilt transcript must be a VALID, ordered conversation: system, user
/// goal, then every assistant call interleaved with its tool result.
struct ToolTurnTranscriptTests {
    @Test("records sent messages and generated turns in conversation order")
    func interleavesSentAndGenerated() {
        var transcript = ToolTurnTranscript()
        transcript.recordSent([.system("persona"), .user("Iran US war latest")])
        transcript.recordGenerated(.toolCalls([ParsedToolCall(name: "search", arguments: ["q": .string("iran")])]))
        transcript.recordSent([.toolResult(name: "search", output: "results…")])
        transcript.recordGenerated(.text("Here's what I found."))

        // system, user, assistant(calls), toolResult, assistant(text).
        #expect(transcript.full.count == 5)
        // The assistant tool-call turn sits BETWEEN the user goal and the tool
        // result — the order the model was trained on.
        guard case .system = transcript.full[0] else { Issue.record("0 not system"); return }
        guard case .user = transcript.full[1] else { Issue.record("1 not user"); return }
        guard case let .assistant(text, calls) = transcript.full[2] else {
            Issue.record("2 not assistant"); return
        }
        #expect(text == nil)
        #expect(calls.first?.name == "search")
        guard case let .toolResult(name, _) = transcript.full[3] else {
            Issue.record("3 not toolResult"); return
        }
        #expect(name == "search")
    }

    @Test("a text turn is recorded as an assistant message carrying the answer")
    func textTurnRecorded() {
        var transcript = ToolTurnTranscript()
        transcript.recordSent([.user("hi")])
        transcript.recordGenerated(.text("hello"))
        guard case let .assistant(text, calls) = transcript.full.last else {
            Issue.record("not assistant"); return
        }
        #expect(text == "hello")
        #expect(calls.isEmpty)
    }

    @Test("a rejected tool call is recorded as an assistant turn carrying its prose, no calls (#418)")
    func rejectedTurnRecorded() {
        var transcript = ToolTurnTranscript()
        transcript.recordGenerated(.rejectedToolCalls(reason: "invalid_arguments", text: "Let me try."))
        transcript.recordGenerated(.rejectedToolCalls(reason: "malformed_syntax", text: ""))
        #expect(transcript.full == [
            .assistant(text: "Let me try.", toolCalls: []),
            .assistant(text: nil, toolCalls: []),
        ])
    }

    @Test("the leading system message is retained for a fresh re-render")
    func keepsSystemForReRender() {
        // The delta path drops .system (it's in the seeded cache), but a
        // fresh-cache re-render needs the persona back — so the accumulator
        // keeps the raw stream, system included.
        var transcript = ToolTurnTranscript()
        transcript.recordSent([.system("persona+tools"), .user("q")])
        guard case .system = transcript.full.first else { Issue.record("system dropped"); return }
    }

    @Test("a fresh transcript is empty")
    func startsEmpty() {
        #expect(ToolTurnTranscript().full.isEmpty)
    }

    @Test("a prepare-throw re-render sees no phantom assistant turn")
    func noPhantomAssistantAfterSendThrow() {
        // The recovery flow: recordSent happens BEFORE the render that can
        // throw; recordGenerated only after a successful generation. A
        // re-render of `full` right after the throw must therefore end on the
        // sent messages — an invented empty assistant turn here would put the
        // fresh render off-distribution. Pins the call-site ordering contract.
        var transcript = ToolTurnTranscript()
        transcript.recordSent([.system("persona"), .user("goal")])
        transcript.recordGenerated(.toolCalls([ParsedToolCall(name: "search", arguments: [:])]))
        transcript.recordSent([.toolResult(name: "search", output: "data")])
        // Delta render rejected here — nothing generated.
        let assistantTurns = transcript.full.filter {
            if case .assistant = $0 { return true } else { return false }
        }
        #expect(assistantTurns.count == 1)
        guard case .toolResult = transcript.full.last else {
            Issue.record("re-render must end on the tool result"); return
        }
    }
}
