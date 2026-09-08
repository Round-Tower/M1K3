//
//  DueDateParserTests.swift
//  M1K3TodosTests
//
//  Pins the natural-language due phrase the Add field accepts: a trailing
//  "by friday" / "tomorrow" / "in 3 days" / "next week" / "on 14 sep" /
//  "2026-09-14" comes off the title and becomes a due date at the END of
//  that local day (so "due today" holds all day and overdue starts at
//  midnight). Anything else leaves the title untouched.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-08, Confidence 0.9 (fixed clock
//  + UTC calendar; every phrase pinned). Prior: none (new file).
//

import Foundation
@testable import M1K3Todos
import Testing

struct DueDateParserTests {
    // Tuesday 2026-09-08 19:30 UTC.
    private let now = Date(timeIntervalSince1970: 1_788_895_800)
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_IE")
        return c
    }

    private func parse(_ text: String) -> (title: String, due: Date?) {
        DueDateParser.parse(text, now: now, calendar: calendar)
    }

    private func day(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withDashSeparatorInDate]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: iso)!.addingTimeInterval(86399)
    }

    @Test("no phrase leaves the title alone")
    func plain() {
        let out = parse("Book flights to Denis's wedding")
        #expect(out.title == "Book flights to Denis's wedding")
        #expect(out.due == nil)
    }

    @Test("today / tomorrow / in N days / next week")
    func relative() {
        #expect(parse("Call Mum today") == ("Call Mum", day("2026-09-08")))
        #expect(parse("Call Mum tomorrow") == ("Call Mum", day("2026-09-09")))
        #expect(parse("Call Mum in 3 days") == ("Call Mum", day("2026-09-11")))
        #expect(parse("Call Mum in 2 weeks") == ("Call Mum", day("2026-09-22")))
        #expect(parse("Call Mum next week") == ("Call Mum", day("2026-09-15")))
    }

    @Test("by / on <weekday>: the next such day, today counts")
    func weekday() {
        #expect(parse("Renew passport by Friday") == ("Renew passport", day("2026-09-11")))
        #expect(parse("Renew passport on tuesday") == ("Renew passport", day("2026-09-08")))
        #expect(parse("Renew passport by mon") == ("Renew passport", day("2026-09-14")))
        #expect(parse("Renew passport next friday") == ("Renew passport", day("2026-09-18")))
    }

    @Test("explicit dates: ISO, 14 sep, sep 14, 14/9 — this year, else next")
    func explicit() {
        #expect(parse("Book flights by 2026-10-03") == ("Book flights", day("2026-10-03")))
        #expect(parse("Book flights by 3 oct") == ("Book flights", day("2026-10-03")))
        #expect(parse("Book flights on Oct 3") == ("Book flights", day("2026-10-03")))
        #expect(parse("Book flights 3/10") == ("Book flights", day("2026-10-03")))
        #expect(parse("Tax return by 1 jan") == ("Tax return", day("2027-01-01")))
    }

    @Test("only a TRAILING phrase counts; a bare 'by' or a mid-sentence day stays in the title")
    func edges() {
        #expect(parse("Buy the Friday paper").due == nil)
        #expect(parse("Buy the Friday paper").title == "Buy the Friday paper")
        #expect(parse("Stand by").due == nil)
        #expect(parse("Stand by").title == "Stand by")
        #expect(parse("  tomorrow  ").title == "")
        #expect(parse("Call Mum, tomorrow") == ("Call Mum", day("2026-09-09")))
    }
}
