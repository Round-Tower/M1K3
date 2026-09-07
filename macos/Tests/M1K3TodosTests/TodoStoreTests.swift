//
//  TodoStoreTests.swift
//  M1K3TodosTests
//
//  Pins the todo store against the in-memory DB: round-trip of every
//  field, state filters newest-first, resolvedAt stamping, the per-source
//  pending count the ceiling reads, and Clear resolved keeping the live list.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-07, Confidence 0.9 (red-first).
//  Prior: none (new file).
//

import Foundation
@testable import M1K3Todos
import Testing

struct TodoStoreTests {
    private let t0 = Date(timeIntervalSince1970: 1_788_000_000)

    private func todo(
        _ title: String, source: TodoSource = .user, state: TodoState? = nil,
        due: Date? = nil, origin: TodoOrigin? = nil, at: Date? = nil
    ) -> Todo {
        Todo(
            title: title, note: nil, source: source,
            state: state ?? TodoConsentPolicy.initialState(for: source),
            origin: origin, due: due, createdAt: at ?? t0
        )
    }

    @Test("a todo round-trips with every field")
    func roundTrip() throws {
        let store = try TodoStore()
        var item = todo(
            "Renew passport", source: .visitor(clientName: "Claude"), due: t0.addingTimeInterval(86400),
            origin: TodoOrigin(memoryId: "mem-1", pulseId: 7)
        )
        item.note = "expires in March"
        try store.add(item)
        let back = try store.todo(id: item.id)
        #expect(back == item)
    }

    @Test("list filters by state, newest first")
    func listByState() throws {
        let store = try TodoStore()
        try store.add(todo("first", at: t0))
        try store.add(todo("second", at: t0.addingTimeInterval(60)))
        try store.add(todo("proposal", source: .resident))
        #expect(try store.list(states: [.open]).map(\.title) == ["second", "first"])
        #expect(try store.list(states: [.pending]).map(\.title) == ["proposal"])
        #expect(try store.list(states: [.open, .pending]).count == 3)
        #expect(try store.openCount() == 2)
    }

    @Test("setState stamps resolvedAt on terminal states and clears it on reopen")
    func resolvedAt() throws {
        let store = try TodoStore()
        let item = todo("x")
        try store.add(item)
        try store.setState(id: item.id, .done, at: t0.addingTimeInterval(10))
        #expect(try store.todo(id: item.id)?.state == .done)
        #expect(try store.todo(id: item.id)?.resolvedAt == t0.addingTimeInterval(10))
        try store.setState(id: item.id, .open, at: t0.addingTimeInterval(20))
        #expect(try store.todo(id: item.id)?.resolvedAt == nil)
    }

    @Test("pendingCount counts by source — visitors never count against the resident")
    func pendingBySource() throws {
        let store = try TodoStore()
        try store.add(todo("a", source: .resident))
        try store.add(todo("b", source: .resident))
        try store.add(todo("c", source: .visitor(clientName: "Claude")))
        try store.add(todo("d", source: .visitor(clientName: nil)))
        #expect(try store.pendingCount(source: .resident) == 2)
        #expect(try store.pendingCount(source: .visitor) == 2)
        #expect(try store.pendingCount(source: .user) == 0)
    }

    @Test("addProposal counts and inserts in one transaction — the ceiling cannot be overshot by a race")
    func addProposalCeiling() throws {
        let store = try TodoStore()
        #expect(try store.addProposal(todo("a", source: .resident), ifPendingCountBelow: 2))
        #expect(try store.addProposal(todo("b", source: .resident), ifPendingCountBelow: 2))
        #expect(try !(store.addProposal(todo("c", source: .resident), ifPendingCountBelow: 2)))
        #expect(try store.pendingCount(source: .resident) == 2)
        // A visitor's inbox is counted on its own.
        #expect(try store.addProposal(todo("v", source: .visitor(clientName: "Claude")), ifPendingCountBelow: 2))
        // Only a PENDING todo goes through this door.
        #expect(throws: TodoStoreError.self) {
            try store.addProposal(todo("u", source: .user), ifPendingCountBelow: 2)
        }
    }

    @Test("clearResolved removes done and dismissed, keeps open and pending")
    func clearResolved() throws {
        let store = try TodoStore()
        let done = todo("done"), gone = todo("gone"), live = todo("live"), ask = todo("ask", source: .resident)
        for item in [done, gone, live, ask] {
            try store.add(item)
        }
        try store.setState(id: done.id, .done, at: t0)
        try store.setState(id: gone.id, .dismissed, at: t0)
        try store.clearResolved()
        #expect(try store.list(states: Set(TodoState.allCases)).map(\.title).sorted() == ["ask", "live"])
    }
}
