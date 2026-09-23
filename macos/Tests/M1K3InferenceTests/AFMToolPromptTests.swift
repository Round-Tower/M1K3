//
//  AFMToolPromptTests.swift
//  M1K3InferenceTests
//
//  Phase 15 — rendering the agent's typed `[ToolMessage]` transcript into the
//  single prompt string AFM's `respond(generating:)` consumes. AFM has no
//  role-tagged tool template to render into (unlike MLX's chat array), so the
//  whole conversation collapses to one prompt + the `@Generable` schema Apple
//  injects. The persona `.system` turn is lifted OUT to the session's
//  `instructions:` (where AFM is trained to read standing rules), so the body
//  carries only the goal, the model's own prior calls, and the tool results.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-15, Confidence 0.85, Prior: Unknown

import Foundation
@testable import M1K3Inference
import Testing

struct AFMToolPromptTests {
    private let tools = [
        ToolDefinition(
            name: "web_search",
            description: "Search the live web for current information.",
            parameters: [ToolParameterDefinition(name: "query", description: "what to search for")]
        ),
        ToolDefinition(
            name: "lookup_fact",
            description: "Look up an encyclopedic fact.",
            parameters: [ToolParameterDefinition(name: "query", description: "the subject")]
        ),
    ]

    @Test("the rendered body lists every tool with its name and description")
    func catalogueListsTools() {
        let body = AFMToolPrompt.render(messages: [.user("What are the tides in Cork?")], tools: tools)
        #expect(body.contains("web_search"))
        #expect(body.contains("Search the live web for current information."))
        #expect(body.contains("lookup_fact"))
        #expect(body.contains("Look up an encyclopedic fact."))
    }

    @Test("the user goal appears in the body")
    func goalAppears() {
        let body = AFMToolPrompt.render(messages: [.user("What are the tides in Cork?")], tools: tools)
        #expect(body.contains("What are the tides in Cork?"))
    }

    @Test("prior tool calls and their results are threaded back into the body")
    func resultsThreaded() {
        let body = AFMToolPrompt.render(
            messages: [
                .user("Tides in Cork?"),
                .assistant(text: nil, toolCalls: [
                    ParsedToolCall(name: "web_search", arguments: ["query": .string("Cork tides")]),
                ]),
                .toolResult(name: "web_search", output: "High tide 14:03, low 20:11."),
            ],
            tools: tools
        )
        // Assert the call's own ARGUMENT and the result text — "web_search" alone
        // is a false positive (it is already in the tool catalogue above).
        #expect(body.contains("Cork tides"))
        #expect(body.contains("High tide 14:03, low 20:11."))
    }

    @Test("the persona system turn is NOT in the body — it goes to session instructions")
    func systemExcludedFromBody() {
        let persona = "You are M1K3, a private local assistant."
        let body = AFMToolPrompt.render(
            messages: [.system(persona), .user("hello")],
            tools: tools
        )
        #expect(!body.contains(persona))
    }

    @Test("system instructions take the first turn, trimmed; nil when absent or blank")
    func systemInstructionsExtraction() {
        let none = AFMToolPrompt.systemInstructions(from: [.user("hi")])
        #expect(none == nil)

        let one = AFMToolPrompt.systemInstructions(from: [.system("  Be M1K3.  "), .user("hi")])
        #expect(one == "Be M1K3.")

        let blank = AFMToolPrompt.systemInstructions(from: [.system("   "), .user("hi")])
        #expect(blank == nil)

        // Contract: `.system` is "sent once". A stray second system turn is
        // IGNORED, not concatenated — joining would double the persona in AFM's
        // `instructions:` on iteration ≥2 (the transcript is re-sent whole).
        let firstWins = AFMToolPrompt.systemInstructions(from: [.system("A."), .user("hi"), .system("B.")])
        #expect(firstWins == "A.")
    }

    @Test("the native session's body (no text catalogue) never points at a list that isn't there")
    func nativeBodyHasNoPhantomCatalogue() {
        let body = AFMToolPrompt.render(messages: [.user("What time is it?")], tools: [])
        #expect(!body.contains("Available tools:"))
        #expect(!body.contains("listed above"))
        // The push to actually USE tools survives without the catalogue.
        #expect(body.contains("yours to USE"))
    }

    @Test("a transcript that records the model's own turns renders each call before its result")
    func nativeTranscriptPairsCallsWithResults() {
        // The native session's bookkeeping: what the agent sent, then what the
        // model generated, then the next delta. Without recordGenerated the body
        // showed "Result from datetime" with no call that asked for it (#397).
        var transcript = ToolTurnTranscript()
        transcript.recordSent([.system("persona"), .user("What day is it?")])
        transcript.recordGenerated(.toolCalls([
            ParsedToolCall(name: "datetime", arguments: [AFMToolMapping.argumentKey: .string("today")]),
        ]))
        transcript.recordSent([.toolResult(name: "datetime", output: "Tuesday 22 September")])

        let body = AFMToolPrompt.render(messages: transcript.full, tools: [])
        let call = body.range(of: "Assistant called datetime(today)")
        let result = body.range(of: "Result from datetime: Tuesday 22 September")
        #expect(call != nil)
        #expect(result != nil)
        if let call, let result { #expect(call.lowerBound < result.lowerBound) }
        #expect(!body.contains("persona")) // .system lifts to instructions, never the body
    }
}
