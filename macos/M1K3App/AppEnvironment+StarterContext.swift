//
//  AppEnvironment+StarterContext.swift
//  M1K3App
//
//  The blank canvas's context (StarterPrompts.Context, 2026-09-11): what the
//  stores hold right now, gathered on the main actor with cheap reads only —
//  titles, counts, one date, the hour. Every read fails soft to its zero so a
//  broken store never blanks the chips; the log-off toggle reads as no visitors.
//  A fresh draw per blank canvas (ContentView's task on `messages.isEmpty`).
//
//  Signed: Kev + claude-fable-5.1, 2026-09-11, Confidence 0.8 (the rule is pure
//  and pinned in StarterPromptsTests; this gatherer is verify-by-launch).
//  Prior: none (new file, patterned on the iOS `recentMemoryTitles`).
//

import Foundation
import M1K3Chat
import M1K3Heartbeat
import M1K3MCPLog
import M1K3Memory
import M1K3Todos

extension AppEnvironment {
    /// The chips for a fresh canvas — a new draw every call.
    func starterPrompts(count: Int = 4) -> [String] {
        var rng = SystemRandomNumberGenerator()
        return StarterPrompts.pick(context: starterContext(), count: count, using: &rng)
    }

    /// What is true right now, in the shape the pure rule wants.
    func starterContext(now: Date = Date(), calendar: Calendar = .current) -> StarterPrompts.Context {
        var context = StarterPrompts.Context.empty
        // allMemories is newest-first; titled facts only (distilled facts are
        // their own titles → nil, and a raw sentence makes a poor chip).
        context.memoryTitles = ((try? memoryStore?.allMemories(limit: 40)) ?? [])
            .compactMap(\.title)
            .prefix(4)
            .map(\.self)
        // The drawer's own list: titled, most recent first. The current empty
        // conversation has no row yet (rows write on send), so it never lists.
        context.conversationTitles = chat.conversationSummaries()
            .compactMap(\.title)
            .prefix(4)
            .map(\.self)
        let open = (try? todoStore?.list(states: [.open])) ?? []
        context.openTodoCount = open.count
        context.overdueTodoCount = open.count(where: { $0.isOverdue(now: now) })
        if let latest = try? heartbeatStore?.latestDate() {
            context.latestPulseAge = now.timeIntervalSince(latest)
        }
        if UserDefaults.standard.bool(forKey: Self.conversationLogEnabledKey),
           let activity = try? conversationLog?.activity(since: calendar.startOfDay(for: now))
        {
            context.visitorCallsToday = activity.callCount
            context.visitorNames = activity.clientNames
        }
        context.hour = calendar.component(.hour, from: now)
        return context
    }
}
