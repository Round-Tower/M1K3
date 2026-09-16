//
//  SearchKnowledgeIntent.swift
//  M1K3App
//
//  "Search M1K3's knowledge" for Siri & Shortcuts — hybrid vector + FTS search
//  across the local RAG corpus, returning ranked results as text. Sits on the
//  same core as the MCP `search_knowledge` tool (KnowledgeMCPTools.searchKnowledge).
//
//  App-glue (verify-by-launch). Signed: Kev + claude-opus-4-6, 2026-09-16,
//  Confidence 0.8, Prior: AskM1K3Intent (the established pattern)
//

import AppIntents
import M1K3Chat // IntentInput

struct SearchKnowledgeIntent: AppIntent {
    static let title: LocalizedStringResource = "Search M1K3's Knowledge"
    static let description = IntentDescription(
        "Search M1K3's local knowledge base for documents, notes, and memories.",
        categoryName: "Knowledge"
    )
    static let openAppWhenRun = false

    @Parameter(title: "Query", requestValueDialog: "What should M1K3 search for?")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Search M1K3's knowledge for \(\.$query)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        do {
            let cleaned = try IntentInput.searchQuery(query)
            let env = try await M1K3IntentSupport.environment()
            let results = try await env.intelligenceSearchKnowledge(cleaned)
            return .result(value: results, dialog: IntentDialog(stringLiteral: results))
        } catch {
            throw M1K3IntentSupport.surface(error)
        }
    }
}
