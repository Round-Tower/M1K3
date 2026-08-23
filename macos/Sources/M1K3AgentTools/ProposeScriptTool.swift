//
//  ProposeScriptTool.swift
//  M1K3AgentTools
//
//  The inert half of the hands: M1K3 drafts a script and ASKS for it to be
//  installed. The tool owns no UI and writes nothing (the OpenLinkTool
//  pattern) — it validates and hands a ScriptProposal to an injected callback
//  the app routes to a review sheet. Nothing exists on disk, and nothing can
//  run, until the user reads the source and clicks Install; that click is the
//  consent ceremony, which is also why this tool carries NO exclusion class —
//  a web-influenced proposal still has to get past the human.
//
//  Signed: Kev + claude-fable-5, 2026-08-23, Confidence 0.85, Prior: Unknown

import Foundation
import M1K3Agent

/// A drafted script awaiting the user's review.
public struct ScriptProposal: Sendable, Equatable {
    public let name: String
    public let content: String
    public let purpose: String

    public init(name: String, content: String, purpose: String) {
        self.name = name
        self.content = content
        self.purpose = purpose
    }
}

public struct ProposeScriptTool: AgentTool {
    public let name = "propose_script"
    public let description =
        "Draft a script for the user to review and install into M1K3's scripts folder, with "
            + "one-click install-and-run. Use this WHENEVER the user asks you to write, create, or "
            + "make a runnable script (shell/bash/zsh) — call it with the full source instead of "
            + "pasting the script in a code block, so they get a real tool in their kit, not text "
            + "to copy. Nothing runs until they approve it. Keep scripts short, readable, single-purpose."
    public let parameters = [
        ToolParameter(name: "name", description: "file name for the script, e.g. disk_report.sh"),
        ToolParameter(name: "content", description: "the full script source, starting with a shebang"),
        ToolParameter(name: "purpose", description: "one line: what this script does and why"),
    ]

    private let onPropose: @Sendable (ScriptProposal) -> Void

    public init(onPropose: @escaping @Sendable (ScriptProposal) -> Void) {
        self.onPropose = onPropose
    }

    public func execute(input: [String: String]) async throws -> ToolResult {
        let scriptName = (input["name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard ExecuteScriptTool.isValidScriptName(scriptName) else {
            return ToolResult(
                output: "Error: \"\(scriptName)\" isn't a usable script name — plain file name, "
                    + "no spaces, no slashes, not starting with a dot."
            )
        }
        let content = input["content"] ?? ""
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ToolResult(output: "Error: the proposal has no content — include the full script source.")
        }
        let purpose = (input["purpose"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        onPropose(ScriptProposal(name: scriptName, content: content, purpose: purpose))
        return ToolResult(
            output: "Proposed \"\(scriptName)\" for the user's review — nothing runs until they "
                + "install and approve it in M1K3. Tell the user what it does and wait for their decision."
        )
    }
}
