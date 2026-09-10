//
//  AppEnvironment+RecentActivity.swift
//  M1K3App
//
//  The app half of recent_activity (2026-09-10): the live reader that
//  gathers the five stores into an `ActivitySnapshot`, and the late-bound hook
//  that carries it into the interactive palette ONLY — non-nil solely from the
//  main responder and its warm (the ContextSenseHook precedent), so a
//  visitor's ask_m1k3, the menu-bar Ask and the deep-dive lane structurally
//  never read chat titles or visitor names through the resident.
//
//  The reads mirror the heartbeat gatherer (AppEnvironment+Heartbeat.swift):
//  the drawer's own summaries on the main actor, the SQLite stores off it,
//  every failure degrading that source to empty rather than sinking the turn.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-10, Confidence 0.8 (the digest and
//  the parsers are pinned in M1K3AgentToolsTests; this gatherer is
//  verify-by-launch on the Mac — a spoken "what have we been up to?" through
//  the installed build). Prior: none (new file).
//

import Foundation
import M1K3AgentTools
import M1K3Chat
import M1K3Heartbeat
import M1K3MCPLog
import M1K3Memory
import M1K3Todos
import Synchronization

/// Late-bound reader (the DeepDelegationHook pattern): the tool is built in
/// init before `self` exists; the live reader is installed once the stores
/// are. Until then the tool reports a wake-up error, never a fake quiet week.
final class RecentActivityHook: ActivityReading, Sendable {
    private let installed = Mutex<(any ActivityReading)?>(nil)

    func install(_ reader: any ActivityReading) {
        installed.withLock { $0 = reader }
    }

    func snapshot(from start: Date, to end: Date?) async throws -> ActivitySnapshot {
        guard let reader = installed.withLock({ $0 }) else { throw NotInstalled() }
        return try await reader.snapshot(from: start, to: end)
    }

    struct NotInstalled: Error, CustomStringConvertible {
        var description: String {
            "M1K3 is still waking up — try again in a moment"
        }
    }
}

/// Gathers the window from the live stores. Each source is optional (the
/// stores are) and each read fails soft to empty — a broken heartbeat DB
/// must not make the chats unreadable.
struct LiveActivityReader: ActivityReading {
    /// The drawer's own list, read on the main actor — a closure rather than
    /// the `@MainActor` ChatSession itself, so this Sendable struct never
    /// holds a non-Sendable class (review 2 on the PR).
    let conversations: @MainActor @Sendable () -> [ConversationSummary]
    let memoryStore: MemoryStore?
    let conversationLog: ConversationLogStore?
    let heartbeatStore: HeartbeatStore?
    let todoStore: TodoStore?

    func snapshot(from start: Date, to end: Date?) async throws -> ActivitySnapshot {
        let inWindow: @Sendable (Date) -> Bool = { date in
            date >= start && (end.map { date < $0 } ?? true)
        }
        // Cheap main-actor read first (the heartbeat's order): the summaries
        // ARE the sidebar's list, so the tool sees exactly what is on disk now.
        let conversations = await conversations()
            .filter { inWindow($0.updatedAt) }
            .map { ActivitySnapshot.Conversation(title: $0.title, updatedAt: $0.updatedAt) }
        let logOn = UserDefaults.standard.bool(forKey: AppEnvironment.conversationLogEnabledKey)
        let memoryStore = memoryStore
        let conversationLog = conversationLog
        let heartbeatStore = heartbeatStore
        let todoStore = todoStore
        // Heavy store reads off the main actor (no main-thread IO).
        return await Task.detached(priority: .utility) { () -> ActivitySnapshot in
            let now = Date()
            let memories = ((try? memoryStore?.memoriesCreated(since: start)) ?? [])
                .filter { inWindow($0.createdAt) }
                .map {
                    ActivitySnapshot.Memory(
                        title: $0.title ?? HeartbeatComposer.excerpt($0.text, maxLength: 60),
                        kind: $0.kind.rawValue,
                        createdAt: $0.createdAt
                    )
                }

            var visitors = ActivitySnapshot.Visitors(isEnabled: logOn, callCount: 0, toolUses: [], clientNames: [])
            if logOn, let activity = try? conversationLog?.activity(since: start, until: end) {
                visitors.callCount = activity.callCount
                visitors.toolUses = activity.toolUses.map { .init(tool: $0.tool, uses: $0.uses) }
                visitors.clientNames = activity.clientNames
            }

            let pulses = ((try? heartbeatStore?.since(start)) ?? [])
                .filter { inWindow($0.createdAt) }
                .map {
                    ActivitySnapshot.Pulse(text: $0.displayText, renderedBy: $0.renderedBy, createdAt: $0.createdAt)
                }

            // The list as it stands — ambient, not windowed (an open todo is
            // open whatever week you ask about). Overdue = open AND past due.
            let open = (try? todoStore?.list(states: [.open])) ?? []
            let todos = ActivitySnapshot.Todos(
                openCount: open.count,
                overdueTitles: open.filter { $0.isOverdue(now: now) }.map(\.title)
            )

            return ActivitySnapshot(
                conversations: conversations, memories: memories, visitors: visitors, pulses: pulses, todos: todos
            )
        }.value
    }
}
