//
//  HeartbeatTodoTests.swift
//  M1K3HeartbeatTests
//
//  The todo list in the pulse: an ambient line (never news — it must not
//  wake the model on its own), the three todo tags, and the prompt's
//  opt-in proposal rule.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-07, Confidence 0.9. Prior: none
//  (new file).
//

import Foundation
@testable import M1K3Heartbeat
import Testing

struct HeartbeatTodoTests {
    private func context(todos: HeartbeatContext.TodoActivity?) -> HeartbeatContext {
        HeartbeatContext(
            date: Date(timeIntervalSince1970: 1_754_480_000),
            device: HeartbeatContext.Device(
                batteryPercent: nil, isCharging: nil, diskFreeGB: 210, diskTotalGB: 994,
                uptimeHours: 51, thermal: .nominal, lowPowerMode: false
            ),
            todos: todos
        )
    }

    @Test("open todos render one ambient line; overdue titles are quoted, capped at three")
    func todoLine() {
        #expect(HeartbeatComposer.todoLine(nil) == nil)
        #expect(HeartbeatComposer.todoLine(.init(openCount: 0)) == nil)
        #expect(HeartbeatComposer.todoLine(.init(openCount: 2)) == "Todos: 2 open.")
        #expect(
            HeartbeatComposer.todoLine(.init(openCount: 5, overdueTitles: ["Renew passport", "Call Mum"]))
                == "Todos: 5 open; overdue: “Renew passport”, “Call Mum”."
        )
        #expect(
            HeartbeatComposer.todoLine(.init(openCount: 9, overdueTitles: ["a", "b", "c", "d", "e"]))
                == "Todos: 9 open; overdue: “a”, “b”, “c” and 2 more."
        )
    }

    @Test("todos are ambient: they do not count as activity and sit under Ambient in the digest")
    func ambientNotNews() {
        let ctx = context(todos: .init(openCount: 2, overdueTitles: ["Renew passport"]))
        #expect(!ctx.hasActivity)
        let digest = HeartbeatComposer.digest(from: ctx)
        #expect(digest.hasPrefix("A quiet stretch"))
        #expect(digest.contains("Todos: 2 open; overdue: “Renew passport”."))
    }

    @Test("tags: open and overdue come from the context; proposed is the app's to add")
    func tags() {
        let none = HeartbeatComposer.tags(from: context(todos: nil), renderedBy: "digest")
        #expect(!none.contains(.todosOpen) && !none.contains(.todoOverdue))
        let open = HeartbeatComposer.tags(from: context(todos: .init(openCount: 1)), renderedBy: "digest")
        #expect(open.contains(.todosOpen) && !open.contains(.todoOverdue))
        let late = HeartbeatComposer.tags(from: context(todos: .init(openCount: 1, overdueTitles: ["x"])), renderedBy: "digest")
        #expect(late.contains(.todosOpen) && late.contains(.todoOverdue))
        #expect(!late.contains(.todoProposed))
        #expect(PulseTag.todosOpen.displayLabel == "Todos open")
        #expect(PulseTag.todoOverdue.displayLabel == "Overdue")
        #expect(PulseTag.todoProposed.displayLabel == "Suggested")
        #expect(PulseTag.todoProposed.rawValue == "todo:proposed")
    }

    @Test("the proposal rule appears only when the app allows it")
    func promptRule() throws {
        let off = HeartbeatPrompt.render(digest: "d", earlierToday: [])
        let on = HeartbeatPrompt.render(digest: "d", earlierToday: [], mayProposeTodo: true)
        #expect(!off.contains("TODO:"))
        #expect(on.contains("`TODO: <short title>`"))
        #expect(on.contains("Otherwise write no such line."))
        #expect(on.replacingOccurrences(of: off, with: "").count > 0)
        #expect(try #require(on.range(of: "TODO:")?.lowerBound) < on.range(of: "Digest:")!.lowerBound)
    }
}
