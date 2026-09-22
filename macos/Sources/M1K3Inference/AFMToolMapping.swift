//
//  AFMToolMapping.swift
//  M1K3Inference
//
//  Phase 15 — the AFM-native tool-calling spike, pure half. Apple Foundation
//  Models speaks no per-model tool dialect (no `<tool_call>` JSON, no Gemma
//  `call:name{…}`); instead it is FORCED, via `respond(generating:)`, to emit a
//  structured `@Generable` decision. The provider extracts that decision's plain
//  fields and hands them here. This file owns two pure, off-device-testable
//  pieces:
//
//    1. `AFMToolMapping.toolTurn(…)` — decision fields → the dialect-free
//       `ToolTurn` the agent already consumes.
//    2. `AFMToolPrompt` — the typed `[ToolMessage]` transcript → the single
//       prompt string `respond(generating:)` takes (AFM has no role-tagged tool
//       template to render into), plus the persona-instructions extraction.
//
//  The map is FAITHFUL, not defensive: a named tool always becomes `.toolCalls`,
//  even an unknown one — `LocalAgent.dispatchCall` already owns the unknown-tool
//  steering + repeat-guard, and forking that here would split the one tested
//  source of truth. The non-melt backstop is the provider's do/catch around the
//  live `respond(generating:)`, not this map.
//
//  Why pure: the one real unknown in the spike is whether AFM reliably EMITS a
//  parseable decision live + survives non-resolving tool results. Translating a
//  well-formed decision is provably correct without the model, so it is pinned
//  here and the live harness is left to test only the genuine unknown.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-15, Confidence 0.9, Prior: Unknown
//  Review: Kev + claude-opus-4-6, 2026-09-16 — image support: on macOS 27+ images
//  ride the Prompt via Attachment(imageURL:) and the "cannot view" text note is
//  suppressed; `imageURLs(from:)` extracts attached URLs for the provider.
//  Confidence now 0.85.

import Foundation

/// Maps the plain fields of AFM's structured `@Generable` tool decision onto the
/// dialect-free `ToolTurn`. Pure: takes scalars (extracted off the decision by
/// the provider), imports no FoundationModels, returns the agent's own type.
public enum AFMToolMapping {
    /// The sole parameter key every current `AgentTool` declares by convention
    /// (`ToolParameterDefinition`). Named here so the mapping can't silently drift
    /// from that contract if a future tool adopts a different argument name.
    static let argumentKey = "query"

    /// A final decision (or one with no actionable tool) becomes a text turn; a
    /// named tool becomes a single call carrying the input under `query` (the arg
    /// key every current `AgentTool` declares). `isFinal` wins over a stray tool
    /// name. The name is NOT validated against a catalogue — see file note.
    public static func toolTurn(
        isFinal: Bool,
        toolName: String,
        toolInput: String,
        finalAnswer: String
    ) -> ToolTurn {
        let tool = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal || tool.isEmpty {
            return .text(finalAnswer.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let input = toolInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return .toolCalls([ParsedToolCall(name: tool, arguments: [argumentKey: .string(input)])])
    }
}

/// Renders the agent's typed transcript into the prompt AFM consumes. The
/// `@Generable` decision schema is injected by `respond(generating:)` itself, so
/// this only supplies the tool catalogue + the conversation; the persona
/// `.system` turn is lifted to the session's `instructions:` separately.
public enum AFMToolPrompt {
    /// The standing-instructions text for the session: the FIRST `.system` turn,
    /// trimmed. `ToolMessage.system` is contractually "sent once, at the start"
    /// (and `StatelessToolTurnSession` re-sends the whole transcript each
    /// iteration, so a join would re-emit / double the persona on iteration ≥2 if
    /// a caller ever added a second system turn). Taking the first keeps AFM's
    /// `instructions:` to one standing persona. `nil` when there is none / it is
    /// blank — the provider then falls back to its own persona closure.
    public static func systemInstructions(from messages: [ToolMessage]) -> String? {
        for message in messages {
            guard case let .system(text) = message else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    /// The prompt body: a tool catalogue, then the conversation (goal, the
    /// model's own prior calls, tool results). `.system` turns are excluded —
    /// they become session instructions, not body text.
    public static func render(messages: [ToolMessage], tools: [ToolDefinition]) -> String {
        var lines: [String] = []

        if !tools.isEmpty {
            lines.append("Available tools:")
            for tool in tools {
                let params = tool.parameters.map(\.name).joined(separator: ", ")
                let paramSuffix = params.isEmpty ? "" : " (args: \(params))"
                lines.append("- \(tool.name): \(tool.description)\(paramSuffix)")
            }
            lines.append("")
        }

        lines.append("Conversation:")
        for message in messages {
            switch message {
            case .system:
                continue // lifted to session instructions
            case let .user(text, images):
                lines.append("User: \(text)")
                // On macOS 27+ images ride the Prompt via Attachment(imageURL:)
                // and never need a text note. On older runtimes, tell the model
                // honestly instead of silently pretending nothing was sent.
                #if compiler(>=6.4)
                    if !images.isEmpty {
                        if #unavailable(macOS 27.0, iOS 27.0, visionOS 27.0) {
                            lines.append("(The user attached \(images.count) image(s) this brain cannot view.)")
                        }
                    }
                #else
                    if !images.isEmpty {
                        lines.append("(The user attached \(images.count) image(s) this brain cannot view.)")
                    }
                #endif
            case let .assistant(text, calls):
                if let text, !text.isEmpty {
                    lines.append("Assistant: \(text)")
                }
                for call in calls {
                    let query = call.arguments["query"]?.stringValue ?? call.stringArguments.values.first ?? ""
                    lines.append("Assistant called \(call.name)(\(query))")
                }
            case let .toolResult(name, output):
                lines.append("Result from \(name): \(output)")
            }
        }

        lines.append("")
        lines.append(
            "Decide the single next step. The tools listed above are yours to USE "
                + "— calling them is your job, not a secret. You do NOT inherently "
                + "know the current date/time, the user's private notes or documents, "
                + "or any live information — CALL the matching tool for those rather "
                + "than saying \"I can't\" or guessing. Never say you lack access to "
                + "something a listed tool provides. Call one tool if it would help "
                + "answer the request; give your final answer only when the tools have "
                + "already given you what you need, or no tool applies."
        )
        return lines.joined(separator: "\n")
    }

    /// Prompt body for the native `Tool` protocol session. Omits the text tool
    /// catalogue (the FM session provides structured definitions via `tools:`)
    /// and the "Decide the single next step" instruction (designed for
    /// `AFMToolDecision` constrained decoding, not native tool calling).
    /// Instead, a short nudge reminds the model to use the tools it was given.
    public static func renderForNativeSession(messages: [ToolMessage]) -> String {
        var lines: [String] = []

        for message in messages {
            switch message {
            case .system:
                continue
            case let .user(text, images):
                lines.append("User: \(text)")
                #if compiler(>=6.4)
                    if !images.isEmpty {
                        if #unavailable(macOS 27.0, iOS 27.0, visionOS 27.0) {
                            lines.append("(The user attached \(images.count) image(s) this brain cannot view.)")
                        }
                    }
                #else
                    if !images.isEmpty {
                        lines.append("(The user attached \(images.count) image(s) this brain cannot view.)")
                    }
                #endif
            case let .assistant(text, calls):
                if let text, !text.isEmpty {
                    lines.append("Assistant: \(text)")
                }
                for call in calls {
                    let query = call.arguments["query"]?.stringValue ?? call.stringArguments.values.first ?? ""
                    lines.append("Assistant called \(call.name)(\(query))")
                }
            case let .toolResult(name, output):
                lines.append("Result from \(name): \(output)")
            }
        }

        lines.append("")
        lines.append(
            "You have tools available. You do NOT know the current date/time, "
                + "the user's private documents, or any live information — ALWAYS "
                + "call the matching tool rather than guessing or saying you can't. "
                + "Answer directly only when no tool applies."
        )
        return lines.joined(separator: "\n")
    }

    /// The image URLs attached to user turns in this transcript, in order.
    /// Empty when the conversation carries no images.
    public static func imageURLs(from messages: [ToolMessage]) -> [URL] {
        messages.compactMap { message -> [URL]? in
            guard case let .user(_, images) = message else { return nil }
            return images.map(\.url)
        }.flatMap { $0 }
    }
}
