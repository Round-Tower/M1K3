//
//  ChatEvalStubPalette.swift
//  M1K3Eval
//
//  The stub tool palette every ChatEval tool-use run offers the brain. Pure
//  data, so the fixtures can be pinned against it: a tool-use fixture that
//  names a tool absent from this list is unpassable for EVERY brain — which is
//  exactly what happened to `tool-read-site` for two months (issue #233).
//
//  Signed: Kev + claude-fable-5.1, 2026-09-10, Confidence 0.85 (lifted out of
//  ChatEvalStage so a test in this target can see it; per-tool parameters
//  replace the one hard-coded `query: "the input"` every stub used to declare,
//  which left no way to express a `url`- or `topic`-taking tool). Review 2 on
//  #263 caught two names that still didn't match production (datetime's
//  ignored `query`, lookup_fact's `topic`) — fixed to the real schemas.
//  Prior: Unknown (the four original specs were ChatEvalStage's, 2026-06).
//  Review: Kev + claude-fable-5.1, 2026-09-10 — recent_activity stub (parameter `window`) so the new tool is scored
//  from day one; the AFM arm gained a matching @Generable shape (ChatEvalStage).
//

import Foundation

/// The single parameter a stub advertises, if any — the NAME the production
/// tool declares (datetime: a required-but-ignored `query`; lookup_fact:
/// `topic`; fetch_page: `url`), so PromptSizeStage measures the real schema
/// cost and the AFM arm asks for the field the real tool would.
public struct ChatEvalStubParameter: Sendable, Equatable {
    public let name: String
    public let description: String

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

/// One probed tool. `canned` is the TERMINAL output (resolves the request so
/// the model concludes after one call); `hardCanned` is the NON-RESOLVING
/// output for the Phase-15 hard case (does the brain survive a result that
/// doesn't answer, or auto-loop into the context-overflow melt?). `{input}` in
/// either template is replaced with the argument the brain passed.
public struct ChatEvalStubSpec: Sendable, Equatable {
    public let name: String
    public let description: String
    public let parameter: ChatEvalStubParameter?
    public let canned: String
    public let hardCanned: String

    public init(
        name: String, description: String, parameter: ChatEvalStubParameter?,
        canned: String, hardCanned: String
    ) {
        self.name = name
        self.description = description
        self.parameter = parameter
        self.canned = canned
        self.hardCanned = hardCanned
    }

    /// The output the stub returns for `input` — terminal or hard.
    public func output(for input: String, hard: Bool) -> String {
        (hard ? hardCanned : canned).replacingOccurrences(of: "{input}", with: input)
    }
}

public enum ChatEvalStubPalette {
    /// Shared by BOTH tool paths so AFM-native and ReAct-floor runs offer the
    /// model the exact same palette — only the calling convention differs.
    public static let specs: [ChatEvalStubSpec] = [
        ChatEvalStubSpec(
            name: "datetime", description: "Get the current date and time on this Mac. Argument: optional, ignored.",
            // Production DateTimeTool declares a required-but-ignored `query`
            // (review 2 on #263) — the eval pays the same schema cost it does.
            parameter: ChatEvalStubParameter(name: "query", description: "ignored"),
            canned: "It is 12:00 on Saturday 14 June 2026. (Complete — no further lookup needed.)",
            hardCanned: "It is 12:00 on Saturday 14 June 2026. (Complete — no further lookup needed.)"
        ),
        ChatEvalStubSpec(
            name: "search_knowledge",
            description: "Search the user's OWN saved notes, memories and imported documents.",
            parameter: ChatEvalStubParameter(name: "query", description: "what to look for"),
            canned: "Search complete. Found the relevant note for '{input}': the user recorded the answer here. "
                + "This fully resolves the request — no further search needed.",
            hardCanned: "No matching notes found for '{input}'. The personal store has nothing on this."
        ),
        ChatEvalStubSpec(
            name: "lookup_fact", description: "Look up an encyclopedic fact from a reference source (Wikipedia).",
            // Production WikipediaTool names its parameter `topic`, not `query`.
            parameter: ChatEvalStubParameter(name: "topic", description: "the fact to look up"),
            canned: "Reference lookup complete for '{input}': the fact was found and is given here. No further lookup needed.",
            hardCanned: ""
        ),
        ChatEvalStubSpec(
            name: "web_search", description: "Search the LIVE web for current, up-to-the-minute news and information.",
            parameter: ChatEvalStubParameter(name: "query", description: "the search terms"),
            canned: "Web search complete for '{input}': the top current result is given here. No further search needed.",
            hardCanned: "Top results for '{input}': [1] example.com/a  [2] example.com/b  [3] example.com/c — "
                + "open a result to read the full answer."
        ),
        // #233: the production palette has fetch_page (read a URL the user gave
        // you) and the fixtures asked for it, but no stub existed — so
        // tool-read-site failed for every brain and was counted in every
        // published tool-use cell. The canned brief mirrors what the real tool
        // returns (PageBrief: title + description + the site's own words).
        ChatEvalStubSpec(
            name: "fetch_page",
            description: "Fetch and READ a web page the user named — a URL or a bare domain (https assumed). "
                + "Use this, not web_search, when the user gives you the site.",
            parameter: ChatEvalStubParameter(name: "url", description: "the page URL, or a bare domain"),
            canned: "Page: M1K3 for Mac — Your AI. Your Mac. Nothing leaves. ({input}) "
                + "M1K3 is a fully on-device AI companion for the Mac: three brains, voice in and out, "
                + "consent-gated memory, and nothing sent to a server. (Complete — describe THIS page.)",
            hardCanned: "Could not fetch {input}: the connection was refused. Do not describe the page."
        ),
        // 2026-09-10: recent_activity — the resident reviewing his own week.
        // Mirrors the production digest's first line + section shape.
        ChatEvalStubSpec(
            name: "recent_activity",
            description: "Review what happened lately on this Mac: recent chats, new memories, visiting "
                + "agents, heartbeat pulses and todos. Argument: the window — today, yesterday, or N days "
                + "(default: the last 7 days).",
            parameter: ChatEvalStubParameter(name: "window", description: "today, yesterday, N days, or week (default)"),
            canned: "Recent activity on this Mac — {input}. Chats: 3 touched, 3 titled. \"Cork Jazz Festival "
                + "2026 Lineup\" (yesterday), \"Quiet code night\" (Tuesday), \"Sourdough starter\" (Monday). "
                + "Memories: 2 new (2 fact). Visitors: 12 calls from Claude Code — speak ×8, remember ×4. "
                + "Heartbeat: 3 pulses. Todos: 1 open. (Complete — summarise THIS digest.)",
            hardCanned: "Recent activity on this Mac — {input}. Chats: none. Memories: none. Visitors: none. "
                + "Heartbeat: no pulses. Todos: none open. A quiet stretch — nothing to review."
        ),
    ]

    /// Every tool name a tool-use fixture may legally require.
    public static var names: [String] {
        specs.map(\.name)
    }
}
