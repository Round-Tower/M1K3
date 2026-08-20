//
//  InteractionTimeline.swift
//  M1K3Heartbeat
//
//  The pure fold behind the Heartbeat destination screen's timeline: heartbeat
//  pulses and visiting-agent MCP calls merged into day buckets, with
//  consecutive same-client calls folded into VISITS ("Claude · 14 calls ·
//  search_knowledge ×6 · 14:02–14:31") so a burst of tool traffic reads as one
//  interaction, not five hundred rows.
//
//  Deliberately ignorant of M1K3MCPLog: the app maps its LoggedMCPCall rows
//  into the AgentCall input type, so this module stays dependency-free and the
//  fold stays unit-testable in milliseconds. Calendar is injected — day
//  bucketing must never depend on the machine running the tests.
//
//  Signed: Kev + claude-fable-5, 2026-08-19, Confidence 0.9 (pure, TDD'd
//  red-first: bucketing, gap/client/day-boundary visit breaks, interleaving,
//  summary counts). Prior: none (new file).
//

import Foundation

public enum InteractionTimeline {
    /// One MCP tool call as the timeline sees it — mapped from the app's
    /// opt-in Agent Interaction Log. Payload-free: the fold needs identity,
    /// tool, client, outcome, and time; request/response text stays in the
    /// log store until the user expands a visit.
    public struct AgentCall: Sendable, Equatable, Identifiable {
        public let id: Int64
        public let tool: String
        /// The MCP client's self-reported name from `initialize` (nil for
        /// rows captured before identity was recorded).
        public let clientName: String?
        public let isError: Bool
        public let timestamp: Date

        public init(id: Int64, tool: String, clientName: String?, isError: Bool, timestamp: Date) {
            self.id = id
            self.tool = tool
            self.clientName = clientName
            self.isError = isError
            self.timestamp = timestamp
        }
    }

    /// A tool + how often it was called inside one visit.
    public struct ToolCount: Sendable, Equatable {
        public let tool: String
        public let count: Int

        public init(tool: String, count: Int) {
            self.tool = tool
            self.count = count
        }
    }

    /// A folded burst of calls from one client: same client, no silence longer
    /// than the gap, never spanning a day boundary.
    public struct Visit: Sendable, Equatable, Identifiable {
        /// Chronological — the expansion renders them oldest-first, the way
        /// the interaction actually ran.
        public let calls: [AgentCall]

        public init(calls: [AgentCall]) {
            self.calls = calls
        }

        public var id: Int64 {
            calls.first?.id ?? 0
        }

        public var clientName: String? {
            calls.first?.clientName
        }

        public var start: Date {
            calls.first?.timestamp ?? .distantPast
        }

        public var end: Date {
            calls.last?.timestamp ?? .distantPast
        }

        public var callCount: Int {
            calls.count
        }

        public var errorCount: Int {
            calls.count(where: \.isError)
        }

        /// Most-frequent first; ties alphabetical — the visit's summary line.
        public var toolCounts: [ToolCount] {
            Dictionary(grouping: calls, by: \.tool)
                .map { ToolCount(tool: $0.key, count: $0.value.count) }
                .sorted { ($0.count, $1.tool) > ($1.count, $0.tool) }
        }
    }

    /// One timeline row: a heartbeat pulse or a folded agent visit.
    public enum Event: Sendable, Equatable, Identifiable {
        case pulse(HeartbeatEntry)
        case visit(Visit)

        public var id: String {
            switch self {
            case let .pulse(entry): "pulse-\(entry.id)"
            case let .visit(visit): "visit-\(visit.id)"
            }
        }

        /// Sort key: a pulse is its moment; a visit sorts by its LATEST
        /// activity (the burst "happened" until it went quiet).
        public var sortDate: Date {
            switch self {
            case let .pulse(entry): entry.createdAt
            case let .visit(visit): visit.end
            }
        }
    }

    /// One day's bucket, events newest-first.
    public struct Day: Sendable, Equatable, Identifiable {
        public let day: Date
        public let events: [Event]

        public init(day: Date, events: [Event]) {
            self.day = day
            self.events = events
        }

        public var id: Date {
            day
        }
    }

    /// Silence longer than this ends a visit — five minutes reads as "the
    /// agent went away and came back", shorter as one working burst.
    public static let visitGap: TimeInterval = 300

    /// Merge + fold + bucket. Days newest-first; events within a day
    /// newest-first. Input order doesn't matter — the fold sorts first.
    public static func build(
        pulses: [HeartbeatEntry],
        calls: [AgentCall],
        gap: TimeInterval = visitGap,
        calendar: Calendar = .current
    ) -> [Day] {
        let events = fold(calls: calls, gap: gap, calendar: calendar).map(Event.visit)
            + pulses.map(Event.pulse)
        let byDay = Dictionary(grouping: events) { calendar.startOfDay(for: $0.sortDate) }
        return byDay
            .map { day, dayEvents in
                Day(day: day, events: dayEvents.sorted { $0.sortDate > $1.sortDate })
            }
            .sorted { $0.day > $1.day }
    }

    /// Fold calls into visits: chronological scan, breaking on client change,
    /// a silence longer than `gap`, or a day boundary (a visit inside one day
    /// keeps the day bucketing unambiguous).
    private static func fold(calls: [AgentCall], gap: TimeInterval, calendar: Calendar) -> [Visit] {
        let ordered = calls.sorted { $0.timestamp < $1.timestamp }
        var visits: [Visit] = []
        var current: [AgentCall] = []
        for call in ordered {
            if let last = current.last {
                let sameClient = last.clientName == call.clientName
                let withinGap = call.timestamp.timeIntervalSince(last.timestamp) <= gap
                let sameDay = calendar.isDate(last.timestamp, inSameDayAs: call.timestamp)
                if sameClient, withinGap, sameDay {
                    current.append(call)
                    continue
                }
                visits.append(Visit(calls: current))
                current = []
            }
            current.append(call)
        }
        if !current.isEmpty { visits.append(Visit(calls: current)) }
        return visits
    }
}
