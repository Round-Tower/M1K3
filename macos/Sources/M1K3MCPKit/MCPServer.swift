//
//  MCPServer.swift
//  M1K3MCPKit
//
//  The M1K3 MCP server, transport-agnostic: the standalone executable serves
//  the knowledge tools over stdio, the Mac app hosts the same core in-process
//  over localhost HTTP with voice tools added. Tools come from an injectable
//  MCPToolRegistry; this file owns the knowledge definitions + server wiring.
//
//  Store path (the sandbox wrinkle): the app is App-Sandboxed, so it writes to
//  its CONTAINER, not bare ~/Library/Application Support. The stdio server is a
//  plain CLI (unsandboxed) Claude spawns, so it reads the container path
//  directly. Override with M1K3_STORE_PATH; otherwise it uses the container if
//  present and falls back to an unsandboxed store. The in-app server skips all
//  of this — it serves the live KnowledgeStore instance.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.75, Prior: Unknown
//  Review: Kev + claude-fable-5, 2026-06-11 — refactored around MCPToolRegistry
//  for in-process hosting; stdio surface byte-identical (same tools, same
//  handlers, same store resolution). Confidence 0.9.

import Foundation
import M1K3Knowledge
import MCP

/// Resolve the knowledge-store path: explicit env override → app sandbox
/// container (the app's real data) → unsandboxed fallback.
public func resolveStorePath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
    let fm = FileManager.default
    if let override = environment["M1K3_STORE_PATH"], !override.isEmpty {
        return override
    }
    // `homeDirectoryForCurrentUser` is macOS-only; on iOS/visionOS the app's home
    // IS its sandbox container, so NSHomeDirectory() is the right root. macOS keeps
    // byte-identical behaviour (resolves the real user home to find the app container).
    #if os(macOS)
        let home = fm.homeDirectoryForCurrentUser
    #else
        let home = URL(fileURLWithPath: NSHomeDirectory())
    #endif
    let container = home.appendingPathComponent(
        "Library/Containers/app.m1k3/Data/Library/Application Support/M1K3/knowledge.sqlite"
    )
    if fm.fileExists(atPath: container.path) {
        return container.path
    }
    let unsandboxed = home.appendingPathComponent("Library/Application Support/M1K3")
    try? fm.createDirectory(at: unsandboxed, withIntermediateDirectories: true)
    return unsandboxed.appendingPathComponent("knowledge.sqlite").path
}

/// Build an MCP `Server` that lists and dispatches the registry's tools.
public func makeM1K3Server(
    registry: MCPToolRegistry,
    name: String = "m1k3",
    version: String = "0.1.0"
) async -> Server {
    let server = Server(
        name: name,
        version: version,
        capabilities: .init(tools: .init())
    )
    let tools = registry.tools
    await server.withMethodHandler(ListTools.self) { _ in
        ListTools.Result(tools: tools)
    }
    await server.withMethodHandler(CallTool.self) { params in
        await registry.call(name: params.name, arguments: params.arguments)
    }
    return server
}

/// Serve a registry over any transport. Blocks until the transport closes.
public func serve(registry: MCPToolRegistry, transport: some Transport) async throws {
    let server = await makeM1K3Server(registry: registry)
    try await server.start(transport: transport)
    await server.waitUntilCompleted()
}

/// Build + run the M1K3 MCP server over stdio (the standalone executable).
public func runM1K3MCPServer() async throws {
    let store = try KnowledgeStore(path: resolveStorePath())
    let registry = MCPToolRegistry(makeKnowledgeToolDefinitions(store: store))
    try await serve(registry: registry, transport: StdioTransport())
}

// MARK: - Knowledge tool definitions

/// The three knowledge tools over a KnowledgeStore — the stdio server's whole
/// surface, and the read-only half of the in-app server's. The in-app host
/// injects its live embedder so search runs the same two-lane gated hybrid as
/// the agent tool; the stdio binary passes nil (FTS-only, byte-identical to
/// its pre-embedder behaviour).
public func makeKnowledgeToolDefinitions(
    store: KnowledgeStore,
    embedder: (any EmbeddingService)? = nil
) -> [MCPToolDefinition] {
    let tools = KnowledgeMCPTools(store: store, embedder: embedder)
    return [
        MCPToolDefinition(
            tool: Tool(
                name: "search_knowledge",
                description: "Search M1K3's stored knowledge (documents, calls, notes; hybrid retrieval when available). Returns ranked matching chunks.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "the text to search for"],
                        "limit": ["type": "integer", "description": "max results (default 5)"],
                    ],
                    "required": ["query"],
                ]
            ),
            handler: { args in
                let query = try MCPInput.text(args, "query", tool: "search_knowledge", maxLength: MCPInput.maxQuery)
                return try await tools.searchKnowledge(query: query ?? "", limit: intArg(args, "limit") ?? 5)
            }
        ),
        MCPToolDefinition(
            tool: Tool(
                name: "list_documents",
                description: "List the items M1K3 has indexed, with their ids, kinds, and titles.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "limit": ["type": "integer", "description": "max items (default 100)"],
                    ],
                ]
            ),
            handler: { args in
                try tools.listDocuments(limit: intArg(args, "limit") ?? 100)
            }
        ),
        MCPToolDefinition(
            tool: Tool(
                name: "get_document",
                description: "Fetch the text of one indexed item by its id (from list_documents). "
                    + "Returns up to ~6000 characters per call; for longer items, a footer gives the "
                    + "offset to resume from — call again with that offset to page through.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "the document id (UUID)"],
                        "offset": [
                            "type": "integer",
                            "description": "character offset to start from (default 0; see the resume footer)",
                        ],
                    ],
                    "required": ["id"],
                ]
            ),
            handler: { args in
                // A UUID is 36 characters; the query cap only bounds the echo of a bad one.
                let id = try MCPInput.text(args, "id", tool: "get_document", maxLength: MCPInput.maxQuery)
                return try tools.getDocument(idString: id ?? "", offset: intArg(args, "offset") ?? 0)
            }
        ),
    ]
}
