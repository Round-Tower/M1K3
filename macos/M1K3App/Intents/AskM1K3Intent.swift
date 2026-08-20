//
//  AskM1K3Intent.swift
//  M1K3App
//
//  "Ask M1K3" for Siri & Shortcuts — one grounded, cited answer from the local
//  knowledge base, with NO chat window. Quiet by design (openAppWhenRun = false):
//  M1K3 answers in the background since it's normally already resident. Sits on the
//  exact same core as the MCP `ask_m1k3` tool (AppEnvironment.intelligenceAsk) —
//  single-flight, shared canary tripwire — but with its OWN 120s deadline:
//  this path AWAITS the answer directly (no job/poll indirection), so it must
//  not inherit the MCP job path's 600s runaway backstop — a hung generation
//  would hold the single-flight lock for 10 minutes against every surface.
//
//  App-glue (verify-by-launch). Signed: Kev + claude-opus-4-8, 2026-06-17,
//  Confidence 0.78, Prior: Unknown
//
//  Review: Kev + claude-fable-5, 2026-08-19 — a dedicated 120s deadline
//  (deadlineSeconds), NOT the MCP job path's 600s backstop: this path awaits
//  intelligenceAsk directly, so it must not hold the single-flight lock for
//  10 minutes (MCP-async package).
//

import AppIntents
import Foundation // TimeInterval
import M1K3Chat // IntentInput

struct AskM1K3Intent: AppIntent {
    /// Direct-await deadline (pre-2026-08-19 behaviour, kept deliberately):
    /// Siri/Shortcuts callers are waiting on this call.
    static let deadlineSeconds: TimeInterval = 120

    static let title: LocalizedStringResource = "Ask M1K3"
    static let description = IntentDescription(
        "Ask M1K3 a question and get a grounded answer from your local knowledge.",
        categoryName: "Intelligence"
    )
    /// Quiet: answer in the background without bringing the app forward.
    static let openAppWhenRun = false

    @Parameter(title: "Question", requestValueDialog: "What would you like to ask M1K3?")
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask M1K3 \(\.$question)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        do {
            let cleaned = try IntentInput.askQuestion(question)
            let env = try await M1K3IntentSupport.environment()
            let answer = try await env.intelligenceAsk(cleaned, deadline: Self.deadlineSeconds)
            return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
        } catch {
            throw M1K3IntentSupport.surface(error)
        }
    }
}
