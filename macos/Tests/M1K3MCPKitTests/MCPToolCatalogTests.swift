//
//  MCPToolCatalogTests.swift
//  M1K3MCPKitTests
//
//  The MCP Bundle's bridge (integrations/mcpb/server/index.js) answers `tools/list`
//  from a checked-in catalog while the M1K3 app is closed: that is what Claude
//  Desktop shows before the app is open, and what Glama introspects in Docker. This
//  pins the catalog to the kit, declaration for declaration (name, title, description,
//  input schema, annotations), so the offline list is the one the app serves.
//
//  Regenerate after changing a tool:
//    M1K3_WRITE_TOOL_CATALOG=1 macos/tools/dev/tdd.sh M1K3MCPKitTests MCPToolCatalogTests
//
//  Signed: Kev + claude-opus-5.5, 2026-11-28, Confidence 0.85 (the same assembly
//  MCPHostController serves, before its grant gate and activity notice, which pass
//  declarations through untouched). Prior: Unknown.
//  Context: Kev, 2026-11-28, on the awesome-mcp-servers listing (#16207), which needs
//  a Glama quality grade: "Build it".
//

import Foundation
import M1K3Knowledge
@testable import M1K3MCPKit
import MCP
import Testing

struct MCPToolCatalogTests {
    private static let catalogURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // M1K3MCPKitTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // macos
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("integrations/mcpb/server/tools.json")

    @Test("The bridge's offline catalog is the kit's full tool list, declaration for declaration")
    func catalogMatchesKit() throws {
        let expected = try Self.render(Self.allTools())
        if ProcessInfo.processInfo.environment["M1K3_WRITE_TOOL_CATALOG"] == "1" {
            try expected.write(to: Self.catalogURL, atomically: true, encoding: .utf8)
        }
        let onDisk = try String(contentsOf: Self.catalogURL, encoding: .utf8)
        #expect(
            onDisk == expected,
            "integrations/mcpb/server/tools.json is stale: run with M1K3_WRITE_TOOL_CATALOG=1"
        )
    }

    @Test("Every tool in the catalog carries a title, a description and an object schema")
    func everyToolIsDescribed() throws {
        let tools = try Self.allTools()
        #expect(tools.count >= 19)
        for tool in tools {
            #expect(tool.title?.isEmpty == false, "\(tool.name) has no title")
            #expect(tool.description?.isEmpty == false, "\(tool.name) has no description")
            #expect(tool.inputSchema.objectValue?["type"] == .string("object"), "\(tool.name)'s schema")
        }
    }

    /// The loopback surface as `MCPHostController` assembles it, Private Cloud included (the
    /// App Store build lists it), annotated by the registry. Handlers are never called.
    static func allTools() throws -> [Tool] {
        let definitions = try makeKnowledgeToolDefinitions(store: KnowledgeStore())
            + makeVoiceToolDefinitions(handlers: VoiceToolHandlers(
                speak: { _, _, _ in throw Unused() },
                stopSpeaking: {},
                status: { fatalError("unused") },
                listen: { _ in throw Unused() }
            ))
            + makeIntelligenceToolDefinitions(handlers: IntelligenceToolHandlers(
                ask: { _ in throw Unused() },
                remember: { _, _, _ in throw Unused() }
            ))
            + makeOpenLinkToolDefinitions(handlers: OpenLinkToolHandlers(open: { _ in throw Unused() }))
            + makeMemoryToolDefinitions(handlers: MemoryToolHandlers(
                recall: { _ in throw Unused() },
                related: { _ in throw Unused() },
                stats: { throw Unused() },
                forget: { _ in throw Unused() }
            ))
            + makeTodoToolDefinitions(handlers: TodoToolHandlers(
                list: { _ in throw Unused() },
                propose: { _, _, _ in throw Unused() }
            ))
            + makePrivateCloudToolDefinitions(handlers: PrivateCloudToolHandlers { _, _ in throw Unused() })
        return MCPToolRegistry(definitions).tools.sorted { $0.name < $1.name }
    }

    static func render(_ tools: [Tool]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(tools)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    private struct Unused: Error {}
}
