//
//  AFMToolPicker.swift
//  M1K3Inference
//
//  Mini as a constrained tool picker (router-invoked tools, 2026-09-26). One
//  short guided generation names ONE tool from a menu, plus the query it should
//  get; the app then runs that tool itself (M1K3Chat's ToolDispatch) instead of
//  Mini deciding, calling and synthesising in an agent loop (~50 s a tool turn).
//  Measured in scratch/dispatch-spike: a pick takes ~1.2 s on Mini. With the router
//  in front and the final prompt, 36 of 38 read-only tool asks in the real fixtures
//  land on the right tool (37/38 before the web line's "newest or latest" edit; the
//  first scoring, 37/42, also counted script and deep-dive asks, which correctly take
//  the agent), and 53 of 58 on 120 independent prompts never used for tuning.
//
//  The choice list is static (the macOS 26.0 floor has no dynamic object schema):
//  it names every dispatchable tool plus `none` and `action`. The per-turn menu in
//  the instructions lists only the tools on offer, and ToolDispatch refuses a pick
//  outside this turn's palette, so a static list can't reach a withheld tool.
//  `ToolPickerChoicesTests` pins these names to ToolDispatch's.
//
//  Signed: Kev + claude-opus-5-5, 2026-09-26, Confidence 0.75 (the pick's accuracy
//  is measured offline; the live gain is the eval arm's to show). Prior: Unknown.
//  Review: Kev + claude-opus-5-5, 2026-10-07 — `pickTools`: with chains on (`toolChain`) the pick
//  is a second schema with an `also` slot (a read-only tool or none), so one guided generation can
//  name two tools ("the weather and my calendar"). The single-tool schema is untouched: the 36/38
//  pick only changes when the flag is on, and the arm measures that first. Confidence 0.7.
//

import Foundation
@_weakLinked import FoundationModels

/// A brain that can name one tool for a message with a short constrained generation.
public protocol ToolPicking: Sendable {
    /// `instructions`: the picker's rules and the menu of tools on offer.
    func pickTool(message: String, instructions: String) async throws -> (tool: String, query: String)

    /// The pick and, when the message plainly needs a second read-only tool, that one too
    /// (first is the pick). A picker that can't chain names one.
    func pickTools(message: String, instructions: String) async throws -> [(tool: String, query: String)]
}

public extension ToolPicking {
    func pickTools(message: String, instructions: String) async throws -> [(tool: String, query: String)] {
        try await [pickTool(message: message, instructions: instructions)]
    }
}

public enum AFMToolPicker {
    public static let choices: [String] = [
        "battery_status", "calendar_peek", "current_location", "datetime", "fetch_page", "list_documents",
        "lookup_fact", "recent_activity", "search_knowledge", "system_status", "web_search", "none", "action",
    ]

    /// A chain's second tool: read-only tools or none, never `action` (an action is the agent's).
    public static let alsoChoices: [String] = choices.filter { $0 != "action" }
}

@Generable
private struct AFMToolPick {
    @Guide(description: "The one tool this message needs; none when no tool is needed; action for anything that acts on the Mac", .anyOf(AFMToolPicker.choices))
    var tool: String
    @Guide(description: "For a search or lookup: the query to use. For fetch_page: the URL. Otherwise empty.")
    var query: String
}

@Generable
private struct AFMToolChainPick {
    @Guide(description: "The one tool this message needs first; none when no tool is needed; action for anything that acts on the Mac", .anyOf(AFMToolPicker.choices))
    var tool: String
    @Guide(description: "For a search or lookup: the query to use. For fetch_page: the URL. Otherwise empty.")
    var query: String
    @Guide(description: "A second, different tool only when the message plainly asks for two separate things; otherwise none", .anyOf(AFMToolPicker.alsoChoices))
    var also: String
    @Guide(description: "The second tool's query or URL, if it needs one. Otherwise empty.")
    var alsoQuery: String
}

extension AppleFoundationModelsProvider: ToolPicking {
    public func pickTool(message: String, instructions: String) async throws -> (tool: String, query: String) {
        guard isAvailable else { throw InferenceError.providerUnavailable("Apple Intelligence is not ready") }
        // A fresh session with the picker's own instructions: it never takes or
        // spoils the chat prewarm slot, and it carries no persona.
        let session = LanguageModelSession(instructions: instructions)
        let pick = try await session.respond(
            to: message, generating: AFMToolPick.self, options: GenerationOptions(temperature: 0)
        ).content
        return (pick.tool, pick.query)
    }

    public func pickTools(message: String, instructions: String) async throws -> [(tool: String, query: String)] {
        guard isAvailable else { throw InferenceError.providerUnavailable("Apple Intelligence is not ready") }
        let session = LanguageModelSession(instructions: instructions)
        let pick = try await session.respond(
            to: message, generating: AFMToolChainPick.self, options: GenerationOptions(temperature: 0)
        ).content
        var picks: [(tool: String, query: String)] = [(tool: pick.tool, query: pick.query)]
        if pick.also != "none", pick.also != pick.tool {
            picks.append((tool: pick.also, query: pick.alsoQuery))
        }
        return picks
    }
}
