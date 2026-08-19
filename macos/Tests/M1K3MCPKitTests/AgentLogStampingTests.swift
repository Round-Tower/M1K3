//
//  AgentLogStampingTests.swift
//  M1K3MCPKitTests
//
//  The identity box + stamping sink behind the Agent Interaction Log's
//  per-client visits.
//

import Foundation
@testable import M1K3MCPKit
import Testing

private final class CapturingSink: MCPCallLogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [MCPCallLogEntry] = []

    func record(_ entry: MCPCallLogEntry) {
        lock.lock()
        _entries.append(entry)
        lock.unlock()
    }

    var entries: [MCPCallLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return _entries
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func bump() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

struct AgentLogStampingTests {
    @Test("the sink stamps the live identity onto each entry and fires onRecord")
    func stampsAndNotifies() {
        let box = ClientIdentityBox()
        let base = CapturingSink()
        let bumps = Counter()
        let sink = StampingLogSink(base: base, clientName: { box.current() }, onRecord: { bumps.bump() })

        box.set("claude-code")
        sink.record(MCPCallLogEntry(
            tool: "search_knowledge", arguments: nil, responseText: "ok", isError: false, durationMS: 5
        ))
        // A re-initialize with no name clears the identity — later calls must
        // not inherit the previous client's name.
        box.set(nil)
        sink.record(MCPCallLogEntry(
            tool: "get_status", arguments: nil, responseText: "ok", isError: false, durationMS: 2
        ))

        #expect(base.entries.map(\.clientName) == ["claude-code", nil])
        #expect(bumps.count == 2)
    }
}
