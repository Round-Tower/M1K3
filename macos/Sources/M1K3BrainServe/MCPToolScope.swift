//
//  MCPToolScope.swift
//  M1K3BrainServe
//
//  The second consent tier for tool palettes (CONTEXT_TOOLS_PLAN P2, built at
//  last): which MCP tools a surface may serve. `.loopback` is today's full
//  local surface, untouched. `.lan` is Kev's 2026-08-19 ruling — the MCP
//  surface reachable by PAIRED devices — scoped to read/ask tools by an
//  ALLOWLIST: write, delete, voice, and link-opening tools are excluded by
//  default and are never silently inherited (audit N4's "no silent widening"
//  applied to tools). A new tool added to the registry is LAN-invisible until
//  someone consciously adds it here.
//
//  Signed: Kev + claude-fable-5, 2026-08-19, Confidence 0.9 (pure allowlist,
//  TDD'd; the exclusion rationale per tool is in the test file). Prior:
//  docs/CONTEXT_TOOLS_PLAN.md P2 + Kev's ruling.
//

import Foundation
import M1K3MCPKit

public enum MCPToolScope: Sendable, Equatable {
    /// The in-app loopback server — full palette, exactly as today.
    case loopback
    /// A paired LAN device. Read/ask only.
    case lan

    /// The LAN allowlist. Deliberately an ALLOWlist: unknown/new tools are
    /// excluded until named here.
    ///
    /// ⚠️ Named equivalence, not a surprise (2026-08-19 audit, finding 2):
    /// `ask_m1k3` runs the SAME agent loop as loopback — when the Settings
    /// web-search toggle is on, an answer may fetch the web from the Mac.
    /// That reach is governed by the existing web consent toggle, identical
    /// to loopback; it is stated in the spec (§2) and the Settings footer
    /// rather than silently implied by "read tools only".
    public static let lanAllowedTools: Set<String> = [
        "search_knowledge", "list_documents", "get_document", // corpus reads
        // The grounded ask + its job flow. `list_jobs` ships with PR #136
        // (the MCP-async package) — until that merges the name filters to
        // nothing here, which fails closed.
        "ask_m1k3", "get_answer", "list_jobs",
        "get_status", "memory_stats", // status/counters
        "recall_memory", "related_memory", // memory-graph reads
        // EXCLUDED by default (future per-device grants, never inherited):
        // remember/forget_memory (writes to the user's permanent memory),
        // speak/listen/stop_speaking (drives the Mac's speakers + microphone),
        // open_link (drives the Mac's screen).
    ]

    public func allows(_ toolName: String) -> Bool {
        switch self {
        case .loopback: true
        case .lan: Self.lanAllowedTools.contains(toolName)
        }
    }
}

/// Filter a tool-definition list down to a scope — the seam the LAN MCP
/// session factory feeds its registry through. Loopback passes everything
/// through untouched (byte-identical behaviour to today).
public func scopedToolDefinitions(
    _ definitions: [MCPToolDefinition], scope: MCPToolScope
) -> [MCPToolDefinition] {
    definitions.filter { scope.allows($0.tool.name) }
}
