//
//  ActivitySnapshot.swift
//  M1K3AgentTools
//
//  The data half of recent_activity: the plain snapshot the app's reader
//  fills (no store types cross into this module), the reader seam + its warm
//  stand-in, and the leniently parsed window / focus arguments. The digest
//  lives in ActivityDigest.swift; the tool in RecentActivityTool.swift.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-10, Confidence 0.85 (parsers and
//  bounds pinned in RecentActivityToolTests). Prior: none (new file).
//

import Foundation

// MARK: - The snapshot (plain data — no store types cross into this module)

/// What the stores held for the window. Plain, Sendable, Equatable data so
/// the digest is pure and the app's reader is the only impure part.
public struct ActivitySnapshot: Sendable, Equatable {
    public struct Conversation: Sendable, Equatable {
        /// nil until auto-titled (the drawer shows "New chat").
        public var title: String?
        public var updatedAt: Date

        public init(title: String?, updatedAt: Date) {
            self.title = title
            self.updatedAt = updatedAt
        }
    }

    public struct Memory: Sendable, Equatable {
        /// The title, or an excerpt of the fact when it has none.
        public var title: String
        /// The MemoryKind raw value ("fact", "preference", "profile", …).
        public var kind: String
        public var createdAt: Date

        public init(title: String, kind: String, createdAt: Date) {
            self.title = title
            self.kind = kind
            self.createdAt = createdAt
        }
    }

    public struct ToolUse: Sendable, Equatable {
        public var tool: String
        public var uses: Int

        public init(tool: String, uses: Int) {
            self.tool = tool
            self.uses = uses
        }
    }

    /// Visiting agents over MCP. `isEnabled` is the Settings toggle for the
    /// visitor log — off means nothing was RECORDED, which the digest says
    /// instead of reporting silence.
    public struct Visitors: Sendable, Equatable {
        public var isEnabled: Bool
        public var callCount: Int
        /// Most-frequent first.
        public var toolUses: [ToolUse]
        /// Self-reported `initialize` names — untrusted display data.
        public var clientNames: [String]

        public init(isEnabled: Bool, callCount: Int, toolUses: [ToolUse], clientNames: [String]) {
            self.isEnabled = isEnabled
            self.callCount = callCount
            self.toolUses = toolUses
            self.clientNames = clientNames
        }
    }

    public struct Pulse: Sendable, Equatable {
        /// The heartbeat's display text (narrative when one passed the guard,
        /// else the digest).
        public var text: String
        /// "Lil", "Big", or "digest".
        public var renderedBy: String
        public var createdAt: Date

        public init(text: String, renderedBy: String, createdAt: Date) {
            self.text = text
            self.renderedBy = renderedBy
            self.createdAt = createdAt
        }
    }

    public struct Todos: Sendable, Equatable {
        public var openCount: Int
        public var overdueTitles: [String]

        public init(openCount: Int, overdueTitles: [String]) {
            self.openCount = openCount
            self.overdueTitles = overdueTitles
        }
    }

    public var conversations: [Conversation]
    public var memories: [Memory]
    public var visitors: Visitors
    public var pulses: [Pulse]
    public var todos: Todos

    public init(
        conversations: [Conversation], memories: [Memory], visitors: Visitors,
        pulses: [Pulse], todos: Todos
    ) {
        self.conversations = conversations
        self.memories = memories
        self.visitors = visitors
        self.pulses = pulses
        self.todos = todos
    }

    /// Nothing recorded, log off — what the warm reader hands back.
    public static let empty = ActivitySnapshot(
        conversations: [], memories: [],
        visitors: Visitors(isEnabled: false, callCount: 0, toolUses: [], clientNames: []),
        pulses: [], todos: Todos(openCount: 0, overdueTitles: [])
    )

    /// True when the window holds no activity at all (open todos are ambient,
    /// not activity).
    var isQuiet: Bool {
        conversations.isEmpty && memories.isEmpty && pulses.isEmpty && visitors.callCount == 0
    }
}

// MARK: - The reader seam

public protocol ActivityReading: Sendable {
    /// Everything at or after `start` and, when `end` is given, before it.
    func snapshot(from start: Date, to end: Date?) async throws -> ActivitySnapshot
}

/// For the persona-prefix warm: the SAME palette (only tool definitions
/// render into the prefix), a reader that touches no store.
public struct NullActivityReading: ActivityReading {
    public init() {}

    public func snapshot(from _: Date, to _: Date?) async throws -> ActivitySnapshot {
        .empty
    }
}

// MARK: - The window

/// The span the model asked for, parsed leniently from free text. Calendar
/// days, never 24h multiples: "yesterday" is a whole day, "today" since
/// midnight.
public enum ActivityWindow: Sendable, Equatable {
    case today
    case yesterday
    case days(Int)
    case week

    /// A runaway "9999 days" is clamped — the stores are read since the start.
    public static let maxDays = 90

    public static func parse(_ raw: String) -> ActivityWindow {
        let text = raw.lowercased()
        if text.contains("yesterday") { return .yesterday }
        if text.contains("today") { return .today }
        if let number = firstNumber(in: text) {
            if text.contains("week") { return number == 1 ? .week : .days(min(number * 7, maxDays)) }
            switch number {
            case ..<1: return .week
            case 7: return .week
            default: return .days(min(number, maxDays))
            }
        }
        return .week
    }

    /// `end` is nil for open windows (through now).
    public func bounds(now: Date, calendar: Calendar) -> (start: Date, end: Date?) {
        let startOfToday = calendar.startOfDay(for: now)
        func daysBack(_ count: Int) -> Date {
            calendar.date(byAdding: .day, value: -count, to: startOfToday)
                ?? startOfToday.addingTimeInterval(-Double(count) * 86400)
        }
        switch self {
        case .today: return (startOfToday, nil)
        case .yesterday: return (daysBack(1), startOfToday)
        case .week: return (daysBack(6), nil)
        case let .days(count): return (daysBack(max(count, 1) - 1), nil)
        }
    }

    /// How many calendar days the window covers.
    var dayCount: Int {
        switch self {
        case .today, .yesterday: 1
        case .week: 7
        case let .days(count): max(count, 1)
        }
    }

    /// The noun the insight lines use ("most of the week went unremembered").
    var noun: String {
        switch self {
        case .today: "today"
        case .yesterday: "yesterday"
        case .week: "the week"
        case .days: "the stretch"
        }
    }

    private static func firstNumber(in text: String) -> Int? {
        guard let match = text.firstMatch(of: #/\d+/#) else { return nil }
        return Int(match.output)
    }
}

/// One section the model may narrow the digest to.
public enum ActivityFocus: Sendable, Equatable, CaseIterable {
    case chats, memories, visitors, pulses, todos

    public static func parse(_ raw: String) -> ActivityFocus? {
        let text = raw.lowercased()
        if text.contains("chat") || text.contains("conversation") { return .chats }
        if text.contains("memor") { return .memories }
        if text.contains("visit") || text.contains("agent") || text.contains("mcp") { return .visitors }
        if text.contains("heartbeat") || text.contains("pulse") { return .pulses }
        if text.contains("todo") || text.contains("task") { return .todos }
        return nil
    }
}
