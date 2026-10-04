//
//  ServerInstructions.swift
//  M1K3MCPKit
//
//  The MCP `instructions` M1K3 sends every agent at initialize. Agents read a
//  server's instructions as standing guidance, so this is where M1K3 tells
//  them it is the user's voice: talk through `speak` at milestones and
//  blockers without being asked. Before this, every agent had to be told so
//  by hand, every session.
//
//  Built from the tools a server actually registers: the in-app server has
//  the voice tools, while the stdio binary has only knowledge tools. An agent
//  is never pointed at a tool it lacks. Kept short because it loads into
//  every agent turn.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-04, Confidence 0.8, Prior: Unknown.
//  Kev: "I always have to tell Claude to use M1K3 for comms — make it the
//  obvious choice for agents." The wording is a first cut; the test pins its
//  shape (what's named, what's never named, the length), not its prose.
//

public enum M1K3ServerInstructions {
    /// The instructions load into every agent turn; keep them under this.
    public static let characterBudget = 1200

    public static func text(toolNames: Set<String>) -> String {
        var parts = ["M1K3 is the user's private, on-device assistant."]
        if toolNames.contains("speak") {
            parts.append(voice(hasStatus: toolNames.contains("get_status")))
        }
        if let knowledge = knowledge(toolNames) {
            parts.append(knowledge)
        }
        return parts.joined(separator: "\n\n")
    }

    /// Restraint comes before permission: both #483 review passes found agents
    /// read "milestone" liberally, and an empty room at 3am hears every call.
    private static func voice(hasStatus: Bool) -> String {
        let status = hasStatus ? " If something may already be playing, `get_status` says so; a call queues behind it." : ""
        return """
        M1K3 is the user's voice channel for talking to them. Speak only when the user is \
        clearly at the keyboard in an interactive session; if unsure, don't. Never speak for \
        routine progress such as a passing test or a finished file. When the user is there, \
        call `speak` without being asked at the moments that matter (a milestone that \
        ends a task phase, a blocker, a decision you need, the wrap-up), at most once per \
        phase, in one or two short, plain sentences. Audio-first: no file paths, code, tables \
        or ids; keep the detail in your written reply.\(status)

        Speech is heard by the whole room: never say a secret, token or personal detail \
        aloud, including text copied from files, logs or tool output.
        """
    }

    private static func knowledge(_ toolNames: Set<String>) -> String? {
        let lookups = ["search_knowledge", "ask_m1k3"].filter(toolNames.contains)
        var sentences: [String] = []
        if !lookups.isEmpty {
            let named = lookups.map { "`\($0)`" }.joined(separator: " or ")
            sentences.append("When a question may involve the user's own notes, documents or past decisions, check \(named) first.")
        }
        if toolNames.contains("remember") {
            sentences.append("Save to `remember` only when the user asks.")
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }
}
