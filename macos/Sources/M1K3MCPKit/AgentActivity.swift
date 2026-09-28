//
//  AgentActivity.swift
//  M1K3MCPKit
//
//  What an agent did that the owner should know about (#270 slice 2; Kev, 2026-09-28: a quiet
//  list in the menu bar, a dot until seen). A grant keeps the microphone and memory deletes off
//  by default, but a caller holding every secret on this Mac can still drive a client that holds
//  them; seeing it happen is the detection that works against that caller. Each entry is who,
//  what, when and whether it ran — never the arguments, which may carry anything.
//
//  Signed: Kev + claude-opus-5-5, 2026-09-28, Confidence 0.85 (pure, test-pinned; the popover
//  is glue, verify-by-launch). Prior: none (new file).
//

import Foundation

public struct AgentActivityEntry: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case microphone, deletedMemory, savedMemory
    }

    public enum Outcome: Sendable, Equatable {
        /// The tool ran.
        case ran
        /// Refused for want of the owner's grant (`LoopbackToolGrants`).
        case refused
        /// Anything else that stopped it: bad input, a busy mic, nothing to forget.
        case failed
    }

    public let id: UUID
    public let kind: Kind
    /// The client's self-reported name: display data, not an identity.
    public let client: String?
    public let at: Date
    public let outcome: Outcome

    public init(id: UUID = UUID(), kind: Kind, client: String?, at: Date, outcome: Outcome) {
        self.id = id
        self.kind = kind
        self.client = client
        self.at = at
        self.outcome = outcome
    }

    /// One plain line: "Claude Code deleted a memory", "Codex tried the microphone — not allowed".
    public var summary: String {
        let who = client.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
            ?? "An agent"
        let what = switch (kind, outcome) {
        case (.microphone, .ran): "listened through the microphone"
        case (.microphone, _): "tried the microphone"
        // forget_memory can end without deleting (no confident match), so the line says
        // what was asked, not what happened.
        case (.deletedMemory, .ran): "asked M1K3 to forget a memory"
        case (.deletedMemory, _): "tried to delete a memory"
        case (.savedMemory, .ran): "saved a memory"
        case (.savedMemory, _): "tried to save a memory"
        }
        return outcome == .refused ? "\(who) \(what) — not allowed" : "\(who) \(what)"
    }
}

public enum AgentActivity {
    /// The tools worth telling the owner about. `remember` is here though it's served freely:
    /// a planted "fact" outlives the session, so the owner should see it arrive.
    public static let noticedTools: [String: AgentActivityEntry.Kind] = [
        "listen": .microphone, "forget_memory": .deletedMemory, "remember": .savedMemory,
    ]
}

/// The newest few entries, newest first, and how many arrived since the owner last looked.
public struct AgentActivityFeed: Sendable, Equatable {
    public static let capacity = 20
    public private(set) var entries: [AgentActivityEntry] = []
    public private(set) var unseen = 0

    public init() {}

    public mutating func record(_ entry: AgentActivityEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
        unseen += 1
    }

    public mutating func markSeen() {
        unseen = 0
    }
}

/// Records every call to a noticed tool, however it ends. Wrap it OUTSIDE the grant gate so a
/// refused attempt is recorded too; the arguments never reach `record`.
public func noticedToolDefinitions(
    _ definitions: [MCPToolDefinition],
    client: @escaping @Sendable () -> String?,
    now: @escaping @Sendable () -> Date = { Date() },
    record: @escaping @Sendable (AgentActivityEntry) -> Void
) -> [MCPToolDefinition] {
    definitions.map { definition in
        guard let kind = AgentActivity.noticedTools[definition.tool.name] else { return definition }
        return MCPToolDefinition(tool: definition.tool) { args in
            var outcome = AgentActivityEntry.Outcome.failed
            defer { record(AgentActivityEntry(kind: kind, client: client(), at: now(), outcome: outcome)) }
            do {
                let text = try await definition.handler(args)
                outcome = .ran
                return text
            } catch let refusal as LoopbackGrantRefusal {
                outcome = .refused
                throw refusal
            }
        }
    }
}
