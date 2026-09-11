//
//  ConversationLogActivityTests.swift
//  M1K3MCPLogTests
//
//  Pins the heartbeat's visiting-agent window: call count + distinct tool
//  names since a watermark, computed IN SQL — the challenger catch: counting
//  in Swift would page up to 500 rows of PII-bearing response text into
//  memory to produce an integer.
//
//  Signed: Kev + claude-fable-5, 2026-08-06, Confidence 0.9 (pinned
//  red-first against the in-memory store). Prior: none (new file).
//

import Foundation
import M1K3MCPKit
@testable import M1K3MCPLog
import Testing

struct ConversationLogActivityTests {
    private func makeStore() throws -> ConversationLogStore {
        try ConversationLogStore(path: nil)
    }

    private func entry(tool: String, client: String? = nil) -> MCPCallLogEntry {
        MCPCallLogEntry(
            tool: tool, arguments: nil, responseText: "ok", isError: false, durationMS: 5,
            clientName: client
        )
    }

    @Test("activity counts calls and names distinct tools since the watermark")
    func windowedActivity() throws {
        let store = try makeStore()
        store.record(entry(tool: "speak"))
        store.record(entry(tool: "search_knowledge"))
        store.record(entry(tool: "search_knowledge"))

        let activity = try store.activity(since: Date(timeIntervalSinceNow: -60))

        #expect(activity.callCount == 3)
        #expect(Set(activity.toolNames) == ["speak", "search_knowledge"])
    }

    @Test("calls before the watermark are outside the window")
    func watermarkExcludes() throws {
        let store = try makeStore()
        store.record(entry(tool: "speak"))

        let activity = try store.activity(since: Date(timeIntervalSinceNow: 60))

        #expect(activity.callCount == 0)
        #expect(activity.toolNames.isEmpty)
    }

    @Test("distinct client names ride the window — identity for the pulse tags, still no payloads")
    func clientNames() throws {
        let store = try makeStore()
        store.record(entry(tool: "speak", client: "Claude Code"))
        store.record(entry(tool: "speak", client: "Claude Code"))
        store.record(entry(tool: "search_knowledge", client: "Cursor"))
        store.record(entry(tool: "listen")) // pre-identity row: no client

        let activity = try store.activity(since: Date(timeIntervalSinceNow: -60))

        #expect(Set(activity.clientNames) == ["Claude Code", "Cursor"])
    }

    @Test("per-tool use counts ride the window, in the same most-frequent-first order as the names")
    func toolUseCounts() throws {
        // recent_activity (2026-09-10) wants "speak ×14, remember ×9" — the
        // counts the SQL already computes and then threw away.
        let store = try makeStore()
        store.record(entry(tool: "speak"))
        store.record(entry(tool: "speak"))
        store.record(entry(tool: "remember"))

        let activity = try store.activity(since: Date(timeIntervalSinceNow: -60))

        #expect(activity.toolUses == [.init(tool: "speak", uses: 2), .init(tool: "remember", uses: 1)])
        #expect(activity.toolUses.map(\.tool) == activity.toolNames)
    }

    @Test("an upper bound closes the window — yesterday's calls, not today's")
    func upperBound() throws {
        let store = try makeStore()
        store.record(entry(tool: "speak"))

        let closed = try store.activity(since: Date(timeIntervalSinceNow: -60), until: Date(timeIntervalSinceNow: -30))
        let open = try store.activity(since: Date(timeIntervalSinceNow: -60), until: Date(timeIntervalSinceNow: 60))

        #expect(closed.callCount == 0)
        #expect(open.callCount == 1)
    }

    @Test("tool names come most-frequent first")
    func frequencyOrder() throws {
        let store = try makeStore()
        store.record(entry(tool: "speak"))
        store.record(entry(tool: "search_knowledge"))
        store.record(entry(tool: "search_knowledge"))

        let activity = try store.activity(since: Date(timeIntervalSinceNow: -60))

        #expect(activity.toolNames.first == "search_knowledge")
    }
}
