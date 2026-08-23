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

import Foundation

public enum DistillationTaint {
    /// Tools whose output must never flow into distilled memory.
    public static let taintedToolNames: Set<String> = ["execute_script"]

    public static func isTainted(toolsUsed: [String]?) -> Bool {
        guard let toolsUsed else { return false }
        return !taintedToolNames.isDisjoint(with: toolsUsed)
    }
}
