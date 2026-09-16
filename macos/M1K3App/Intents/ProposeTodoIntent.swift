//
//  ProposeTodoIntent.swift
//  M1K3App
//
//  "Add a todo with M1K3" for Siri & Shortcuts — proposes a new item onto the
//  user's todo list (pending until they accept). Sits on the same core as the
//  MCP `propose_todo` tool (TodoToolHandlers.propose).
//
//  App-glue (verify-by-launch). Signed: Kev + claude-opus-4-6, 2026-09-16,
//  Confidence 0.8, Prior: RememberWithM1K3Intent (parameter pattern)
//

import AppIntents
import M1K3Chat // IntentInput

struct ProposeTodoIntent: AppIntent {
    static let title: LocalizedStringResource = "Add a Todo with M1K3"
    static let description = IntentDescription(
        "Propose a new item for M1K3's todo list.",
        categoryName: "Todos"
    )
    static let openAppWhenRun = false

    @Parameter(title: "Title", requestValueDialog: "What's the todo?")
    var todoTitle: String

    @Parameter(title: "Note")
    var note: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$todoTitle) to M1K3's todos") {
            \.$note
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            let cleaned = try IntentInput.todoTitle(todoTitle)
            let env = try await M1K3IntentSupport.environment()
            let confirmation = try await env.intelligenceProposeTodo(
                title: cleaned,
                note: note?.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            return .result(dialog: IntentDialog(stringLiteral: confirmation))
        } catch {
            throw M1K3IntentSupport.surface(error)
        }
    }
}
