//
//  LoopbackToolGrants.swift
//  M1K3MCPKit
//
//  What an agent on this Mac may do without asking (#270, Kev's ruling 2026-09-27). Any same-user
//  process can reach the loopback server, and a token in a client config is readable by the same
//  process, so reachability can't be the consent for the tools that hurt most: the microphone,
//  deleting memories, and driving the screen. Each needs a grant the owner turns on in Settings,
//  default OFF; another process can't flip a Settings toggle without Accessibility or container
//  access. A refused call stays listed and answers isError with where to allow it, so the owner's
//  own agents learn why. Every tool is classified here; an unclassified one is refused until
//  someone decides, the `.lan` allowlist's "no silent widening" applied to loopback.
//
//  Signed: Kev + claude-opus-5-5, 2026-09-27, Confidence 0.85 (pure, test-pinned; the gated three
//  are Kev's call after the challenger pass on #270). Prior: none (new file).
//

public struct LoopbackToolGrants: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// `listen`: open the Mac's microphone and hand back what it heard.
    public static let microphone = LoopbackToolGrants(rawValue: 1 << 0)
    /// `forget_memory`: a permanent delete of the owner's memory.
    public static let deleteMemories = LoopbackToolGrants(rawValue: 1 << 1)
    /// `open_link`: put a page on the owner's screen and read it back.
    public static let openLinks = LoopbackToolGrants(rawValue: 1 << 2)
    public static let all: LoopbackToolGrants = [.microphone, .deleteMemories, .openLinks]

    /// The tools a grant gates.
    public static let gatedTools: [String: LoopbackToolGrants] = [
        "listen": .microphone, "forget_memory": .deleteMemories, "open_link": .openLinks,
    ]

    /// Served with no grant. `remember` stays here by the same ruling: agent-written facts
    /// keep their `mcp:remember` provenance instead of waiting for approval.
    public static let servedTools: Set<String> = [
        "search_knowledge", "list_documents", "get_document",
        "speak", "stop_speaking", "get_status",
        "ask_m1k3", "get_answer", "list_jobs", "remember",
        "recall_memory", "related_memory", "memory_stats",
        "list_todos", "propose_todo", // a proposal lands pending; the owner decides
    ]

    /// What a refused call says: what's off, and where the owner turns it on.
    public static func refusal(for tool: String) -> String {
        let what = switch gatedTools[tool] {
        case .microphone?: "use the microphone"
        case .deleteMemories?: "delete memories"
        case .openLinks?: "open links on screen"
        default: "use \(tool)"
        }
        return "Not allowed: M1K3's owner hasn't let agents \(what). "
            + "They can turn it on in M1K3 ▸ Settings ▸ Privacy ▸ MCP server."
    }
}

/// The loopback registry's gate: gated tools run only while `grants()` holds their grant,
/// read on every call so a toggle takes effect at once; served tools pass untouched; an
/// unclassified tool is always refused.
public func grantGatedToolDefinitions(
    _ definitions: [MCPToolDefinition],
    grants: @escaping @Sendable () -> LoopbackToolGrants
) -> [MCPToolDefinition] {
    definitions.map { definition in
        let name = definition.tool.name
        if LoopbackToolGrants.servedTools.contains(name) { return definition }
        let needed = LoopbackToolGrants.gatedTools[name]
        return MCPToolDefinition(tool: definition.tool) { args in
            guard let needed, grants().contains(needed) else {
                throw MCPInputError(LoopbackToolGrants.refusal(for: name))
            }
            return try await definition.handler(args)
        }
    }
}
