//
//  Todo.swift
//  M1K3Todos
//
//  One list, three sources. A todo is a memory with a verb and a state —
//  nothing more — and the state machine is the consent story:
//
//    user      → open at once (it is their list)
//    resident  → pending (the heartbeat may PROPOSE, capped by ProposalCeiling)
//    visitor   → pending (an MCP client may PROPOSE, stamped with its name)
//
//  Only the user ever moves a todo: accept, done, dismiss, reopen. The
//  resident and visitors get a nil from `TodoConsentPolicy.resolve` for
//  every transition — the same shape as forget_memory's consent gate, made
//  a pure table so nothing app-side can widen it by accident. v1 is
//  surface-only: M1K3 reads open todos into its grounding and may mention
//  or propose; it never acts on one unasked.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-07, Confidence 0.9 (pure types,
//  every consent cell pinned by TodoConsentPolicyTests). Prior: none (new file).
//

import Foundation

/// Who wrote the todo. `visitor(clientName:)` carries the MCP client's
/// self-reported `initialize` name — a label for the UI, never trusted.
public enum TodoSource: Sendable, Equatable, Hashable, Codable {
    case user
    case resident
    case visitor(clientName: String?)

    /// The coarse kind — what the store indexes and the ceiling counts.
    public var kind: TodoSourceKind {
        switch self {
        case .user: .user
        case .resident: .resident
        case .visitor: .visitor
        }
    }
}

public enum TodoSourceKind: String, Sendable, CaseIterable, Codable {
    case user, resident, visitor
}

public enum TodoState: String, Sendable, CaseIterable, Codable {
    /// Proposed by the resident or a visitor; waits for the user's tap.
    case pending
    case open
    case done
    case dismissed

    public var isResolved: Bool {
        self == .done || self == .dismissed
    }
}

/// What spawned the todo, when something did: the memory it was distilled
/// beside, or the heartbeat pulse whose narrative proposed it.
public struct TodoOrigin: Sendable, Equatable, Hashable, Codable {
    public var memoryId: String?
    public var pulseId: Int64?

    public init(memoryId: String? = nil, pulseId: Int64? = nil) {
        self.memoryId = memoryId
        self.pulseId = pulseId
    }
}

public struct Todo: Identifiable, Sendable, Equatable, Hashable, Codable {
    public var id: UUID
    public var title: String
    public var note: String?
    public var source: TodoSource
    public var state: TodoState
    public var origin: TodoOrigin?
    public var due: Date?
    public var createdAt: Date
    public var resolvedAt: Date?

    public init(
        id: UUID = UUID(), title: String, note: String? = nil, source: TodoSource,
        state: TodoState, origin: TodoOrigin? = nil, due: Date? = nil,
        createdAt: Date = Date(), resolvedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.note = note
        self.source = source
        self.state = state
        self.origin = origin
        self.due = due
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
    }

    /// Open AND past its due date. Pending items are never overdue — they
    /// aren't on the list yet.
    public func isOverdue(now: Date) -> Bool {
        guard state == .open, let due else { return false }
        return due < now
    }
}

/// Who is asking for a transition.
public enum TodoActor: Sendable, CaseIterable {
    case user, resident, visitor
}

public enum TodoTransition: Sendable, CaseIterable {
    case accept, done, dismiss, reopen
}

/// The consent table. Pure: the app applies the result to the store.
public enum TodoConsentPolicy {
    /// Where a new todo lands. The user's own go straight on the list;
    /// anything else is a proposal.
    public static func initialState(for source: TodoSource) -> TodoState {
        source.kind == .user ? .open : .pending
    }

    /// The next state, or nil when the transition is refused. Only the user
    /// ever gets a non-nil — the resident and visitors may propose (via
    /// `initialState`) and nothing else.
    public static func resolve(_ transition: TodoTransition, on state: TodoState, by actor: TodoActor) -> TodoState? {
        guard actor == .user else { return nil }
        switch (transition, state) {
        case (.accept, .pending): return .open
        case (.done, .open): return .done
        case (.dismiss, .open), (.dismiss, .pending): return .dismissed
        case (.reopen, .done), (.reopen, .dismissed): return .open
        default: return nil
        }
    }
}

/// How many proposals the resident may hold unanswered. Three is the
/// noise ceiling: a heartbeat fires ~12×/day, and an inbox that fills
/// itself is a list the user stops reading. Visitors are counted
/// separately (each is its own caller; the MCP surface has its own gate).
public enum ProposalCeiling {
    public static let residentMax = 3

    public static func mayPropose(pendingResidentCount: Int, max: Int = residentMax) -> Bool {
        pendingResidentCount < max
    }
}
