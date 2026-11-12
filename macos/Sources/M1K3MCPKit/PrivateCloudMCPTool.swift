//
//  PrivateCloudMCPTool.swift
//  M1K3MCPKit
//
//  `ask_private_cloud`: an agent on this Mac asks Apple's Private Cloud Compute
//  through M1K3 (ADR 0011). The agent's own prompt and optional instructions
//  are ALL that leave: no M1K3 persona, memory, knowledge or tools ride along,
//  and nothing is stored. That is why it is its own tool and not a switch on
//  `ask_m1k3`, whose grounding is the owner's private store.
//
//  Gated: `LoopbackToolGrants.privateCloud`, off until the owner turns it on in
//  Settings ▸ Server. Loopback only (the LAN palette is an allowlist that does
//  not name it), and registered only where a Private Cloud Compute backend
//  exists, so the stdio binary never offers it.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-12, Confidence 0.8 (pinned with a fake
//  handler; the real service is verify-by-launch on a store-lane build),
//  Prior: none (new file).
//

import Foundation
import MCP

public struct PrivateCloudToolHandlers: Sendable {
    /// Ask Private Cloud Compute. Returns the whole answer, or throws a sentence the agent can read
    /// (not available, the limit is reached, the owner has it off).
    public var ask: @Sendable (_ prompt: String, _ instructions: String) async throws -> String

    public init(ask: @escaping @Sendable (_ prompt: String, _ instructions: String) async throws -> String) {
        self.ask = ask
    }
}

public enum PrivateCloudMCPTool {
    public static let name = "ask_private_cloud"
    /// The same ceiling `remember` puts on text: enough for a long document, bounded.
    public static let maxPrompt = MCPInput.maxText
    public static let maxInstructions = MCPInput.maxQuestion
}

public func makePrivateCloudToolDefinitions(handlers: PrivateCloudToolHandlers) -> [MCPToolDefinition] {
    [
        MCPToolDefinition(
            tool: Tool(
                name: PrivateCloudMCPTool.name,
                description: "Ask Apple's Private Cloud Compute, a larger model than the ones on this Mac. "
                    + "NOT local: your prompt and instructions are sent to Apple's Private Cloud Compute "
                    + "(Apple states it keeps nothing), under Apple's acceptable use requirements. Only what you "
                    + "pass is sent, behind one fixed line saying so: nothing from M1K3's "
                    + "memory or knowledge is added, so include any context the answer needs, and send "
                    + "nothing the user would not want to leave this Mac. Each call counts against the "
                    + "user's daily Private Cloud Compute limit. For a private, local answer use ask_m1k3.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "prompt": ["type": "string", "description": "the question or task, with any context it needs"],
                        "instructions": [
                            "type": "string",
                            "description": "optional system instructions for this one call",
                        ],
                    ],
                    "required": ["prompt"],
                ]
            ),
            handler: { args in
                let tool = PrivateCloudMCPTool.name
                let prompt = try MCPInput.text(
                    args, "prompt", tool: tool, maxLength: PrivateCloudMCPTool.maxPrompt
                ) ?? ""
                guard !prompt.isEmpty else { throw MCPVoiceError("\(tool) requires a non-empty prompt") }
                let instructions = try MCPInput.text(
                    args, "instructions", tool: tool, maxLength: PrivateCloudMCPTool.maxInstructions
                ) ?? ""
                let answer = try await handlers.ask(prompt, instructions)
                guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw MCPVoiceError("Private Cloud Compute returned no answer.")
                }
                return answer
            }
        ),
    ]
}
