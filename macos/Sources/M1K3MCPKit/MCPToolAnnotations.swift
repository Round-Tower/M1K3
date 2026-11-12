//
//  MCPToolAnnotations.swift
//  M1K3MCPKit
//
//  What each MCP tool tells a client about itself beyond its description: a short
//  title, whether it only reads, whether a change it makes can destroy something,
//  and whether it reaches beyond this Mac. Clients use these to decide what to ask
//  the person before a call, and directories that list MCP servers require them.
//
//  One table, applied where the registry lists its tools, so a tool defined in any
//  file cannot be served without them and the claims sit in one place to review.
//  They are HINTS a client may show a person: keep each one true of what the
//  handler does, and change the entry in the same commit as the handler.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-12, Confidence 0.8 (each entry read
//  against its tool's description; `ask_m1k3` is marked as changing things and
//  open-world because the brain behind it can run tools). Prior: Unknown.
//  Context: Kev, 2026-11-12, on listing M1K3 for Claude users: "Let's go it pal,
//  could give us some traction". Claude's directory asks that every tool carry a
//  title and the applicable read-only or destructive hint.

import MCP

public enum MCPToolAnnotations {
    /// What a call does to the world.
    public enum Effect: Sendable {
        /// Reads only.
        case reads
        /// Changes something, without destroying anything (a new memory, speech aloud, an open mic).
        case changes
        /// Can remove something the person kept.
        case destroys
    }

    public struct Entry: Sendable {
        public let title: String
        public let effect: Effect
        /// Reaches beyond this Mac: a network service, or whatever a link opens.
        public let openWorld: Bool

        init(_ title: String, _ effect: Effect, openWorld: Bool = false) {
            self.title = title
            self.effect = effect
            self.openWorld = openWorld
        }
    }

    /// Every tool M1K3 serves, by name.
    public static let table: [String: Entry] = [
        // Knowledge and documents
        "search_knowledge": Entry("Search knowledge", .reads),
        "list_documents": Entry("List documents", .reads),
        "get_document": Entry("Read a document", .reads),
        // Memory
        "remember": Entry("Remember", .changes),
        "recall_memory": Entry("Recall memories", .reads),
        "related_memory": Entry("Related memories", .reads),
        "memory_stats": Entry("Memory stats", .reads),
        "forget_memory": Entry("Forget a memory", .destroys),
        // The brain
        "ask_m1k3": Entry("Ask M1K3", .changes, openWorld: true),
        "get_answer": Entry("Get an answer", .reads),
        "list_jobs": Entry("List questions asked", .reads),
        "ask_private_cloud": Entry("Ask Private Cloud Compute", .changes, openWorld: true),
        // Voice
        "speak": Entry("Speak aloud", .changes),
        "stop_speaking": Entry("Stop speaking", .changes),
        "listen": Entry("Listen", .changes),
        "get_status": Entry("M1K3 status", .reads),
        // Todos and links
        "propose_todo": Entry("Propose a todo", .changes),
        "list_todos": Entry("List todos", .reads),
        "open_link": Entry("Open a link", .changes, openWorld: true),
    ]

    /// `tool` with its entry's annotations. A tool that brought its own, or that the table does
    /// not know, is returned untouched.
    public static func annotated(_ tool: Tool) -> Tool {
        guard tool.annotations.isEmpty, tool.title == nil, let entry = table[tool.name] else { return tool }
        let reads = entry.effect == .reads
        return Tool(
            name: tool.name,
            title: entry.title,
            description: tool.description,
            inputSchema: tool.inputSchema,
            annotations: .init(
                title: entry.title,
                readOnlyHint: reads,
                destructiveHint: reads ? nil : entry.effect == .destroys,
                openWorldHint: entry.openWorld
            ),
            outputSchema: tool.outputSchema,
            icons: tool.icons,
            _meta: tool._meta
        )
    }
}
