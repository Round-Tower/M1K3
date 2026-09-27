//
//  KnowledgeToolDefinitionsTests.swift
//  M1K3MCPKitTests
//
//  Pins the knowledge tool surface the stdio server has always exposed — the
//  registry refactor must not change what Claude sees.
//

import Foundation
import M1K3Knowledge
@testable import M1K3MCPKit
import MCP
import Testing

struct KnowledgeToolDefinitionsTests {
    @Test("the registry exposes exactly the original three knowledge tools")
    func toolSurface() throws {
        let store = try KnowledgeStore()
        let registry = MCPToolRegistry(makeKnowledgeToolDefinitions(store: store))
        #expect(registry.tools.map(\.name) == ["search_knowledge", "list_documents", "get_document"])
    }

    @Test("search_knowledge round-trips through the registry against a real store")
    func searchRoundTrip() async throws {
        let store = try KnowledgeStore()
        let ingester = DocumentIngester(store: store, embedder: HashingEmbeddingService())
        try await ingester.ingest(
            title: "Plant Notes",
            text: "3.2 Seals\nThe hydraulic seal on the conveyor failed under load."
        )
        let registry = MCPToolRegistry(makeKnowledgeToolDefinitions(store: store))
        let result = await registry.call(name: "search_knowledge", arguments: ["query": .string("hydraulic seal")])
        #expect(result.isError != true)
        if case let .text(text, _, _) = result.content.first {
            #expect(text.contains("Plant Notes"))
        } else {
            Issue.record("expected text content")
        }
    }

    @Test("missing required argument degrades to the handler's default, not a crash")
    func missingArgument() async throws {
        let store = try KnowledgeStore()
        let registry = MCPToolRegistry(makeKnowledgeToolDefinitions(store: store))
        let result = await registry.call(name: "get_document", arguments: nil)
        // Empty id → an isError result (#378); the call itself survives.
        #expect(result.content.isEmpty == false)
        #expect(result.isError == true)
    }
}

/// #378 + #379: a failed knowledge call reads as a failure to every MCP client.
extension KnowledgeToolDefinitionsTests {
    private func call(_ name: String, _ arguments: [String: Value]?) async throws -> (Bool, String) {
        let registry = try MCPToolRegistry(makeKnowledgeToolDefinitions(store: KnowledgeStore()))
        let result = await registry.call(name: name, arguments: arguments)
        guard case let .text(text, _, _) = result.content.first else { return (result.isError == true, "") }
        return (result.isError == true, text)
    }

    @Test("#378: search_knowledge refuses an empty, missing or wrong-typed query with isError")
    func searchRefusals() async throws {
        let empty = try await call("search_knowledge", ["query": .string("  ")])
        #expect(empty.0)
        #expect(empty.1.contains("requires a non-empty query"))
        #expect(try await call("search_knowledge", nil).0)
        let typed = try await call("search_knowledge", ["query": .int(42)])
        #expect(typed.0)
        #expect(typed.1.contains("query must be a string"))
    }

    @Test("#379: an over-cap query is refused at once and never echoed back")
    func searchCap() async throws {
        let long = String(repeating: "brain tier ", count: 12000)
        let over = try await call("search_knowledge", ["query": .string(long)])
        #expect(over.0)
        #expect(over.1.count < 200, "the refusal reflected the payload: \(over.1.count) chars")
    }

    @Test("#379: a no-results line quotes only the start of a long query")
    func noResultsEchoIsShort() async throws {
        let query = String(repeating: "zyzzyva ", count: 110) // 880 chars, under the cap
        let result = try await call("search_knowledge", ["query": .string(query)])
        #expect(!result.0)
        #expect(result.1.count < 200, "echoed \(result.1.count) chars")
    }

    @Test("#378: get_document reports a bad or unknown id as isError")
    func getDocumentRefusals() async throws {
        let bad = try await call("get_document", ["id": .string("not-a-uuid")])
        #expect(bad.0)
        #expect(bad.1.contains("not a valid document id"))
        let typed = try await call("get_document", ["id": .int(1)])
        #expect(typed.0)
        #expect(typed.1.contains("id must be a string"))
        let unknown = try await call("get_document", ["id": .string(UUID().uuidString)])
        #expect(unknown.0)
        #expect(unknown.1.contains("No document found"))
    }
}
