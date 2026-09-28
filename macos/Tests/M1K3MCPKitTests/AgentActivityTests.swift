//
//  AgentActivityTests.swift
//  M1K3MCPKitTests
//
//  #270 slice 2 (Kev, 2026-09-28: the menu-bar list): when an agent uses the microphone, deletes
//  a memory or saves one, M1K3 notes who, what and when — never the arguments — whether the call
//  ran, was refused for want of a grant, or failed. It's detection that works against a caller
//  who holds every secret: the owner sees it happened.
//
//  Signed: Kev + claude-opus-5-5, 2026-09-28, Confidence 0.85 (pure; the popover is glue).
//  Prior: none (new file).
//

import Foundation
@testable import M1K3MCPKit
import MCP
import Synchronization
import Testing

private final class Recorded: Sendable {
    let entries = Mutex<[AgentActivityEntry]>([])
}

private func tool(_ name: String, throwing error: (any Error)? = nil) -> MCPToolDefinition {
    MCPToolDefinition(tool: Tool(name: name, description: name, inputSchema: ["type": "object"])) { _ in
        if let error { throw error }
        return "done"
    }
}

private func noticed(
    _ definitions: [MCPToolDefinition], client: String? = "Claude Code", recorded: Recorded
) -> MCPToolRegistry {
    MCPToolRegistry(noticedToolDefinitions(
        definitions, client: { client }, now: { Date(timeIntervalSince1970: 1000) },
        record: { entry in recorded.entries.withLock { $0.append(entry) } }
    ))
}

struct AgentActivityTests {
    @Test("the noticed three: the microphone, deleting a memory, saving one")
    func noticedTools() {
        #expect(AgentActivity.noticedTools == ["listen": .microphone, "forget_memory": .deletedMemory, "remember": .savedMemory])
    }

    @Test("a noticed call that runs is recorded with the agent, what and when — and no arguments")
    func recordsRun() async {
        let recorded = Recorded()
        let registry = noticed([tool("remember")], recorded: recorded)
        _ = await registry.call(name: "remember", arguments: ["title": .string("secret title"), "text": .string("secret text")])
        let entry = recorded.entries.withLock { $0 }.first
        #expect(entry?.kind == .savedMemory)
        #expect(entry?.client == "Claude Code")
        #expect(entry?.outcome == .ran)
        #expect(entry?.at == Date(timeIntervalSince1970: 1000))
        #expect(!String(describing: entry as Any).contains("secret"))
    }

    @Test("a call refused for want of a grant is recorded as refused — the attempt is the news")
    func recordsRefusal() async {
        let recorded = Recorded()
        let gated = grantGatedToolDefinitions([tool("listen")], grants: { [] })
        _ = await noticed(gated, recorded: recorded).call(name: "listen", arguments: nil)
        #expect(recorded.entries.withLock { $0 }.map(\.outcome) == [.refused])
    }

    @Test("a call that fails otherwise is recorded as failed; unnoticed tools are never recorded")
    func recordsFailureOnly() async {
        let recorded = Recorded()
        let registry = noticed([tool("forget_memory", throwing: MCPInputError("nope")), tool("search_knowledge")], recorded: recorded)
        _ = await registry.call(name: "forget_memory", arguments: nil)
        _ = await registry.call(name: "search_knowledge", arguments: nil)
        #expect(recorded.entries.withLock { $0 }.map(\.outcome) == [.failed])
    }

    @Test("the line reads plainly; an unnamed agent is 'An agent'")
    func summaries() {
        func entry(_ kind: AgentActivityEntry.Kind, _ outcome: AgentActivityEntry.Outcome, client: String? = "Codex") -> String {
            AgentActivityEntry(kind: kind, client: client, at: .now, outcome: outcome).summary
        }
        #expect(entry(.microphone, .ran) == "Codex listened through the microphone")
        #expect(entry(.microphone, .refused) == "Codex tried the microphone — not allowed")
        // forget_memory can run and delete nothing, so a run says what was asked.
        #expect(entry(.deletedMemory, .ran) == "Codex asked M1K3 to forget a memory")
        #expect(entry(.deletedMemory, .refused) == "Codex tried to delete a memory — not allowed")
        #expect(entry(.savedMemory, .ran, client: nil) == "An agent saved a memory")
        #expect(entry(.savedMemory, .failed) == "Codex tried to save a memory")
    }

    @Test("the feed keeps the newest few, newest first, and counts what's unseen")
    func feed() {
        var feed = AgentActivityFeed()
        for index in 0 ..< AgentActivityFeed.capacity + 5 {
            feed.record(AgentActivityEntry(kind: .savedMemory, client: "c\(index)", at: .now, outcome: .ran))
        }
        #expect(feed.entries.count == AgentActivityFeed.capacity)
        #expect(feed.entries.first?.client == "c\(AgentActivityFeed.capacity + 4)")
        #expect(feed.unseen == AgentActivityFeed.capacity + 5)
        feed.markSeen()
        #expect(feed.unseen == 0)
        #expect(feed.entries.count == AgentActivityFeed.capacity)
    }
}
