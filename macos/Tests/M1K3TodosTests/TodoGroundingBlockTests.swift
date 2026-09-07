//
//  TodoGroundingBlockTests.swift
//  M1K3TodosTests
//
//  Pins the block the responder pastes under WHAT I KNOW ABOUT YOU: nil on
//  an empty list (byte-identical prompt), overdue first with a band, the
//  visitor's name on visitor items, a hard cap of eight lines — and the
//  TODO-line extractor the heartbeat uses to turn a narrative tail into a
//  proposal.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-07, Confidence 0.85 (format
//  pinned; the wording awaits a live A/B like every grounding block).
//  Prior: none (new file).
//

import Foundation
@testable import M1K3Todos
import Testing

struct TodoGroundingBlockTests {
    private let now = Date(timeIntervalSince1970: 1_788_000_000)
    private func open(_ title: String, source: TodoSource = .user, due: TimeInterval? = nil, age: TimeInterval = 0) -> Todo {
        Todo(
            title: title, note: nil, source: source, state: .open, origin: nil,
            due: due.map { now.addingTimeInterval($0) }, createdAt: now.addingTimeInterval(-age)
        )
    }

    @Test("an empty list renders nil")
    func empty() {
        #expect(TodoGroundingBlock.render(open: [], now: now) == nil)
    }

    @Test("overdue lines lead and carry the band; due next; then newest first")
    func ordering() throws {
        let block = try #require(TodoGroundingBlock.render(open: [
            open("Call Mum", age: 100),
            open("Book dentist", due: 3 * 86400),
            open("Renew passport", source: .visitor(clientName: "Claude"), due: -2 * 86400),
            open("Water plants", age: 10),
        ], now: now))
        #expect(block == """
        OPEN TODOS (the user's own list — mention only when relevant; never mark one done, never add one unasked):
        - [overdue 2 days] Renew passport (from Claude)
        - [due in 3 days] Book dentist
        - Water plants
        - Call Mum
        """)
    }

    @Test("bands: due today, tomorrow, overdue yesterday, weeks")
    func bands() throws {
        let block = try #require(TodoGroundingBlock.render(open: [
            open("a", due: 3600), open("b", due: 86400 + 3600), open("c", due: -86400 - 3600), open("d", due: 15 * 86400),
        ], now: now))
        #expect(block.contains("- [overdue 1 day] c"))
        #expect(block.contains("- [due today] a"))
        #expect(block.contains("- [due tomorrow] b"))
        #expect(block.contains("- [due in 2 weeks] d"))
    }

    @Test("a resident proposal that was accepted shows no source; a nameless visitor is an unnamed agent")
    func sources() throws {
        let block = try #require(TodoGroundingBlock.render(open: [
            open("r", source: .resident), open("v", source: .visitor(clientName: nil)),
        ], now: now))
        #expect(block.contains("\n- r\n"))
        #expect(block.hasSuffix("- v (from an unnamed agent)"))
    }

    @Test("dueBand: every band and its boundaries, off a plain 86 400-second day")
    func dueBandContract() {
        func band(_ seconds: TimeInterval) -> String {
            TodoGroundingBlock.dueBand(now.addingTimeInterval(seconds), now: now)
        }
        #expect(band(0) == "due today")
        #expect(band(86399) == "due today")
        #expect(band(86400) == "due tomorrow")
        #expect(band(2 * 86400) == "due in 2 days")
        #expect(band(13 * 86400 + 3600) == "due in 13 days")
        #expect(band(14 * 86400) == "due in 2 weeks")
        #expect(band(30 * 86400) == "due in 4 weeks")
        #expect(band(-1) == "overdue 1 day")
        #expect(band(-86400) == "overdue 1 day")
        #expect(band(-2 * 86400) == "overdue 2 days")
    }

    @Test("caps at eight lines")
    func cap() throws {
        let many = (0 ..< 12).map { open("t\($0)", age: TimeInterval($0)) }
        let block = try #require(TodoGroundingBlock.render(open: many, now: now))
        #expect(block.split(separator: "\n").count == 9)
        #expect(block.contains("- t0\n"))
        #expect(!block.contains("- t8"))
    }
}

struct TodoProposalLineTests {
    @Test("extracts a trailing TODO: line and strips it from the narrative")
    func extracts() {
        let out = TodoProposalLine.extract(from: "Quiet afternoon. You mentioned the passport twice.\nTODO: Renew passport")
        #expect(out.title == "Renew passport")
        #expect(out.narrative == "Quiet afternoon. You mentioned the passport twice.")
    }

    @Test("no line leaves the narrative untouched")
    func none() {
        let out = TodoProposalLine.extract(from: "Quiet afternoon.")
        #expect(out.title == nil)
        #expect(out.narrative == "Quiet afternoon.")
    }

    @Test("only the LAST line counts; an empty or overlong title is dropped")
    func edges() {
        #expect(TodoProposalLine.extract(from: "TODO: early\nThen more prose.").title == nil)
        #expect(TodoProposalLine.extract(from: "Prose.\nTODO:   ").title == nil)
        #expect(TodoProposalLine.extract(from: "Prose.\nTODO:   ").narrative == "Prose.")
        let long = String(repeating: "x", count: 200)
        #expect(TodoProposalLine.extract(from: "Prose.\ntodo: \(long)").title == nil)
        #expect(TodoProposalLine.extract(from: "Prose.\n- TODO: Book the dentist.").title == "Book the dentist")
    }
}
