//
//  SeasonalLookTests.swift
//  M1K3AvatarTests
//
//  The Halloween window (Oct 24 - Nov 1 inclusive, the user's LOCAL calendar), the
//  opt-out, the launch-argument override, and the seasonal phosphor palette.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.85 (pure date maths and
//  mapping; the on-screen look is verify-by-launch). Prior: Unknown.
//  Review: Kev + claude-sonnet-5.5, 2026-10-22 — Offline AI Flight Club (Nov 3 – Dec 1, offline only):
//  every call gains `offline:`; window, gate, precedence, override, palette and greeting pinned below.
//  Confidence 0.85 (pure maths; the on-screen look is verify-by-launch, and real Airplane Mode on device).
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
        #expect(try SeasonalLook.active(on: date(2026, 10, 23, 23, 59, 59, in: utc), calendar: utc, offline: false) == nil)
        #expect(try SeasonalLook.active(on: date(2026, 10, 24, 0, 0, in: utc), calendar: utc, offline: false) == .halloween)
        #expect(try SeasonalLook.active(on: date(2026, 10, 31, 12, 0, in: utc), calendar: utc, offline: false) == .halloween)
        #expect(try SeasonalLook.active(on: date(2026, 11, 1, 23, 59, 59, in: utc), calendar: utc, offline: false) == .halloween)
        #expect(try SeasonalLook.active(on: date(2026, 11, 2, 0, 0, in: utc), calendar: utc, offline: false) == nil)
    }

    @Test("it is a local-calendar rule: one instant, two time zones, two answers")
    func localCalendar() throws {
        let auckland = try calendar("Pacific/Auckland")
        let losAngeles = try calendar("America/Los_Angeles")
        // Nov 2 09:00 in Auckland (UTC+13) is still Nov 1 in Los Angeles (UTC-7).
        let instant = try date(2026, 11, 2, 9, 0, in: auckland)
        #expect(SeasonalLook.active(on: instant, calendar: auckland, offline: false) == nil)
        #expect(SeasonalLook.active(on: instant, calendar: losAngeles, offline: false) == .halloween)
    }

    @Test("a non-Gregorian regional calendar still reads Oct 24 – Nov 1 on the Gregorian dates")
    func nonGregorianCalendar() throws {
        let utc = try calendar("UTC")
        let halloween = try date(2026, 10, 31, 12, 0, in: utc)
        let june = try date(2026, 6, 15, 12, 0, in: utc)
        for identifier: Calendar.Identifier in [.islamicUmmAlQura, .hebrew, .persian, .chinese] {
            var regional = Calendar(identifier: identifier)
            regional.timeZone = utc.timeZone
            #expect(SeasonalLook.active(on: halloween, calendar: regional, offline: false) == .halloween, "\(identifier)")
            #expect(SeasonalLook.active(on: june, calendar: regional, offline: false) == nil, "\(identifier)")
        }
    }

    @Test("in season every shading style wears the phosphor costume; out of season the choice stands")
    func seasonWearsPhosphor() {
        for style in CompanionShadingStyle.allCases {
            #expect(style.wearing(.halloween) == .phosphor)
            #expect(style.wearing(nil) == style)
        }
    }

    @Test("in costume M1K3 says one short line; out of season, nothing")
    func greeting() throws {
        let line = try #require(SeasonalLook.greeting(for: .halloween))
        #expect(!line.isEmpty && line.count <= 70)
        #expect(SeasonalLook.greeting(for: nil) == nil)
    }

    @Test("it applies in any year")
    func otherYears() throws {
        let utc = try calendar("UTC")
        #expect(try SeasonalLook.active(on: date(2027, 10, 31, 9, 0, in: utc), calendar: utc, offline: false) == .halloween)
        #expect(try SeasonalLook.active(on: date(2027, 6, 15, 9, 0, in: utc), calendar: utc, offline: false) == nil)
    }

    @Test("the user's opt-out wins over the date")
    func optOutWins() throws {
        let utc = try calendar("UTC")
        let halloween = try date(2026, 10, 31, 9, 0, in: utc)
        #expect(SeasonalLook.resolve(on: halloween, calendar: utc, enabled: false, offline: false, override: nil) == nil)
        #expect(SeasonalLook.resolve(on: halloween, calendar: utc, enabled: true, offline: false, override: nil) == .halloween)
    }

    @Test("-seasonalLook halloween forces it on in June, even opted out")
    func overrideForcesOn() throws {
        let utc = try calendar("UTC")
        let june = try date(2026, 6, 15, 9, 0, in: utc)
        #expect(SeasonalLook.resolve(on: june, calendar: utc, enabled: true, offline: false, override: .halloween) == .halloween)
        #expect(SeasonalLook.resolve(on: june, calendar: utc, enabled: false, offline: false, override: .halloween) == .halloween)
    }

    @Test("-seasonalLook none forces it off on Oct 31")
    func overrideForcesOff() throws {
        let utc = try calendar("UTC")
        let halloween = try date(2026, 10, 31, 9, 0, in: utc)
        let off = SeasonalLook.Override.off
        #expect(SeasonalLook.resolve(on: halloween, calendar: utc, enabled: true, offline: false, override: off) == nil)
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

    // MARK: - Offline AI Flight Club (Nov 3 – Dec 1, only while offline)

    @Test("flight club opens at Nov 3 00:00 and closes after Dec 1 23:59:59, offline")
    func flightWindowEdges() throws {
        let utc = try calendar("UTC")
        #expect(try SeasonalLook.active(on: date(2026, 11, 2, 23, 59, 59, in: utc), calendar: utc, offline: true) == nil)
        #expect(try SeasonalLook.active(on: date(2026, 11, 3, 0, 0, in: utc), calendar: utc, offline: true) == .flightClub)
        #expect(try SeasonalLook.active(on: date(2026, 11, 15, 12, 0, in: utc), calendar: utc, offline: true) == .flightClub)
        #expect(try SeasonalLook.active(on: date(2026, 11, 30, 23, 59, 59, in: utc), calendar: utc, offline: true) == .flightClub)
        #expect(try SeasonalLook.active(on: date(2026, 12, 1, 23, 59, 59, in: utc), calendar: utc, offline: true) == .flightClub)
        #expect(try SeasonalLook.active(on: date(2026, 12, 2, 0, 0, in: utc), calendar: utc, offline: true) == nil)
    }

    @Test("online, flight club never shows, in the window or out of it")
    func flightNeedsOffline() throws {
        let utc = try calendar("UTC")
        #expect(try SeasonalLook.active(on: date(2026, 11, 15, 12, 0, in: utc), calendar: utc, offline: false) == nil)
        #expect(try SeasonalLook.active(on: date(2026, 11, 3, 0, 0, in: utc), calendar: utc, offline: false) == nil)
        #expect(try SeasonalLook.active(on: date(2026, 12, 1, 23, 59, 59, in: utc), calendar: utc, offline: false) == nil)
    }

    @Test("offline out of season is nothing: July, and the days between the windows")
    func offlineOutOfSeason() throws {
        let utc = try calendar("UTC")
        #expect(try SeasonalLook.active(on: date(2026, 7, 15, 12, 0, in: utc), calendar: utc, offline: true) == nil)
        #expect(try SeasonalLook.active(on: date(2026, 10, 10, 12, 0, in: utc), calendar: utc, offline: true) == nil)
        #expect(try SeasonalLook.active(on: date(2026, 11, 2, 12, 0, in: utc), calendar: utc, offline: true) == nil)
    }

    @Test("Halloween keeps its dates and wins offline too; the windows never overlap")
    func halloweenPrecedence() throws {
        let utc = try calendar("UTC")
        #expect(try SeasonalLook.active(on: date(2026, 10, 31, 12, 0, in: utc), calendar: utc, offline: true) == .halloween)
        #expect(try SeasonalLook.active(on: date(2026, 11, 1, 23, 59, 59, in: utc), calendar: utc, offline: true) == .halloween)
        #expect(try SeasonalLook.active(on: date(2026, 11, 2, 12, 0, in: utc), calendar: utc, offline: true) == nil)
        // Every day of Oct 24 – Dec 2: at most one look, and Halloween's dates are Halloween's alone.
        var day = try date(2026, 10, 24, 12, 0, in: utc)
        for _ in 0 ..< 40 {
            let online = SeasonalLook.active(on: day, calendar: utc, offline: false)
            let offline = SeasonalLook.active(on: day, calendar: utc, offline: true)
            if online == .halloween { #expect(offline == .halloween) }
            if offline == .flightClub { #expect(online == nil) }
            day = day.addingTimeInterval(86400)
        }
    }

    @Test("flight club is a local-calendar rule: one instant, UTC+14 and UTC-10, two answers")
    func flightLocalCalendar() throws {
        let kiritimati = try calendar("Pacific/Kiritimati") // UTC+14
        let honolulu = try calendar("Pacific/Honolulu") // UTC-10
        // Nov 3 05:00 in Kiritimati (UTC+14) is Nov 2 05:00 in Honolulu (UTC-10): 24 hours apart, two dates.
        let instant = try date(2026, 11, 3, 5, 0, in: kiritimati)
        #expect(SeasonalLook.active(on: instant, calendar: kiritimati, offline: true) == .flightClub)
        #expect(SeasonalLook.active(on: instant, calendar: honolulu, offline: true) == nil)
    }

    @Test("a non-Gregorian regional calendar still reads Nov 3 – Dec 1 on the Gregorian dates")
    func flightNonGregorianCalendar() throws {
        let utc = try calendar("UTC")
        let inside = try date(2026, 11, 15, 12, 0, in: utc)
        let edge = try date(2026, 12, 1, 23, 59, 59, in: utc)
        let outside = try date(2026, 12, 2, 0, 0, in: utc)
        for identifier: Calendar.Identifier in [.islamicUmmAlQura, .hebrew, .persian, .chinese] {
            var regional = Calendar(identifier: identifier)
            regional.timeZone = utc.timeZone
            #expect(SeasonalLook.active(on: inside, calendar: regional, offline: true) == .flightClub, "\(identifier)")
            #expect(SeasonalLook.active(on: edge, calendar: regional, offline: true) == .flightClub, "\(identifier)")
            #expect(SeasonalLook.active(on: outside, calendar: regional, offline: true) == nil, "\(identifier)")
        }
    }

    @Test("the Seasonal looks opt-out covers flight club")
    func flightOptOut() throws {
        let utc = try calendar("UTC")
        let november = try date(2026, 11, 15, 9, 0, in: utc)
        #expect(SeasonalLook.resolve(on: november, calendar: utc, enabled: false, offline: true, override: nil) == nil)
        #expect(SeasonalLook.resolve(on: november, calendar: utc, enabled: true, offline: true, override: nil) == .flightClub)
        #expect(SeasonalLook.resolve(on: november, calendar: utc, enabled: true, offline: false, override: nil) == nil)
    }

    @Test("-seasonalLook flightclub forces it on regardless of date, network and opt-out")
    func flightOverrideForcesOn() throws {
        let utc = try calendar("UTC")
        let july = try date(2026, 7, 15, 9, 0, in: utc)
        #expect(SeasonalLook.resolve(on: july, calendar: utc, enabled: true, offline: false, override: .flightClub) == .flightClub)
        #expect(SeasonalLook.resolve(on: july, calendar: utc, enabled: false, offline: false, override: .flightClub) == .flightClub)
    }

    @Test("-seasonalLook none turns flight club off; -seasonalLook halloween still forces Halloween in November")
    func flightOverridesOtherWords() throws {
        let utc = try calendar("UTC")
        let november = try date(2026, 11, 15, 9, 0, in: utc)
        #expect(SeasonalLook.resolve(on: november, calendar: utc, enabled: true, offline: true, override: .off) == nil)
        #expect(SeasonalLook.resolve(on: november, calendar: utc, enabled: true, offline: true, override: .halloween) == .halloween)
    }

    @Test("the override parses flightclub, any case")
    func flightOverrideParsing() {
        #expect(SeasonalLook.Override(argument: "flightclub") == .flightClub)
        #expect(SeasonalLook.Override(argument: "FlightClub") == .flightClub)
        #expect(SeasonalLook.Override(argument: "flight-club") == nil)
        #expect(SeasonalLook.flightClub.rawValue == "flightclub")
    }

    @Test("the flight greeting is one honest line of at most 70 characters; nothing out of season")
    func flightGreeting() throws {
        let utc = try calendar("UTC")
        let line = try #require(SeasonalLook.greeting(for: .flightClub))
        #expect(!line.isEmpty && line.count <= 70)
        #expect(line != SeasonalLook.greeting(for: .halloween))
        // The line never claims what the app cannot see (Airplane Mode itself, or a costume).
        #expect(!line.localizedCaseInsensitiveContains("airplane"))
        #expect(!line.localizedCaseInsensitiveContains("goggles"))
        // Offline with no brain downloaded, M1K3 can't answer: the line promises presence, not answers.
        #expect(!line.localizedCaseInsensitiveContains("no problem"))
        #expect(!line.localizedCaseInsensitiveContains("I run"))
        let november = try date(2026, 11, 15, 9, 0, in: utc)
        let online = SeasonalLook.resolve(on: november, calendar: utc, enabled: true, offline: false, override: nil)
        #expect(SeasonalLook.greeting(for: online) == nil)
    }

    @Test("in flight colours every shading style wears the phosphor shader too")
    func flightWearsPhosphor() {
        for style in CompanionShadingStyle.allCases {
            #expect(style.wearing(.flightClub) == .phosphor)
            #expect(style.wearing(.flightClub) == style.wearing(.halloween))
        }
    }

    @Test("flight palette: runway blue resting, beacon amber speaking, strobe white thinking, nav green listening")
    func flightPalette() {
        let calm = AvatarActivity.idle.phosphorTreatment(season: .flightClub)
        #expect(calm.red == 0.290 && calm.green == 0.525 && calm.blue == 1.0)
        let speaking = AvatarActivity.speaking.phosphorTreatment(season: .flightClub)
        #expect(speaking.red == 1.0 && speaking.green == 0.690 && speaking.blue == 0.0)
        #expect(speaking.fresnelPower < calm.fresnelPower)
        for activity in [AvatarActivity.thinking, .generating] {
            let thinking = activity.phosphorTreatment(season: .flightClub)
            #expect(thinking.red == 0.957 && thinking.green == 0.973 && thinking.blue == 1.0)
            #expect(thinking.fresnelPower > calm.fresnelPower) // a strobe: tight and bright
        }
        let listening = AvatarActivity.listening.phosphorTreatment(season: .flightClub)
        #expect(listening.red == 0.224 && listening.green == 1.0 && listening.blue == 0.478)
        #expect(AvatarActivity.error.phosphorTreatment(season: .flightClub) == calm)
    }

    @Test("flight resting is not the default mint nor the default thinking blue, and not Halloween's colours")
    func flightPaletteIsDistinct() {
        let calm = AvatarActivity.idle.phosphorTreatment(season: .flightClub)
        #expect(calm != .calm && calm != .thinking)
        // The runway rest must not pass for today's thinking blue: deeper and clearly less green (it is a
        // lattice line on black now, so it can't go much darker without failing SiteFoxPaint's luminance floor).
        #expect(PhosphorTreatment.thinking.green - calm.green > 0.15)
        for activity in AvatarActivity.allCases {
            let flight = activity.phosphorTreatment(season: .flightClub)
            #expect(flight != activity.phosphorTreatment, "\(activity) matches today's default")
            #expect(flight != activity.phosphorTreatment(season: .halloween), "\(activity) matches Halloween")
        }
        // Each activity reads apart from the others (state must not hinge on colour alone: the rim
        // power differs too, but the hues are separable on their own).
        let colours = Set(AvatarActivity.allCases.map { activity -> [Float] in
            let t = activity.phosphorTreatment(season: .flightClub)
            return [t.red, t.green, t.blue]
        })
        #expect(colours.count == 4) // idle/error share, thinking/generating share
    }
}
