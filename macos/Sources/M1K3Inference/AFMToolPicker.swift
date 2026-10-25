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
//  Review: Kev + claude-fable-5.1, 2026-10-09 — chainPicks promotes `also` when the head is none (#512).
//  Review: Kev + claude-fable-5.1, 2026-10-25 — the pick's generation is one helper (`pick`/`pickChain`) over any
//  session, and `PrewarmedToolPicker` serves it a session prewarmed for the menu (the arm behind
//  `-pickerPrewarm YES`): the Release baseline's picker route paid ~3 s a turn for a cold session. Confidence 0.7
//  (the generic slot and the flag defaults are pinned; the wrapper itself needs Apple Intelligence, so what a
//  warm picker session buys is the arm eval's to show).
//  Review: Kev + claude-fable-5.1, 2026-10-25 (later) — the first measurement (−18 % / −12 %) ran each pick
//  against its own re-arm (`store` before `respond`) and warmed the cold path twice; now the cold pick runs on
//  an unwarmed session and the re-arm follows the pick (`defer`). Confidence 0.7, re-measured in the PR.

import Foundation
@_weakLinked import FoundationModels
import OSLog

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
    /// The route's category, so a pick's session warmth reads beside its `tool pick:` line.
    static let log = Logger(subsystem: "app.m1k3", category: "route")

    public static let choices: [String] = [
        "battery_status", "calendar_peek", "current_location", "datetime", "fetch_page", "list_documents",
        "lookup_fact", "recent_activity", "search_knowledge", "system_status", "web_search", "none", "action",
    ]

    /// A chain's second tool: read-only tools or none, never `action` (an action is the agent's).
    public static let alsoChoices: [String] = choices.filter { $0 != "action" }

    /// The picks a chain schema's answer stands for. `also` repeating the head, or none,
    /// adds nothing; a `none` head with a real `also` IS that tool (#510 review 3: the
    /// turn went plain and the tool it named never ran).
    public static func chainPicks(tool: String, query: String, also: String, alsoQuery: String) -> [(tool: String, query: String)] {
        let second: (tool: String, query: String)? = also == "none" || also == tool ? nil : (tool: also, query: alsoQuery)
        if tool == "none", let second { return [second] }
        return [(tool: tool, query: query)] + (second.map { [$0] } ?? [])
    }
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
        return try await AFMToolPicker.pick(session: LanguageModelSession(instructions: instructions), message: message)
    }

    public func pickTools(message: String, instructions: String) async throws -> [(tool: String, query: String)] {
        guard isAvailable else { throw InferenceError.providerUnavailable("Apple Intelligence is not ready") }
        let session = LanguageModelSession(instructions: instructions)
        return try await AFMToolPicker.pickChain(session: session, message: message)
    }
}

extension AFMToolPicker {
    /// One guided generation naming a tool, on whatever session the caller brings (fresh or prewarmed).
    static func pick(session: LanguageModelSession, message: String) async throws -> (tool: String, query: String) {
        let pick = try await session.respond(
            to: message, generating: AFMToolPick.self, options: GenerationOptions(temperature: 0)
        ).content
        return (pick.tool, pick.query)
    }

    static func pickChain(
        session: LanguageModelSession, message: String
    ) async throws -> [(tool: String, query: String)] {
        let pick = try await session.respond(
            to: message, generating: AFMToolChainPick.self, options: GenerationOptions(temperature: 0)
        ).content
        return chainPicks(tool: pick.tool, query: pick.query, also: pick.also, alsoQuery: pick.alsoQuery)
    }
}

/// The same pick on a session prewarmed for the menu (the A/B arm, 2026-10-25). The Release baseline put the
/// picker route's first token at 3.8 s (Lil) / 5.1 s (Big) against 0.65 / 1.8 s on the chat route, on half the
/// trials, and the timed pick read 3.0 s: a fresh `LanguageModelSession(instructions:)` per turn, processed cold.
/// Here the first pick on a menu is cold too, and every pick re-arms a session for its menu
/// (`prewarm()` — the framework loads and processes the instructions ahead), so the next pick on the same
/// menu starts warm. One slot (`PrewarmSlot`, keyed by the exact instructions): a palette change is a miss,
/// never a stale menu. The picker's session never touches the chat prewarm slot.
public final class PrewarmedToolPicker: ToolPicking, @unchecked Sendable {
    private let base: AppleFoundationModelsProvider
    private let slot = PrewarmSlot<LanguageModelSession>()
    /// The second arm (`-pickerPrewarmPrefix YES`): the rules and menu ride as the PROMPT's prefix, warmed with
    /// `prewarm(promptPrefix:)`, under a one-line instruction. The 2026-09-14 probe found instructions-only
    /// prewarm bought ~7 %, a processed prompt prefix ~3×; the first arm (instructions warmed) read −18 %.
    private let prefixMode: Bool

    /// What the prefix arm's session is instructed with; the rules and menu arrive in the prompt instead.
    static let prefixInstructions =
        "You name one tool for a message, following the rules and menu the message opens with."

    public init(base: AppleFoundationModelsProvider, prefixMode: Bool = false) {
        self.base = base
        self.prefixMode = prefixMode
    }

    /// Whether a warm session is waiting (diagnostics).
    public var isArmed: Bool {
        slot.isArmed
    }

    public func pickTool(message: String, instructions: String) async throws -> (tool: String, query: String) {
        let session = try session(for: instructions)
        defer { arm(instructions) }
        return try await AFMToolPicker.pick(session: session, message: prompt(message, instructions))
    }

    public func pickTools(message: String, instructions: String) async throws -> [(tool: String, query: String)] {
        let session = try session(for: instructions)
        defer { arm(instructions) }
        return try await AFMToolPicker.pickChain(session: session, message: prompt(message, instructions))
    }

    /// The prefix arm's prompt opens with the warmed prefix byte for byte, so the framework skips its prefill.
    private func prompt(_ message: String, _ instructions: String) -> String {
        prefixMode ? instructions + "\n\n" + message : message
    }

    /// A session shaped for the arm, not yet warmed: the cold pick runs on it as the baseline does.
    private func coldSession(_ instructions: String) -> LanguageModelSession {
        LanguageModelSession(instructions: prefixMode ? Self.prefixInstructions : instructions)
    }

    /// The same shape, warming for the next pick on this menu.
    private func warmSession(_ instructions: String) -> LanguageModelSession {
        let session = coldSession(instructions)
        if prefixMode {
            session.prewarm(promptPrefix: Prompt(instructions + "\n\n"))
        } else {
            session.prewarm()
        }
        return session
    }

    /// The warm session for this menu when one waits (the slot drops a mismatch), else a cold one.
    private func session(for instructions: String) throws -> LanguageModelSession {
        guard base.isAvailable else { throw InferenceError.providerUnavailable("Apple Intelligence is not ready") }
        let taken = slot.take(matching: instructions)
        // Params only inside the Logger autoclosure (the swiftformat landmine: never a member).
        let warmth = taken == nil ? "cold" : "warm"
        let shape = prefixMode ? "prefix" : "instructions"
        AFMToolPicker.log.notice("tool picker session: \(warmth, privacy: .public) (\(shape, privacy: .public))")
        return taken ?? coldSession(instructions)
    }

    /// Re-arms the slot for the NEXT pick on this menu — after the pick returns, so the warm-up never shares
    /// the model with the pick being timed (the first measurement did, and the cold path warmed twice).
    private func arm(_ instructions: String) {
        slot.store(warmSession(instructions), key: instructions)
        AFMToolPicker.log.notice("tool picker session: next armed")
    }
}
