//
//  ConversationLogStoreTests.swift
//  M1K3MCPLogTests
//
//  Contract for the opt-in agent-interaction log: record→recall roundtrip,
//  the 500-cap trim, the live-toggle self-gate (record() reads `isEnabled` on
//  every call — no server restart needed to take effect), and clear().
//
//  Signed: Kev + claude-opus-4-8, 2026-07-05, Confidence 0.85 (store logic
//  test-pinned against an in-memory GRDB queue; the app-shell wiring — the
//  UserDefaults-backed predicate + the sibling-of-memory.sqlite path — is
//  verify-by-launch). Prior: none (new file).
//

import Foundation
@testable import M1K3MCPKit
@testable import M1K3MCPLog
import MCP
import Testing

private func makeEntry(
    tool: String = "search_knowledge",
    arguments: [String: Value]? = ["query": .string("seals")],
    responseText: String = "found 3 documents",
    isError: Bool = false,
    durationMS: Int = 42,
    clientName: String? = nil
) -> MCPCallLogEntry {
    MCPCallLogEntry(
        tool: tool, arguments: arguments, responseText: responseText,
        isError: isError, durationMS: durationMS, clientName: clientName
    )
}

/// Tiny test-only mutable box so a `@Sendable` isEnabled predicate can be
/// flipped mid-test (mirrors MCPToolRegistryTests' `Locked`).
private final class ToggleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(_ value: Bool) {
        self.value = value
    }

    func set(_ new: Bool) {
        lock.lock()
        value = new
        lock.unlock()
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

struct ConversationLogStoreTests {
    @Test("a recorded call round-trips through recent()")
    func recordThenRecall() throws {
        let store = try ConversationLogStore()
        store.record(makeEntry())

        let recent = try store.recent()
        #expect(recent.count == 1)
        #expect(recent.first?.tool == "search_knowledge")
        #expect(recent.first?.responseText == "found 3 documents")
        #expect(recent.first?.isError == false)
        #expect(recent.first?.argumentsJSON?.contains("seals") == true)
    }

    @Test("recent() returns newest first")
    func newestFirst() throws {
        let store = try ConversationLogStore()
        store.record(makeEntry(tool: "first"))
        store.record(makeEntry(tool: "second"))
        store.record(makeEntry(tool: "third"))

        let recent = try store.recent()
        #expect(recent.map(\.tool) == ["third", "second", "first"])
    }

    @Test("recording beyond the cap trims the oldest entries")
    func capTrimsOldest() throws {
        let store = try ConversationLogStore(capacity: 3)
        for i in 1 ... 5 {
            store.record(makeEntry(tool: "call-\(i)"))
        }

        let recent = try store.recent()
        #expect(recent.count == 3)
        #expect(recent.map(\.tool) == ["call-5", "call-4", "call-3"])
        #expect(try store.count() == 3)
    }

    @Test("when disabled, record() is a no-op — the live toggle takes effect with no restart")
    func disabledPredicateSkipsRecording() throws {
        let enabled = ToggleBox(false)
        let store = try ConversationLogStore(isEnabled: { enabled.get() })

        store.record(makeEntry(tool: "should-not-land"))
        #expect(try store.count() == 0)

        // Flip the toggle live — no store rebuild, matching the app's
        // UserDefaults-read predicate.
        enabled.set(true)
        store.record(makeEntry(tool: "should-land"))
        #expect(try store.count() == 1)
        #expect(try store.recent().first?.tool == "should-land")
    }

    @Test("a throwing/isError call is recorded with isError true")
    func recordsErrorFlag() throws {
        let store = try ConversationLogStore()
        store.record(makeEntry(tool: "beta", responseText: "Error: the seal failed", isError: true))

        let recent = try store.recent()
        #expect(recent.first?.isError == true)
    }

    @Test("a client name round-trips; an entry without one reads back nil")
    func clientNameRoundTrip() throws {
        // The timeline folds visits by the client that called — the name comes
        // from the MCP initialize's clientInfo, stamped by the app's sink
        // wrapper. Legacy rows (pre-v2) and unidentified sessions stay nil.
        let store = try ConversationLogStore()
        store.record(makeEntry(clientName: "claude-code"))
        store.record(makeEntry())

        let recent = try store.recent()
        #expect(recent.count == 2)
        #expect(recent[0].clientName == nil) // newest first — the unnamed one
        #expect(recent[1].clientName == "claude-code")
    }

    @Test("a call with nil arguments records a nil argumentsJSON")
    func nilArgumentsStayNil() throws {
        let store = try ConversationLogStore()
        store.record(makeEntry(tool: "get_status", arguments: nil))

        #expect(try store.recent().first?.argumentsJSON == nil)
    }

    @Test("clear() empties the log")
    func clearEmptiesLog() throws {
        let store = try ConversationLogStore()
        store.record(makeEntry())
        store.record(makeEntry())
        #expect(try store.count() == 2)

        try store.clear()
        #expect(try store.count() == 0)
        #expect(try store.recent().isEmpty)
    }
}
