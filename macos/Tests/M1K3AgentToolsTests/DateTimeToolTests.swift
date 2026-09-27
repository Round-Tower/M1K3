//
//  DateTimeToolTests.swift
//  M1K3AgentToolsTests
//
//  DateTimeDescriber is pure under injected Date/TimeZone/Locale, so the
//  expected strings are exact. The tool itself just wraps the describer with
//  an injectable clock — local models have no clock without this.
//
//  Signed: Kev + claude-fable-5, 2026-06-09, Confidence 0.9, Prior: Unknown
//  Review: Kev + claude-opus-5-5, 2026-09-27 — the reading carries derived values (#429):
//  until-midnight on a normal, a spring-forward and a fall-back day, the minute truncation, the
//  singular forms. Confidence 0.9.

import Foundation
@testable import M1K3AgentTools
import Testing

struct DateTimeDescriberTests {
    private let dublin = TimeZone(identifier: "Europe/Dublin")!
    private let irishEnglish = Locale(identifier: "en_IE")

    @Test("describes a known instant with weekday, date, time and zone")
    func describesKnownInstant() {
        // 2026-06-09 14:32:00 UTC == 15:32 IST (Dublin is UTC+1 in June).
        let date = Date(timeIntervalSince1970: 1_781_015_520)
        let described = DateTimeDescriber.describe(date, timeZone: dublin, locale: irishEnglish)
        #expect(described == "Tuesday, 9 June 2026, 15:32 (Europe/Dublin)")
    }

    @Test("respects the injected time zone")
    func respectsTimeZone() throws {
        let date = Date(timeIntervalSince1970: 1_781_015_520)
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let described = DateTimeDescriber.describe(date, timeZone: tokyo, locale: irishEnglish)
        #expect(described == "Tuesday, 9 June 2026, 23:32 (Asia/Tokyo)")
    }

    // #429: 375 read 13:55 and told the user "3 hours and 15 minutes until midnight".
    // The model quotes the arithmetic; it never does it.
    @Test("the reading carries time until midnight and tomorrow's date")
    func readingCarriesDerivedValues() {
        let date = Date(timeIntervalSince1970: 1_781_015_520) // 15:32 IST
        let reading = DateTimeDescriber.reading(date, timeZone: dublin, locale: irishEnglish)
        #expect(reading == """
        Tuesday, 9 June 2026, 15:32 (Europe/Dublin)
        Until midnight: 8 hours and 28 minutes. Tomorrow is Wednesday, 10 June.
        """)
    }

    @Test("until-midnight counts from the minute shown, not the seconds past it")
    func untilMidnightTruncatesSeconds() {
        let date = Date(timeIntervalSince1970: 1_781_015_520 + 45) // 15:32:45 IST
        let reading = DateTimeDescriber.reading(date, timeZone: dublin, locale: irishEnglish)
        #expect(reading.contains("Until midnight: 8 hours and 28 minutes."))
    }

    @Test("a spring-forward day is 23 hours long")
    func untilMidnightOnDSTDay() {
        // 2026-03-29 00:30 GMT; Dublin jumps 01:00 → 02:00 later that night.
        let date = Date(timeIntervalSince1970: 1_774_744_200)
        let reading = DateTimeDescriber.reading(date, timeZone: dublin, locale: irishEnglish)
        #expect(reading.contains("Until midnight: 22 hours and 30 minutes."))
        #expect(reading.contains("Tomorrow is Monday, 30 March."))
    }

    @Test("a fall-back day is 25 hours long")
    func untilMidnightOnFallBackDay() {
        // 2026-10-25 00:30 IST (24 Oct 23:30 UTC); Dublin falls back 02:00 → 01:00 later that night.
        let date = Date(timeIntervalSince1970: 1_792_884_600)
        let reading = DateTimeDescriber.reading(date, timeZone: dublin, locale: irishEnglish)
        #expect(reading.hasPrefix("Sunday, 25 October 2026, 00:30 (Europe/Dublin)"))
        #expect(reading.contains("Until midnight: 24 hours and 30 minutes."))
        #expect(reading.contains("Tomorrow is Monday, 26 October."))
    }

    @Test("durations drop zero parts and use singulars")
    func durationWording() {
        #expect(DateTimeDescriber.duration(minutes: 1) == "1 minute")
        #expect(DateTimeDescriber.duration(minutes: 59) == "59 minutes")
        #expect(DateTimeDescriber.duration(minutes: 60) == "1 hour")
        #expect(DateTimeDescriber.duration(minutes: 61) == "1 hour and 1 minute")
        #expect(DateTimeDescriber.duration(minutes: 1440) == "24 hours")
    }
}

struct DateTimeToolTests {
    @Test("returns the described injected now and ignores the argument")
    func returnsDescribedNow() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_781_015_520)
        let tool = try DateTimeTool(
            now: { fixedNow },
            timeZone: #require(TimeZone(identifier: "Europe/Dublin")),
            locale: Locale(identifier: "en_IE")
        )
        let result = try await tool.execute(input: ["query": "whatever"])
        #expect(result.output.hasPrefix("Tuesday, 9 June 2026, 15:32 (Europe/Dublin)\n"))
        #expect(result.output.contains("Until midnight: 8 hours and 28 minutes."))
    }

    @Test("declares the agent-facing contract")
    func declaresContract() {
        let tool = DateTimeTool()
        #expect(tool.name == "datetime")
        #expect(!tool.description.isEmpty)
        #expect(tool.parameters.count == 1)
    }
}
