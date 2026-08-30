//
//  HeartbeatStoreTests.swift
//  M1K3HeartbeatTests
//
//  Pins the pulse store: its own capped GRDB file (ConversationLogStore's
//  idioms — in-memory when path is nil, cap-trim inside the write
//  transaction, one-tap Clear), plus the two reads the heartbeat itself
//  depends on: `latestDate()` IS the schedule watermark, and `since(_:)`
//  feeds the day's earlier pulses back into the next narrative.
//
//  Signed: Kev + claude-fable-5, 2026-08-06, Confidence 0.9 (round-trip, cap,
//  ordering, and watermark behaviour all pinned red-first against the
//  in-memory store). Prior: none (new file).
//

import Foundation
@testable import M1K3Heartbeat
import Testing

struct HeartbeatStoreTests {
    private func makeStore(capacity: Int = HeartbeatStore.defaultCapacity) throws -> HeartbeatStore {
        try HeartbeatStore(path: nil, capacity: capacity)
    }

    @Test("a recorded pulse round-trips")
    func roundTrip() throws {
        let store = try makeStore()
        let when = Date(timeIntervalSince1970: 1_754_480_000)
        store.record(digest: "The machine is running cool.", narrative: "Easy afternoon.", renderedBy: "Big", at: when)
        let entries = try store.recent()
        #expect(entries.count == 1)
        #expect(entries[0].digest == "The machine is running cool.")
        #expect(entries[0].narrative == "Easy afternoon.")
        #expect(entries[0].renderedBy == "Big")
        #expect(abs(entries[0].createdAt.timeIntervalSince(when)) < 1)
    }

    @Test("a deterministic-fallback pulse stores a nil narrative")
    func nilNarrative() throws {
        let store = try makeStore()
        store.record(digest: "Quiet stretch.", narrative: nil, renderedBy: "digest", at: Date())
        #expect(try store.recent()[0].narrative == nil)
    }

    @Test("recent is newest-first")
    func newestFirst() throws {
        let store = try makeStore()
        let base = Date(timeIntervalSince1970: 1_754_480_000)
        store.record(digest: "first", narrative: nil, renderedBy: "digest", at: base)
        store.record(digest: "second", narrative: nil, renderedBy: "digest", at: base.addingTimeInterval(7200))
        #expect(try store.recent().map(\.digest) == ["second", "first"])
    }

    @Test("the cap trims oldest rows inside the write")
    func capTrims() throws {
        let store = try makeStore(capacity: 2)
        let base = Date(timeIntervalSince1970: 1_754_480_000)
        for index in 0 ..< 4 {
            store.record(
                digest: "pulse-\(index)", narrative: nil, renderedBy: "digest",
                at: base.addingTimeInterval(Double(index) * 7200)
            )
        }
        #expect(try store.count() == 2)
        #expect(try store.recent().map(\.digest) == ["pulse-3", "pulse-2"])
    }

    @Test("latestDate is the schedule watermark; empty store has none")
    func watermark() throws {
        let store = try makeStore()
        #expect(try store.latestDate() == nil)
        let base = Date(timeIntervalSince1970: 1_754_480_000)
        store.record(digest: "a", narrative: nil, renderedBy: "digest", at: base)
        store.record(digest: "b", narrative: nil, renderedBy: "digest", at: base.addingTimeInterval(7200))
        let latest = try #require(try store.latestDate())
        #expect(abs(latest.timeIntervalSince(base.addingTimeInterval(7200))) < 1)
    }

    @Test("since() returns the day's pulses oldest-first for the narrative arc")
    func sinceOldestFirst() throws {
        let store = try makeStore()
        let base = Date(timeIntervalSince1970: 1_754_480_000)
        store.record(digest: "yesterday", narrative: nil, renderedBy: "digest", at: base.addingTimeInterval(-86400))
        store.record(digest: "morning", narrative: "Slow start.", renderedBy: "Lil", at: base)
        store.record(digest: "midday", narrative: "Warming up.", renderedBy: "Big", at: base.addingTimeInterval(7200))
        let today = try store.since(base.addingTimeInterval(-1))
        #expect(today.map(\.digest) == ["morning", "midday"])
    }

    @Test("clear empties the store and resets the watermark")
    func clearResets() throws {
        let store = try makeStore()
        store.record(digest: "a", narrative: nil, renderedBy: "digest", at: Date())
        try store.clear()
        #expect(try store.count() == 0)
        #expect(try store.latestDate() == nil)
    }

    // MARK: - Pulse tags (2026-08-30 addendum: structural only, cascade on delete)

    @Test("tags round-trip with their pulse")
    func tagsRoundTrip() throws {
        let store = try makeStore()
        store.record(
            digest: "d", narrative: nil, renderedBy: "digest",
            tags: [.quiet, .machineCool, .firstToday], at: Date()
        )
        let entry = try #require(try store.recent().first)
        #expect(entry.tags == [.quiet, .machineCool, .firstToday])
    }

    @Test("a tagless record stays a valid pulse with an empty set")
    func taglessRecord() throws {
        let store = try makeStore()
        store.record(digest: "d", narrative: nil, renderedBy: "digest", at: Date())
        #expect(try store.recent()[0].tags.isEmpty)
    }

    @Test("Clear takes the tags with it — nothing survives, no exceptions on the first extension")
    func clearTakesTags() throws {
        let store = try makeStore()
        store.record(digest: "d", narrative: nil, renderedBy: "digest", tags: [.active], at: Date())
        try store.clear()
        #expect(try store.tagRowCount() == 0)
    }

    @Test("the cap trim cascades to the trimmed pulses' tags")
    func capTrimCascadesTags() throws {
        let store = try makeStore(capacity: 1)
        let base = Date(timeIntervalSince1970: 1_754_480_000)
        store.record(digest: "old", narrative: nil, renderedBy: "digest", tags: [.quiet], at: base)
        store.record(
            digest: "new", narrative: nil, renderedBy: "digest",
            tags: [.active], at: base.addingTimeInterval(7200)
        )
        #expect(try store.count() == 1)
        // Only the surviving pulse's tag remains — the trimmed pulse's went with it.
        #expect(try store.tagRowCount() == 1)
        #expect(try store.recent()[0].tags == [.active])
    }

    @Test("since() carries tags too — the arc reader sees the same shape")
    func sinceCarriesTags() throws {
        let store = try makeStore()
        let base = Date(timeIntervalSince1970: 1_754_480_000)
        store.record(digest: "a", narrative: nil, renderedBy: "digest", tags: [.agentVisited], at: base)
        let today = try store.since(base.addingTimeInterval(-1))
        #expect(today[0].tags == [.agentVisited])
    }
}
