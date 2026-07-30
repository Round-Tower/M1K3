//
//  MemoryRecencyTests.swift
//  M1K3ChatTests
//
//  Tier 1 of the dream-cycle plan (scratch/dream-cycle/SPEC.md): the recency
//  phrase the memory block renders — "(learned 3 days ago)". Pure band math
//  over a supplied clock; no Calendar, no locale, fully deterministic.
//
//  Signed: Kev + claude-fable-5, 2026-07-30, Confidence 0.9. Prior: Unknown
//

import Foundation
@testable import M1K3Chat
import Testing

struct MemoryRecencyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func phrase(daysAgo: Double) -> String {
        MemoryRecency.phrase(from: now.addingTimeInterval(-daysAgo * 86400), to: now)
    }

    @Test("under a day reads today")
    func today() {
        #expect(phrase(daysAgo: 0) == "today")
        #expect(phrase(daysAgo: 0.9) == "today")
    }

    @Test("a future timestamp clamps to today, never a negative age")
    func futureClamps() {
        #expect(phrase(daysAgo: -3) == "today")
    }

    @Test("one to two days reads yesterday")
    func yesterday() {
        #expect(phrase(daysAgo: 1) == "yesterday")
        #expect(phrase(daysAgo: 1.9) == "yesterday")
    }

    @Test("days band up to two weeks")
    func days() {
        #expect(phrase(daysAgo: 2) == "2 days ago")
        #expect(phrase(daysAgo: 13) == "13 days ago")
    }

    @Test("weeks band from two weeks")
    func weeks() {
        #expect(phrase(daysAgo: 14) == "2 weeks ago")
        #expect(phrase(daysAgo: 30) == "4 weeks ago")
        #expect(phrase(daysAgo: 60) == "8 weeks ago")
    }

    @Test("months band from ~two months")
    func months() {
        #expect(phrase(daysAgo: 61) == "2 months ago")
        #expect(phrase(daysAgo: 200) == "6 months ago")
        #expect(phrase(daysAgo: 364) == "11 months ago")
    }

    @Test("years band from a year")
    func years() {
        #expect(phrase(daysAgo: 365) == "a year ago")
        #expect(phrase(daysAgo: 800) == "2 years ago")
    }
}
