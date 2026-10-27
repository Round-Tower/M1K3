//
//  ImportDatesTests.swift
//  M1K3ImportTests
//
//  #711: the two date shapes the exports carry. ChatGPT writes seconds since 1970 (a JSON number,
//  sometimes null); Claude and OKF write ISO 8601, with or without fractional seconds and with a
//  `Z` or a numeric offset. Anything else is no date, never a wrong one: oldest-first commit order
//  reads these, and `true` must not become 1970-01-01T00:00:01.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.9.
//  Prior: none (new file).

import Foundation
@testable import M1K3Import
import Testing

struct ImportDatesTests {
    @Test("epoch reads JSON numbers only: a bool, a string, null or nothing is no date")
    func epoch() {
        #expect(ImportDates.epoch(NSNumber(value: 1_760_000_000.5)) == Date(timeIntervalSince1970: 1_760_000_000.5))
        #expect(ImportDates.epoch(NSNumber(value: 1_760_000_000)) == Date(timeIntervalSince1970: 1_760_000_000))
        #expect(ImportDates.epoch(kCFBooleanTrue) == nil)
        #expect(ImportDates.epoch(NSNumber(value: true)) == nil)
        #expect(ImportDates.epoch("123") == nil)
        #expect(ImportDates.epoch(NSNull()) == nil)
        #expect(ImportDates.epoch(nil) == nil)
    }

    @Test("iso8601 reads whole and fractional seconds, Z and numeric offsets; garbage is no date")
    func iso8601() throws {
        let whole = Date(timeIntervalSince1970: 1_772_357_400)
        #expect(ImportDates.iso8601("2026-03-01T09:30:00Z") == whole)
        #expect(ImportDates.iso8601("2026-03-01T09:30:00+00:00") == whole)
        #expect(ImportDates.iso8601("2026-03-01T10:30:00+01:00") == whole)
        let fractional = try #require(ImportDates.iso8601("2026-03-01T09:30:00.123456Z"))
        #expect(abs(fractional.timeIntervalSince1970 - 1_772_357_400.123456) < 0.001)
        #expect(ImportDates.iso8601("not a date") == nil)
        #expect(ImportDates.iso8601("   ") == nil)
        #expect(ImportDates.iso8601(nil) == nil)
    }
}
