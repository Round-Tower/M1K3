//
//  SeasonalLookTests.swift
//  M1K3AvatarTests
//
//  The Halloween window (Oct 24 - Nov 1 inclusive, the user's LOCAL calendar), the
//  opt-out, the launch-argument override, and the seasonal phosphor palette.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.85 (pure date maths and
//  mapping; the on-screen look is verify-by-launch). Prior: Unknown.
//

import Foundation
@testable import M1K3Avatar
import Testing

struct SeasonalLookTests {
    private func calendar(_ zone: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: zone))
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0,
                      in calendar: Calendar) throws -> Date
    {
        let parts = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        return try #require(calendar.date(from: parts))
    }

    @Test("the window opens at Oct 24 00:00 and closes after Nov 1 23:59:59")
    func windowEdges() throws {
        let utc = try calendar("UTC")
        #expect(try SeasonalLook.active(on: date(2026, 10, 23, 23, 59, 59, in: utc), calendar: utc) == nil)
        #expect(try SeasonalLook.active(on: date(2026, 10, 24, 0, 0, in: utc), calendar: utc) == .halloween)
        #expect(try SeasonalLook.active(on: date(2026, 10, 31, 12, 0, in: utc), calendar: utc) == .halloween)
        #expect(try SeasonalLook.active(on: date(2026, 11, 1, 23, 59, 59, in: utc), calendar: utc) == .halloween)
        #expect(try SeasonalLook.active(on: date(2026, 11, 2, 0, 0, in: utc), calendar: utc) == nil)
    }

    @Test("it is a local-calendar rule: one instant, two time zones, two answers")
    func localCalendar() throws {
        let auckland = try calendar("Pacific/Auckland")
        let losAngeles = try calendar("America/Los_Angeles")
        // Nov 2 09:00 in Auckland (UTC+13) is still Nov 1 in Los Angeles (UTC-7).
        let instant = try date(2026, 11, 2, 9, 0, in: auckland)
        #expect(SeasonalLook.active(on: instant, calendar: auckland) == nil)
        #expect(SeasonalLook.active(on: instant, calendar: losAngeles) == .halloween)
    }

    @Test("a non-Gregorian regional calendar still reads Oct 24 – Nov 1 on the Gregorian dates")
    func nonGregorianCalendar() throws {
        let utc = try calendar("UTC")
        let halloween = try date(2026, 10, 31, 12, 0, in: utc)
        let june = try date(2026, 6, 15, 12, 0, in: utc)
        for identifier: Calendar.Identifier in [.islamicUmmAlQura, .hebrew, .persian, .chinese] {
            var regional = Calendar(identifier: identifier)
            regional.timeZone = utc.timeZone
            #expect(SeasonalLook.active(on: halloween, calendar: regional) == .halloween, "\(identifier)")
            #expect(SeasonalLook.active(on: june, calendar: regional) == nil, "\(identifier)")
        }
    }

    @Test("in season every shading style wears the phosphor costume; out of season the choice stands")
    func seasonWearsPhosphor() {
        for style in CompanionShadingStyle.allCases {
            #expect(style.wearing(.halloween) == .phosphor)
            #expect(style.wearing(nil) == style)
        }
    }

    @Test("it applies in any year")
    func otherYears() throws {
        let utc = try calendar("UTC")
        #expect(try SeasonalLook.active(on: date(2027, 10, 31, 9, 0, in: utc), calendar: utc) == .halloween)
        #expect(try SeasonalLook.active(on: date(2027, 6, 15, 9, 0, in: utc), calendar: utc) == nil)
    }

    @Test("the user's opt-out wins over the date")
    func optOutWins() throws {
        let utc = try calendar("UTC")
        let halloween = try date(2026, 10, 31, 9, 0, in: utc)
        #expect(SeasonalLook.resolve(on: halloween, calendar: utc, enabled: false, override: nil) == nil)
        #expect(SeasonalLook.resolve(on: halloween, calendar: utc, enabled: true, override: nil) == .halloween)
    }

    @Test("-seasonalLook halloween forces it on in June, even opted out")
    func overrideForcesOn() throws {
        let utc = try calendar("UTC")
        let june = try date(2026, 6, 15, 9, 0, in: utc)
        #expect(SeasonalLook.resolve(on: june, calendar: utc, enabled: true, override: .halloween) == .halloween)
        #expect(SeasonalLook.resolve(on: june, calendar: utc, enabled: false, override: .halloween) == .halloween)
    }

    @Test("-seasonalLook none forces it off on Oct 31")
    func overrideForcesOff() throws {
        let utc = try calendar("UTC")
        let halloween = try date(2026, 10, 31, 9, 0, in: utc)
        let off = SeasonalLook.Override.off
        #expect(SeasonalLook.resolve(on: halloween, calendar: utc, enabled: true, override: off) == nil)
    }

    @Test("the override parses its words, and reads the argument domain only")
    func overrideParsing() {
        #expect(SeasonalLook.Override(argument: "halloween") == .halloween)
        #expect(SeasonalLook.Override(argument: "none") == SeasonalLook.Override.off)
        #expect(SeasonalLook.Override(argument: "Halloween") == .halloween)
        #expect(SeasonalLook.Override(argument: "christmas") == nil)
        #expect(SeasonalLook.Override(argument: nil) == nil)

        // A value that persisted in the app's defaults must never force a look in a shipped build.
        let suite = "SeasonalLookTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let persisted = UserDefaults(suiteName: suite)
        persisted?.set("halloween", forKey: SeasonalLook.overrideKey)
        #expect(persisted.flatMap { SeasonalLook.Override(in: $0) } == nil)
    }

    @Test("halloween wears pumpkin at rest, ember speaking, violet thinking, amber listening")
    func halloweenPalette() {
        let calm = AvatarActivity.idle.phosphorTreatment(season: .halloween)
        #expect(calm.red == 1.0 && calm.green == 0.541 && calm.blue == 0.122)
        let speaking = AvatarActivity.speaking.phosphorTreatment(season: .halloween)
        #expect(speaking.red == 1.0 && speaking.green == 0.702 && speaking.blue == 0.278)
        #expect(speaking.fresnelPower < calm.fresnelPower)
        for activity in [AvatarActivity.thinking, .generating] {
            let thinking = activity.phosphorTreatment(season: .halloween)
            #expect(thinking.red == 0.608 && thinking.green == 0.361 && thinking.blue == 1.0)
        }
        let listening = AvatarActivity.listening.phosphorTreatment(season: .halloween)
        #expect(listening.red == 1.0)
        #expect(listening.green > calm.green && listening.green < speaking.green)
        #expect(AvatarActivity.error.phosphorTreatment(season: .halloween) == calm)
    }

    @Test("no season is today's exact treatment, for every activity")
    func noSeasonUnchanged() {
        for activity in AvatarActivity.allCases {
            #expect(activity.phosphorTreatment(season: nil) == activity.phosphorTreatment)
        }
    }
}
