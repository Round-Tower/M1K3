//
//  MCPToolAnnotationsTests.swift
//  M1K3MCPKitTests
//
//  Signed: Kev + claude-fable-5.2, 2026-11-12, Confidence 0.85. Prior: Unknown.
//

import Foundation
@testable import M1K3MCPKit
import MCP
import Testing

struct MCPToolAnnotationsTests {
    private func tool(_ name: String) -> Tool {
        Tool(name: name, description: "x", inputSchema: .object([:]))
    }

    @Test("Every tool M1K3 serves has a title and says whether it only reads")
    func everyToolIsCovered() {
        #expect(MCPToolAnnotations.table.count == 19)
        for (name, entry) in MCPToolAnnotations.table {
            #expect(!entry.title.isEmpty, "\(name)")
            #expect(entry.title.count <= 40, "\(name): a title is a label, not a sentence")
            let annotations = MCPToolAnnotations.annotated(tool(name)).annotations
            #expect(annotations.title == entry.title, "\(name)")
            #expect(annotations.readOnlyHint != nil, "\(name)")
        }
    }

    @Test("A tool that only reads says so and nothing more; a tool that changes something says whether it destroys")
    func readersAndWriters() {
        for (name, entry) in MCPToolAnnotations.table {
            let annotations = MCPToolAnnotations.annotated(tool(name)).annotations
            switch entry.effect {
            case .reads:
                #expect(annotations.readOnlyHint == true, "\(name)")
                #expect(annotations.destructiveHint == nil, "\(name): the hint only means something for a writer")
            case .changes:
                #expect(annotations.readOnlyHint == false, "\(name)")
                #expect(annotations.destructiveHint == false, "\(name)")
            case .destroys:
                #expect(annotations.readOnlyHint == false, "\(name)")
                #expect(annotations.destructiveHint == true, "\(name)")
            }
        }
    }

    @Test("The calls a client should think twice about are marked: forgetting destroys, the rest never claim to")
    func theOnesThatMatter() {
        #expect(MCPToolAnnotations.table["forget_memory"]?.effect == .destroys)
        #expect(MCPToolAnnotations.table.values.filter { $0.effect == .destroys }.count == 1)
        for reader in ["search_knowledge", "recall_memory", "get_document", "list_documents", "get_status", "memory_stats"] {
            #expect(MCPToolAnnotations.table[reader]?.effect == .reads, "\(reader)")
        }
        // These reach beyond the Mac: Apple's private cloud, a link opened in the world, a brain that may search.
        for outward in ["ask_private_cloud", "open_link", "ask_m1k3"] {
            let annotations = MCPToolAnnotations.annotated(tool(outward)).annotations
            #expect(annotations.openWorldHint == true, "\(outward)")
            #expect(annotations.readOnlyHint == false, "\(outward)")
        }
        #expect(MCPToolAnnotations.annotated(tool("remember")).annotations.openWorldHint == false)
    }

    @Test("A tool's own annotations win, an unknown tool passes through, and nothing else about a tool changes")
    func passThrough() {
        let own = Tool(
            name: "speak", description: "d", inputSchema: .object([:]),
            annotations: .init(title: "Mine", readOnlyHint: true)
        )
        #expect(MCPToolAnnotations.annotated(own).annotations.title == "Mine")

        let unknown = tool("not_a_tool")
        #expect(MCPToolAnnotations.annotated(unknown) == unknown)

        let before = Tool(name: "remember", description: "keeps it", inputSchema: .object(["type": "object"]))
        let after = MCPToolAnnotations.annotated(before)
        #expect(after.name == before.name)
        #expect(after.description == before.description)
        #expect(after.inputSchema == before.inputSchema)
        #expect(after.title == "Remember")
    }

    @Test("No tool is defined in the kit without an entry: the source's tool names and the table agree")
    func sourceAndTableAgree() throws {
        // …/macos/Tests/M1K3MCPKitTests/<this file>
        let kit = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/M1K3MCPKit")
        let files = try FileManager.default.contentsOfDirectory(at: kit, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(files.count > 5, "scan found too few files: the kit moved")
        var declared: Set<String> = []
        let pattern = /Tool\(\s*name:\s*"([a-z0-9_]+)"/
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for match in source.matches(of: pattern) {
                declared.insert(String(match.1))
            }
        }
        // The one tool that names itself through a constant.
        declared.insert(PrivateCloudMCPTool.name)
        #expect(declared == Set(MCPToolAnnotations.table.keys))
    }

    @Test("The registry lists tools with their annotations on")
    func registryAnnotates() {
        let registry = MCPToolRegistry([MCPToolDefinition(tool: tool("forget_memory")) { _ in "" }])
        #expect(registry.tools.first?.annotations.destructiveHint == true)
        #expect(registry.tools.first?.title == "Forget a memory")
    }
}
