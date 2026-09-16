//
//  ListTodosIntent.swift
//  M1K3App
//
//  "List M1K3's todos" for Siri & Shortcuts — reads the user's todo list as
//  M1K3 holds it. Returns open items as text. Sits on the same core as the MCP
//  `list_todos` tool (TodoToolHandlers.list).
//
//  App-glue (verify-by-launch). Signed: Kev + claude-opus-4-6, 2026-09-16,
//  Confidence 0.8, Prior: AskM1K3Intent (the established pattern)
//

import AppIntents

struct ListTodosIntent: AppIntent {
    static let title: LocalizedStringResource = "List M1K3's Todos"
    static let description = IntentDescription(
        "List the open items on M1K3's todo list.",
        categoryName: "Todos"
    )
    static let openAppWhenRun = false

    static var parameterSummary: some ParameterSummary {
        Summary("List M1K3's todos")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        do {
            let env = try await M1K3IntentSupport.environment()
            let results = try await env.intelligenceListTodos()
            return .result(value: results, dialog: IntentDialog(stringLiteral: results))
        } catch {
            throw M1K3IntentSupport.surface(error)
        }
    }
}
