//
//  InteractionTimelineTests.swift
//  M1K3HeartbeatTests
//
//  The interaction-timeline fold: pulses + agent calls merged into day
//  buckets, with consecutive same-client calls folded into visits. Pure and
//  Calendar-injected — deterministic, off-device.
//

import Foundation
@testable import M1K3Heartbeat
import Testing

/// A fixed calendar so day bucketing never depends on the test machine.
private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

/// 2026-08-19 00:00 UTC — an arbitrary, readable epoch for fixtures.
private let day0 = Date(timeIntervalSince1970: 1_786_752_000)

private func at(_ hours: Double, _ minutes: Double = 0) -> Date {
    day0.addingTimeInterval(hours * 3600 + minutes * 60)
}

private func pulse(_ id: Int64, at date: Date) -> HeartbeatEntry {
    HeartbeatEntry(id: id, digest: "digest \(id)", narrative: nil, renderedBy: "Lil", createdAt: date)
}

private func call(
    _ id: Int64, tool: String = "search_knowledge", client: String? = "Claude",
    isError: Bool = false, at date: Date
) -> InteractionTimeline.AgentCall {
    InteractionTimeline.AgentCall(id: id, tool: tool, clientName: client, isError: isError, timestamp: date)
}

/// The visits of a flattened day list, in order — most assertions want them.
private func visits(_ days: [InteractionTimeline.Day]) -> [InteractionTimeline.Visit] {
    days.flatMap(\.events).compactMap { event in
        if case let .visit(visit) = event { return visit }
        return nil
    }
}

struct InteractionTimelineTests {
    @Test("no inputs → no days")
    func empty() {
        #expect(InteractionTimeline.build(pulses: [], calls: [], calendar: utc).isEmpty)
    }

    @Test("pulses bucket by day, newest day and newest event first")
    func pulseDayBuckets() {
        let days = InteractionTimeline.build(
            pulses: [pulse(1, at: at(9)), pulse(2, at: at(13)), pulse(3, at: at(27))],
            calls: [],
            calendar: utc
        )
        #expect(days.count == 2)
        #expect(days[0].day == utc.startOfDay(for: at(27)))
        #expect(days[1].day == utc.startOfDay(for: at(9)))
        // Within a day: newest first.
        #expect(days[1].events.map(\.id) == ["pulse-2", "pulse-1"])
    }

    @Test("consecutive same-client calls inside the gap fold into one visit")
    func visitFolding() {
        let days = InteractionTimeline.build(
            pulses: [],
            calls: [
                call(1, tool: "search_knowledge", at: at(14, 0)),
                call(2, tool: "ask_m1k3", at: at(14, 2)),
                call(3, tool: "search_knowledge", at: at(14, 4)),
            ],
            calendar: utc
        )
        let folded = visits(days)
        #expect(folded.count == 1)
        let visit = folded[0]
        #expect(visit.calls.map(\.id) == [1, 2, 3]) // chronological inside the visit
        #expect(visit.start == at(14, 0))
        #expect(visit.end == at(14, 4))
    }

    @Test("a silence longer than the gap starts a new visit")
    func gapBreaksVisit() {
        let days = InteractionTimeline.build(
            pulses: [],
            calls: [
                call(1, at: at(14, 0)),
                call(2, at: at(14, 3)),
                call(3, at: at(15, 0)), // 57 min later — a fresh visit
            ],
            calendar: utc
        )
        let folded = visits(days)
        #expect(folded.count == 2)
        #expect(folded.map { $0.calls.map(\.id) } == [[3], [1, 2]]) // newest visit first
    }

    @Test("a client change starts a new visit even inside the gap")
    func clientChangeBreaksVisit() {
        let days = InteractionTimeline.build(
            pulses: [],
            calls: [
                call(1, client: "Claude", at: at(14, 0)),
                call(2, client: "Cursor", at: at(14, 1)),
            ],
            calendar: utc
        )
        #expect(visits(days).count == 2)
    }

    @Test("a visit never spans a day boundary")
    func dayBoundaryBreaksVisit() {
        let days = InteractionTimeline.build(
            pulses: [],
            calls: [
                call(1, at: at(23, 58)),
                call(2, at: at(24, 1)), // 3 min later, but tomorrow
            ],
            calendar: utc
        )
        #expect(days.count == 2)
        #expect(visits(days).count == 2)
    }

    @Test("pulses and visits interleave newest-first, a visit sorted by its latest activity")
    func interleaving() {
        let days = InteractionTimeline.build(
            pulses: [pulse(1, at: at(14, 3))],
            calls: [
                call(1, at: at(14, 0)),
                call(2, at: at(14, 2)),
                call(3, at: at(16, 0)),
            ],
            calendar: utc
        )
        #expect(days.count == 1)
        // Visit [3] (16:00) → pulse (14:03) → visit [1,2] (ends 14:02).
        #expect(days[0].events.map(\.id) == ["visit-3", "pulse-1", "visit-1"])
    }

    @Test("visit summaries: tool counts most-frequent first, ties by name; errors counted")
    func visitSummary() {
        let days = InteractionTimeline.build(
            pulses: [],
            calls: [
                call(1, tool: "ask_m1k3", at: at(14, 0)),
                call(2, tool: "search_knowledge", at: at(14, 1)),
                call(3, tool: "search_knowledge", isError: true, at: at(14, 2)),
            ],
            calendar: utc
        )
        let visit = visits(days)[0]
        #expect(visit.toolCounts == [
            InteractionTimeline.ToolCount(tool: "search_knowledge", count: 2),
            InteractionTimeline.ToolCount(tool: "ask_m1k3", count: 1),
        ])
        #expect(visit.errorCount == 1)
        #expect(visit.callCount == 3)
    }

    @Test("tool-count ties break ALPHABETICALLY by name (the non-obvious tuple sort)")
    func toolCountTieBreak() {
        // Two tools tied at 1 each — the ordering must be alphabetical, which
        // the swapped-operand tuple sort encodes non-obviously. Pins it so a
        // later "simplification" can't silently flip it.
        let days = InteractionTimeline.build(
            pulses: [],
            calls: [
                call(1, tool: "zebra_tool", at: at(14, 0)),
                call(2, tool: "alpha_tool", at: at(14, 1)),
            ],
            calendar: utc
        )
        #expect(visits(days)[0].toolCounts.map(\.tool) == ["alpha_tool", "zebra_tool"])
    }

    @Test("unsorted input calls are handled — the fold sorts before grouping")
    func unsortedInput() {
        let days = InteractionTimeline.build(
            pulses: [],
            calls: [call(2, at: at(14, 2)), call(1, at: at(14, 0))],
            calendar: utc
        )
        let folded = visits(days)
        #expect(folded.count == 1)
        #expect(folded[0].calls.map(\.id) == [1, 2])
    }
}
