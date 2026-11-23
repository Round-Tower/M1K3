//
//  SeasonalCalendarTests.swift
//  M1K3AvatarTests
//
//  The seasonal calendar beyond Halloween and Flight Club: Christmas / New Year (Dec 2 – Jan 7),
//  Ramadan (Umm al-Qura month 9) and Eid al-Fitr (Shawwal 1–3), Nowruz (Farvardin 1–7) and
//  St Patrick's (Mar 14–17). Ramadan, Eid and Nowruz are read off their own calendars, so the
//  windows are right every year with no date table; the pins below are the published 2026/2027
//  dates (Ramadan 1447 began 2026-02-18, Eid 2026-03-20; Ramadan 1448 2027-02-08, Eid 2027-03-09;
//  Nowruz 1406 2027-03-21), checked against Foundation's calendars on 2026-11-23.
//
//  Signed: Kev + claude-opus-5-5, 2026-11-23, Confidence 0.85 (pure calendar maths; Umm al-Qura is
//  Saudi Arabia's reckoning, and a country that sights the moon can start a day either side; the
//  on-screen looks are verify-by-launch). Prior: Unknown.
//

import Foundation
@testable import M1K3Avatar
import Testing

struct SeasonalCalendarTests {
    private func calendar(_ zone: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: zone))
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0, _ second: Int = 0,
                      in calendar: Calendar) throws -> Date
    {
        let parts = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        return try #require(calendar.date(from: parts))
    }

    private func look(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0, _ second: Int = 0,
                      offline: Bool = false) throws -> SeasonalLook?
    {
        let utc = try calendar("UTC")
        return try SeasonalLook.active(on: date(year, month, day, hour, minute, second, in: utc), calendar: utc, offline: offline)
    }

    // MARK: - Christmas / New Year

    @Test("christmas opens Dec 2 00:00 (the day after Flight Club) and closes after Jan 7 23:59:59")
    func christmasEdges() throws {
        #expect(try look(2026, 12, 1, 23, 59, 59) == nil)
        #expect(try look(2026, 12, 1, 23, 59, 59, offline: true) == .flightClub)
        #expect(try look(2026, 12, 2, 0, 0) == .christmas)
        #expect(try look(2026, 12, 2, 0, 0, offline: true) == .christmas)
        #expect(try look(2026, 12, 25) == .christmas)
        #expect(try look(2026, 12, 31, 23, 59, 59) == .christmas)
        #expect(try look(2027, 1, 1) == .christmas)
        #expect(try look(2027, 1, 7, 23, 59, 59) == .christmas)
        #expect(try look(2027, 1, 8, 0, 0) == nil)
    }

    // MARK: - Ramadan and Eid al-Fitr

    @Test("ramadan 1447 runs 2026-02-18 to 03-19, then three days of Eid from 03-20")
    func ramadan2026() throws {
        #expect(try look(2026, 2, 17) == nil)
        #expect(try look(2026, 2, 18) == .ramadan)
        #expect(try look(2026, 3, 1) == .ramadan)
        #expect(try look(2026, 3, 19) == .ramadan)
        #expect(try look(2026, 3, 20) == .eid)
        #expect(try look(2026, 3, 22) == .eid)
        #expect(try look(2026, 3, 23) != .eid)
    }

    @Test("ramadan 1448 moves eleven days earlier: 2027-02-08 to 03-08, Eid 03-09 to 03-11")
    func ramadan2027() throws {
        #expect(try look(2027, 2, 7) == nil)
        #expect(try look(2027, 2, 8) == .ramadan)
        #expect(try look(2027, 3, 8) == .ramadan)
        #expect(try look(2027, 3, 9) == .eid)
        #expect(try look(2027, 3, 11) == .eid)
        #expect(try look(2027, 3, 12) == nil)
    }

    @Test("ramadan is read off the Islamic calendar, whatever regional calendar the user runs")
    func ramadanRegionalCalendars() throws {
        let utc = try calendar("UTC")
        let ramadan = try date(2027, 2, 20, in: utc)
        for identifier: Calendar.Identifier in [.gregorian, .islamicUmmAlQura, .hebrew, .persian, .chinese, .buddhist] {
            var regional = Calendar(identifier: identifier)
            regional.timeZone = utc.timeZone
            #expect(SeasonalLook.active(on: ramadan, calendar: regional, offline: false) == .ramadan, "\(identifier)")
        }
    }

    // MARK: - Nowruz and St Patrick's

    @Test("nowruz runs Farvardin 1–7: 2027-03-21 to 03-27")
    func nowruz2027() throws {
        #expect(try look(2027, 3, 20) == nil)
        #expect(try look(2027, 3, 21) == .nowruz)
        #expect(try look(2027, 3, 27) == .nowruz)
        #expect(try look(2027, 3, 28) == nil)
    }

    @Test("st patrick's runs Mar 14–17, the Dublin festival days, every year")
    func stPatricks() throws {
        #expect(try look(2027, 3, 13) == nil)
        #expect(try look(2027, 3, 14, 0, 0) == .stPatricks)
        #expect(try look(2027, 3, 17, 23, 59, 59) == .stPatricks)
        #expect(try look(2027, 3, 18, 0, 0) == nil)
        #expect(try look(2028, 3, 17) == .stPatricks)
    }

    @Test("overlaps: the short feast wins the long season, and Eid wins Nowruz (2026)")
    func precedence() throws {
        // 2026: St Patrick's fell inside Ramadan, and Eid's first days met Nowruz.
        #expect(try look(2026, 3, 16) == .stPatricks)
        #expect(try look(2026, 3, 18) == .ramadan)
        #expect(try look(2026, 3, 21) == .eid)
        #expect(try look(2026, 3, 23) == .nowruz)
        #expect(try look(2026, 3, 27) == .nowruz)
    }

    // MARK: - Every look

    @Test("the override parses every look's name, any case")
    func overrideParsesEveryLook() {
        for season in SeasonalLook.allCases {
            #expect(SeasonalLook.Override(argument: season.rawValue) == .look(season), "\(season)")
            #expect(SeasonalLook.Override(argument: season.rawValue.uppercased()) == .look(season), "\(season)")
        }
        #expect(SeasonalLook.Override(argument: "easter") == nil)
    }

    @Test("-seasonalLook <look> forces any look on in July, even opted out")
    func overrideForcesEveryLook() throws {
        let utc = try calendar("UTC")
        let july = try date(2026, 7, 15, in: utc)
        for season in SeasonalLook.allCases {
            #expect(SeasonalLook.resolve(on: july, calendar: utc, enabled: false, offline: false, override: .look(season)) == season)
        }
    }

    @Test("the opt-out covers every look")
    func optOutCoversEveryLook() throws {
        let utc = try calendar("UTC")
        for day in try [date(2026, 12, 25, in: utc), date(2027, 2, 20, in: utc), date(2027, 3, 10, in: utc),
                        date(2027, 3, 17, in: utc), date(2027, 3, 22, in: utc)]
        {
            #expect(SeasonalLook.resolve(on: day, calendar: utc, enabled: true, offline: false, override: nil) != nil)
            #expect(SeasonalLook.resolve(on: day, calendar: utc, enabled: false, offline: false, override: nil) == nil)
        }
    }

    @Test("every look has one short greeting of at most 70 characters, and they are all different")
    func greetings() throws {
        var lines = Set<String>()
        for season in SeasonalLook.allCases {
            let line = try #require(SeasonalLook.greeting(for: season), "\(season)")
            #expect(!line.isEmpty && line.count <= 70, "\(season): \(line.count)")
            lines.insert(line)
        }
        #expect(lines.count == SeasonalLook.allCases.count)
    }

    @Test("every look costumes the Phosphor Fox")
    func everyLookWearsPhosphor() {
        for season in SeasonalLook.allCases {
            #expect(CompanionShadingStyle.off.wearing(season, on: .phosphorFox) == .phosphor, "\(season)")
        }
    }

    @Test("every look's four states are distinct, its rest is not today's rest, and speaking has the tighter rim")
    func palettesDistinct() {
        for season in SeasonalLook.allCases {
            let states = [AvatarActivity.idle, .listening, .thinking, .speaking].map { $0.phosphorTreatment(season: season) }
            #expect(Set(states.map(\.customValue.description)).count == 4, "\(season)")
            let calm = AvatarActivity.idle.phosphorTreatment(season: season)
            #expect(calm != PhosphorTreatment.calm, "\(season)")
            #expect(AvatarActivity.error.phosphorTreatment(season: season) == calm, "\(season)")
            #expect(AvatarActivity.generating.phosphorTreatment(season: season)
                == AvatarActivity.thinking.phosphorTreatment(season: season), "\(season)")
            #expect(AvatarActivity.speaking.phosphorTreatment(season: season).fresnelPower < calm.fresnelPower, "\(season)")
        }
    }

    @Test("every seasonal lattice reads on the site Fox's black body (relative luminance ≥ 0.45)")
    func everyLatticeReadsOnBlack() {
        for season in SeasonalLook.allCases {
            for activity in AvatarActivity.allCases {
                let t = activity.phosphorTreatment(season: season)
                let luminance = 0.2126 * t.red + 0.7152 * t.green + 0.0722 * t.blue
                #expect(luminance >= 0.45, "\(season) \(activity) is too dark for a line on black")
            }
        }
    }

    @Test("every day of a whole year resolves to at most one look, without crashing")
    func wholeYear() throws {
        let utc = try calendar("UTC")
        var day = try date(2027, 1, 1, in: utc)
        var seen = Set<SeasonalLook>()
        for _ in 0 ..< 365 {
            if let season = SeasonalLook.active(on: day, calendar: utc, offline: true) { seen.insert(season) }
            day = day.addingTimeInterval(86400)
        }
        #expect(seen == Set(SeasonalLook.allCases))
    }
}
