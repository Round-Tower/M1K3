//
//  DistillationTaint.swift
//  M1K3Chat
//
//  P3 of the context-tools charter (macos/docs/CONTEXT_TOOLS_PLAN.md): rolling
//  memory distillation runs over persisted assistant text with no provenance,
//  so an answer carrying script output would become a permanent, retrievable
//  memory-graph fact that outlives the consent toggle. Turns served by the
//  named tools are therefore excluded at the transcript→distiller boundary
//  (the quarantine pattern). Names are strings because M1K3Chat cannot link
//  the tool modules (the SelfQueryGate precedent); the tool side pins its name
//  in ExecuteScriptToolTests.contract.
//
//  Signed: Kev + claude-fable-5, 2026-08-23, Confidence 0.9, Prior: Unknown
//  Review: Kev + claude-fable-5.1, 2026-09-10 — recent_activity joins the taint set: its digest is DERIVED from
//  memories / chat titles / visitor names; distilling the answer would feed the next digest (pinned to the tool).

import Foundation

public enum DistillationTaint {
    /// Tools whose output must never flow into distilled memory. The context
    /// senses (calendar_peek, current_location — 2026-09-01) join
    /// execute_script: an event title or a coordinate must not outlive its
    /// consent toggle as a memory-graph fact. battery_status is exempt by
    /// charter (unclassed, harmless).
    /// recent_activity (2026-09-10) joins for a different reason: its digest
    /// is DERIVED from memories, chat titles and visitor names, and distilling
    /// the answer would write meta-facts the next digest then reads as
    /// activity — the heartbeat's own narrative-laundering loop (fix 6).
    public static let taintedToolNames: Set<String> = [
        "execute_script", "calendar_peek", "current_location", "recent_activity",
    ]

    public static func isTainted(toolsUsed: [String]?) -> Bool {
        guard let toolsUsed else { return false }
        return !taintedToolNames.isDisjoint(with: toolsUsed)
    }
}
