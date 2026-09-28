//
//  LoopbackToolGrantsTests.swift
//  M1K3MCPKitTests
//
//  #270 (Kev's ruling, 2026-09-27): on the loopback MCP surface, the microphone, memory deletes
//  and on-screen links each need a grant the owner turns on in Settings, default OFF. Any same-user
//  process can reach :4242, so reachability can't be the consent; a Settings toggle is something
//  another process can't flip. Refused calls stay listed and answer isError with where to allow them.
//
//  Signed: Kev + claude-opus-5-5, 2026-09-27, Confidence 0.85 (pure; the toggles themselves are
//  app glue, verify-by-launch). Prior: none (new file).
//

@testable import M1K3MCPKit
import MCP
import Synchronization
import Testing

private final class Calls: Sendable {
    let names = Mutex<[String]>([])
}

private func definition(_ name: String, calls: Calls) -> MCPToolDefinition {
    MCPToolDefinition(tool: Tool(name: name, description: name, inputSchema: ["type": "object"])) { _ in
        calls.names.withLock { $0.append(name) }
        return "ran \(name)"
    }
}

private func call(
    _ name: String, grants: LoopbackToolGrants, calls: Calls = Calls()
) async -> (isError: Bool, text: String, ran: Bool) {
    let registry = MCPToolRegistry(grantGatedToolDefinitions([definition(name, calls: calls)], grants: { grants }))
    let result = await registry.call(name: name, arguments: nil)
    let text: String = if case let .text(text, _, _) = result.content.first { text } else { "" }
    return (result.isError == true, text, calls.names.withLock { $0.contains(name) })
}

struct LoopbackToolGrantsTests {
    /// Every tool the loopback surface serves today, as the tool files declare them.
    static let everyTool: Set<String> = [
        "search_knowledge", "list_documents", "get_document",
        "speak", "stop_speaking", "get_status", "listen",
        "ask_m1k3", "get_answer", "list_jobs", "remember",
        "open_link",
        "recall_memory", "related_memory", "memory_stats", "forget_memory",
        "list_todos", "propose_todo",
    ]

    @Test("every loopback tool is classified: served, or gated by exactly one grant")
    func everyToolClassified() {
        let gated = Set(LoopbackToolGrants.gatedTools.keys)
        #expect(gated.isDisjoint(with: LoopbackToolGrants.servedTools))
        #expect(gated.union(LoopbackToolGrants.servedTools) == Self.everyTool)
    }

    @Test("the microphone, memory deletes and on-screen links are the gated three")
    func gatedThree() {
        #expect(LoopbackToolGrants.gatedTools == [
            "listen": .microphone, "forget_memory": .deleteMemories, "open_link": .openLinks,
        ])
    }

    @Test("#270: without its grant, a gated tool answers isError, says where to allow it, and never runs")
    func refusedWithoutGrant() async {
        for (tool, needed) in LoopbackToolGrants.gatedTools {
            let others = LoopbackToolGrants.all.subtracting(needed)
            let result = await call(tool, grants: others)
            #expect(result.isError, "\(tool)")
            #expect(!result.ran, "\(tool)")
            #expect(result.text.contains("Settings"), "\(tool): \(result.text)")
        }
    }

    @Test("with its grant, a gated tool runs as before")
    func runsWithGrant() async {
        for (tool, needed) in LoopbackToolGrants.gatedTools {
            let result = await call(tool, grants: needed)
            #expect(!result.isError, "\(tool)")
            #expect(result.ran, "\(tool)")
        }
    }

    @Test("served tools run with no grants at all")
    func servedRunUngranted() async {
        for tool in LoopbackToolGrants.servedTools {
            #expect(await call(tool, grants: []).ran, "\(tool)")
        }
    }

    @Test("an unclassified tool is refused until someone classifies it (no silent widening)")
    func unclassifiedFailsClosed() async {
        let result = await call("wipe_everything", grants: .all)
        #expect(result.isError)
        #expect(!result.ran)
        // No switch exists for it, so the refusal doesn't point at Settings (#444 review).
        #expect(!result.text.contains("Settings"))
        #expect(result.text.contains("isn't open to agents"))
    }

    @Test("grants are read on every call: turning one on takes effect at once")
    func grantsReadLive() async {
        let granted = Mutex(LoopbackToolGrants())
        let calls = Calls()
        let registry = MCPToolRegistry(grantGatedToolDefinitions(
            [definition("listen", calls: calls)], grants: { granted.withLock { $0 } }
        ))
        #expect(await registry.call(name: "listen", arguments: nil).isError == true)
        granted.withLock { $0 = .microphone }
        #expect(await registry.call(name: "listen", arguments: nil).isError != true)
    }
}
