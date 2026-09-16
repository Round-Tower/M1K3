//
//  RecallMemoryIntent.swift
//  M1K3App
//
//  "Recall a memory from M1K3" for Siri & Shortcuts — hybrid recall over the
//  temporal memory graph's atomic facts. Returns matching memories as text.
//  Sits on the same core as the MCP `recall_memory` tool
//  (MemoryToolHandlers.recall).
//
//  App-glue (verify-by-launch). Signed: Kev + claude-opus-4-6, 2026-09-16,
//  Confidence 0.8, Prior: AskM1K3Intent (the established pattern)
//

import AppIntents
import M1K3Chat // IntentInput

struct RecallMemoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Recall Memory from M1K3"
    static let description = IntentDescription(
        "Recall a specific memory from M1K3's private memory graph.",
        categoryName: "Memory"
    )
    static let openAppWhenRun = false

    @Parameter(title: "Query", requestValueDialog: "What memory should M1K3 recall?")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Recall \(\.$query) from M1K3's memory")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        do {
            let cleaned = try IntentInput.recallQuery(query)
            let env = try await M1K3IntentSupport.environment()
            let results = try await env.intelligenceRecallMemory(cleaned)
            return .result(value: results, dialog: IntentDialog(stringLiteral: results))
        } catch {
            throw M1K3IntentSupport.surface(error)
        }
    }
}
