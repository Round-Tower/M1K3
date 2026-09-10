//
//  RecentActivityTool.swift
//  M1K3AgentTools
//
//  "What have we been up to?" — M1K3 reviewing his own recent interactions.
//  Until 2026-09-10 the resident could not read his own week: memories and
//  todos reached him only as passive grounding, and chat titles, visiting
//  agents and heartbeat pulses not at all — while every MCP visitor could ask
//  the server for recall_memory / memory_stats / list_todos. One tool, not
//  three (every extra name costs the small tiers prompt tokens and they
//  already under-call search_knowledge): a window, an optional focus, and a
//  digest with FACT sections that are byte-stable and INSIGHT lines drawn at
//  random from what is true of the week (Kev: "we want variability here, and
//  insight overall").
//
//  Shape rules, each pinned in RecentActivityToolTests:
//  - Titles, memory titles, visitor names and pulse text are UNTRUSTED (a
//    visitor's `remember`, a document-derived chat title, a self-reported
//    clientInfo name): folded to one line, fence markers defanged, and the
//    whole digest rides between DATA fences (the CalendarPeekTool pattern).
//  - Never message bodies, never a visitor's arguments or response text —
//    counts, names, titles and the heartbeat's own narratives only.
//  - `.localSensitive`: it reads sensitive local data, so within a turn it is
//    exclusive with the network tools (P1 of the context-tools charter) — a
//    week of memory titles must not ride into web_search in the same turn.
//  - Distillation-tainted (DistillationTaint): a review of the week must not
//    distil back into the week as memory-graph facts.
//  - The reader is a seam (`ActivityReading`); the app's live reader gathers
//    from the five stores, the warm variant reads nothing.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-10, Confidence 0.85 (pure digest +
//  parsers pinned red-first; the live reader is verify-by-launch on the Mac).
//  Prior: none (new file, patterned on CalendarPeekTool + SystemStatusTool).
//

import Foundation
import M1K3Agent
import M1K3Inference

// MARK: - The tool

public struct RecentActivityTool: AgentTool {
    public let name = "recent_activity"
    public let description =
        "Review what happened lately on \(HostPlatform.thisDevice): recent chats, new memories, visiting "
            + "agents, heartbeat pulses and todos. Argument: the window — today, yesterday, or N days "
            + "(default: the last 7 days)."
    public let parameters = [
        ToolParameter(name: "window", description: "today, yesterday, N days, or week (default)", isRequired: false),
        ToolParameter(
            name: "focus", description: "narrow to one of: chats, memories, visitors, heartbeat, todos",
            isRequired: false
        ),
    ]
    public let exclusionClass: ToolExclusionClass? = .localSensitive

    private let reader: any ActivityReading
    private let now: @Sendable () -> Date
    private let calendar: Calendar

    public init(
        reader: any ActivityReading,
        now: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = .current
    ) {
        self.reader = reader
        self.now = now
        self.calendar = calendar
    }

    public func execute(input: [String: String]) async throws -> ToolResult {
        let window = ActivityWindow.parse(input["window"] ?? "")
        let focus = ActivityFocus.parse(input["focus"] ?? "")
        let at = now()
        let bounds = window.bounds(now: at, calendar: calendar)
        let snapshot: ActivitySnapshot
        do {
            snapshot = try await reader.snapshot(from: bounds.start, to: bounds.end)
        } catch {
            return ToolResult(output: "Error: could not read the activity stores (\(error)).")
        }
        var generator = SystemRandomNumberGenerator()
        return ToolResult(output: ActivityDigest.render(
            snapshot, window: window, focus: focus, now: at, calendar: calendar, using: &generator
        ))
    }
}
