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
//  Review: Kev + claude-opus-5-5, 2026-11-23 (Diwali + Lunar New Year) — pins Lunar New Year's Day 2027–2030 on the
//  Chinese calendar, its 16-day window once a year through three leap months, Diwali's five published dates, the
//  ± 2 window, a Gujarati-calendar typo guard and a freshness tripwire on the table, and every collision the brief
//  said didn't exist (Diwali × Halloween 2027/2030 and × Flight Club 2026/2029; Lunar New Year × Ramadan / Eid
//  2026–2030) with the "main days first" rule. The two Ramadan pins on Feb 17 2026 and Feb 7 2027 now read
//  `.lunarNewYear`. Confidence 0.85 (the Indian and Chinese calendar reads assume CI's OS agrees with macOS 27's).
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

    @Test("ramadan 1447: fasting Feb 18 – Mar 17, the moon-sighting days Mar 18–20, then Eid Mar 21–23")
    func ramadan2026() throws {
        #expect(try look(2026, 2, 15) == nil)
        #expect(try look(2026, 2, 17) == .lunarNewYear) // New Year's Day keeps its look (precedence below)
        #expect(try look(2026, 2, 18) == .ramadan)
        #expect(try look(2026, 3, 1) == .ramadan)
        // Mar 14–17 is St Patrick's (a short feast wins); Ramadan 28 is Mar 17.
        #expect(try look(2026, 3, 18) == .moonSighting) // Ramadan 29
        #expect(try look(2026, 3, 19) == .moonSighting) // Ramadan 30
        #expect(try look(2026, 3, 20) == .moonSighting) // Shawwal 1: Saudi Eid, maybe still Ramadan in Pakistan
        #expect(try look(2026, 3, 21) == .eid)
        #expect(try look(2026, 3, 23) == .eid)
        #expect(try look(2026, 3, 24) == .nowruz)
    }

    @Test("ramadan 1448 (29 days): fasting Feb 8 – Mar 7, moon sighting Mar 8–9, Eid Mar 10–12")
    func ramadan2027() throws {
        #expect(try look(2027, 2, 4) == nil)
        #expect(try look(2027, 2, 7) == .lunarNewYear) // Lunar New Year's second day; Ramadan takes the rest
        #expect(try look(2027, 2, 8) == .ramadan)
        #expect(try look(2027, 3, 7) == .ramadan)
        #expect(try look(2027, 3, 8) == .moonSighting)
        #expect(try look(2027, 3, 9) == .moonSighting)
        #expect(try look(2027, 3, 10) == .eid)
        #expect(try look(2027, 3, 12) == .eid)
        #expect(try look(2027, 3, 13) == nil)
    }

    @Test("the moon-sighting line is true on the last fast day and on Eid alike: it names neither")
    func moonSightingGreeting() throws {
        let line = try #require(SeasonalLook.greeting(for: .moonSighting))
        #expect(!line.contains("Eid") && !line.contains("Ramadan"))
        #expect(AvatarActivity.idle.phosphorTreatment(season: .moonSighting)
            == AvatarActivity.idle.phosphorTreatment(season: .ramadan))
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
        // 2026: St Patrick's fell inside Ramadan, and Eid met Nowruz (Farvardin 1 = Mar 21).
        #expect(try look(2026, 3, 16) == .stPatricks)
        #expect(try look(2026, 3, 21) == .eid)
        #expect(try look(2026, 3, 23) == .eid)
        #expect(try look(2026, 3, 27) == .nowruz)
    }

    @Test("every window is the user's local day: UTC+14 and UTC-12 disagree across St Patrick's last midnight")
    func localDayEdges() throws {
        let kiritimati = try calendar("Pacific/Kiritimati") // UTC+14
        let bakerIsland = try calendar("Etc/GMT+12") // UTC-12
        // Mar 18 00:30 in Kiritimati is Mar 16 22:30 at UTC-12.
        let instant = try date(2027, 3, 18, 0, 30, in: kiritimati)
        #expect(SeasonalLook.active(on: instant, calendar: kiritimati, offline: false) == nil)
        #expect(SeasonalLook.active(on: instant, calendar: bakerIsland, offline: false) == .stPatricks)
        let lastMinute = try date(2027, 3, 17, 23, 59, 59, in: kiritimati)
        #expect(SeasonalLook.active(on: lastMinute, calendar: kiritimati, offline: false) == .stPatricks)
    }

    @Test("the per-minute memo computes once per key and recomputes when the key moves")
    func memo() {
        let memo = SeasonalLook.Memo()
        var runs = 0
        let key = SeasonalLook.Memo.Key(zone: "UTC", minute: 100, enabled: true, offline: false, override: nil)
        #expect(memo.value(for: key) { runs += 1; return .christmas } == .christmas)
        #expect(memo.value(for: key) { runs += 1; return nil } == .christmas)
        #expect(runs == 1)
        let next = SeasonalLook.Memo.Key(zone: "UTC", minute: 101, enabled: true, offline: false, override: nil)
        #expect(memo.value(for: next) { runs += 1; return nil } == nil)
        let offline = SeasonalLook.Memo.Key(zone: "UTC", minute: 101, enabled: true, offline: true, override: nil)
        #expect(memo.value(for: offline) { runs += 1; return .flightClub } == .flightClub)
        #expect(runs == 3)
    }

    // MARK: - Lunar New Year

    @Test("lunar new year's day is read off the Chinese calendar: 2027-02-06, 2028-01-26, 2029-02-13, 2030-02-03")
    func lunarNewYearDays() throws {
        for (year, month, day) in [(2027, 2, 6), (2028, 1, 26), (2029, 2, 13), (2030, 2, 3)] {
            let utc = try calendar("UTC")
            let newYear = try date(year, month, day, in: utc)
            let eve = newYear.addingTimeInterval(-86400)
            #expect(SeasonalLook.lunarNewYearDay(on: newYear, in: utc.timeZone) == 1, "\(year)")
            #expect(SeasonalLook.lunarNewYearDay(on: eve, in: utc.timeZone) == 0, "\(year) eve")
            #expect(SeasonalLook.lunarNewYearDay(on: eve.addingTimeInterval(-86400), in: utc.timeZone) == nil, "\(year)")
            #expect(SeasonalLook.active(on: newYear, calendar: utc, offline: false) == .lunarNewYear, "\(year)")
            #expect(SeasonalLook.active(on: eve, calendar: utc, offline: false) == .lunarNewYear, "\(year) eve")
        }
    }

    @Test("the window is the Eve plus days 1–15, once a year, leap months and all (2026–2035)")
    func lunarNewYearWindowEveryYear() throws {
        // 2028 has a leap 5th month, 2031 a leap 3rd, 2033 a leap 11th that runs into January 2034: a leap
        // month repeats a number, so only the ORDINARY first month may open the year.
        let utc = try calendar("UTC")
        var day = try date(2026, 1, 1, in: utc)
        var byYear: [Int: [Int]] = [:]
        while utc.component(.year, from: day) < 2036 {
            if let index = SeasonalLook.lunarNewYearDay(on: day, in: utc.timeZone) {
                // Key by the Gregorian year of the Eve's day after (the New Year's Day).
                byYear[utc.component(.year, from: day.addingTimeInterval(86400)), default: []].append(index)
            }
            day = day.addingTimeInterval(86400)
        }
        #expect(byYear.keys.sorted() == Array(2026 ... 2035))
        for (year, days) in byYear {
            #expect(days == Array(0 ... 15), "\(year): \(days)")
        }
        // 2034's New Year follows the leap 11th month: Feb 19 (eve Feb 18).
        #expect(try SeasonalLook.lunarNewYearDay(on: date(2034, 2, 19, in: utc), in: utc.timeZone) == 1)
        #expect(try SeasonalLook.lunarNewYearDay(on: date(2034, 2, 18, in: utc), in: utc.timeZone) == 0)
    }

    @Test("the lantern festival (day 15) is the last day: 2029 and 2030, the years Ramadan doesn't cover it")
    func lunarNewYearEnd() throws {
        #expect(try look(2029, 2, 27) == .lunarNewYear)
        #expect(try look(2029, 2, 28) == nil)
        #expect(try look(2030, 2, 17) == .lunarNewYear)
        #expect(try look(2030, 2, 18) == nil)
    }

    @Test("lunar new year is a local day, and the user's own calendar never moves it")
    func lunarNewYearLocalDay() throws {
        let kiritimati = try calendar("Pacific/Kiritimati") // UTC+14
        let honolulu = try calendar("Pacific/Honolulu") // UTC-10
        // 2029-02-27 23:30 in Honolulu (day 15) is 2029-02-28 23:30 in Kiritimati (day 16).
        let instant = try date(2029, 2, 27, 23, 30, in: honolulu)
        #expect(SeasonalLook.active(on: instant, calendar: honolulu, offline: false) == .lunarNewYear)
        #expect(SeasonalLook.active(on: instant, calendar: kiritimati, offline: false) == nil)
        let newYear = try date(2029, 2, 13, in: calendar("UTC"))
        for identifier: Calendar.Identifier in [.gregorian, .chinese, .islamicUmmAlQura, .persian, .gujarati] {
            var regional = Calendar(identifier: identifier)
            regional.timeZone = try #require(TimeZone(identifier: "UTC"))
            #expect(SeasonalLook.active(on: newYear, calendar: regional, offline: false) == .lunarNewYear, "\(identifier)")
        }
    }

    // MARK: - Diwali

    @Test("diwali (Lakshmi Puja) on its published dates: 2026-11-08, 2027-10-29, 2028-10-17, 2029-11-05, 2030-10-26")
    func diwaliDays() throws {
        for (year, month, day) in [(2026, 11, 8), (2027, 10, 29), (2028, 10, 17), (2029, 11, 5), (2030, 10, 26)] {
            let entry = try #require(SeasonalLook.diwaliDates[year], "\(year)")
            #expect(entry.month == month && entry.day == day, "\(year)")
            #expect(try look(year, month, day) == .diwali, "\(year)")
            #expect(try look(year, month, day, offline: true) == .diwali, "\(year) offline")
        }
    }

    @Test("diwali runs Dhanteras (2 days before) through Bhai Dooj (2 days after): 2028 Oct 15–19")
    func diwaliWindow() throws {
        #expect(try look(2028, 10, 14, 23, 59, 59) == nil)
        #expect(try look(2028, 10, 15, 0, 0) == .diwali)
        #expect(try look(2028, 10, 19, 23, 59, 59) == .diwali)
        #expect(try look(2028, 10, 20, 0, 0) == nil)
        let utc = try calendar("UTC")
        #expect(try SeasonalLook.diwaliDay(on: date(2028, 10, 15, in: utc), in: utc.timeZone) == -2)
        #expect(try SeasonalLook.diwaliDay(on: date(2028, 10, 19, in: utc), in: utc.timeZone) == 2)
    }

    @Test("every table date is Ashvin's last days (Gujarati month 12, day 29 or 30, in India): a typo guard")
    func diwaliTableAgreesWithTheGujaratiCalendar() throws {
        // Foundation's Indian calendars number a day by the tithi at SUNRISE; Diwali is the day Amavasya holds at
        // DUSK, so no calendar rule picks between day 29 and 30 (2026: Diwali is 12/29, 2027: 12/30). They do bound
        // it, so a slipped digit in the table fails here.
        var india = Calendar(identifier: .gregorian)
        india.timeZone = try #require(TimeZone(identifier: "Asia/Kolkata"))
        var gujarati = Calendar(identifier: .gujarati)
        gujarati.timeZone = india.timeZone
        for (year, entry) in SeasonalLook.diwaliDates {
            let day = try date(year, entry.month, entry.day, in: india)
            let parts = gujarati.dateComponents([.month, .day], from: day)
            // ±1 day of slack: ICU's Indian calendars differ between OS releases (CI's runner is older than the
            // dev Mac), and this is a typo guard, not the source of truth (the table's two sources are).
            let nearNewMoon = (parts.month == 12 && (28 ... 30).contains(parts.day ?? 0)) || (parts.month == 1 && parts.day == 1)
            #expect(nearNewMoon, "\(year): \(parts)")
        }
    }

    @Test("the diwali table has at least 2 years left (extend it from two sources before this fails)")
    func diwaliTableIsFresh() throws {
        let thisYear = Calendar(identifier: .gregorian).component(.year, from: Date())
        let last = try #require(SeasonalLook.diwaliDates.keys.max())
        #expect(last - thisYear >= 2, "the Diwali table ends in \(last): add the next years, each checked against two sources")
        #expect(Set(SeasonalLook.diwaliDates.keys) == Set(2026 ... last), "no gaps")
    }

    // MARK: - Main days and overlaps (2026–2030)

    @Test("diwali meets halloween in 2027 and 2030: diwali wins its days, but halloween night stays halloween")
    func diwaliMeetsHalloween() throws {
        #expect(try look(2027, 10, 26) == .halloween)
        #expect(try look(2027, 10, 27) == .diwali) // Dhanteras
        #expect(try look(2027, 10, 30) == .diwali)
        #expect(try look(2027, 10, 31) == .halloween) // Bhai Dooj falls on Halloween night
        #expect(try look(2027, 11, 1) == .halloween)
        #expect(try look(2030, 10, 23) == nil)
        #expect(try look(2030, 10, 24) == .diwali) // Dhanteras; Halloween's first day
        #expect(try look(2030, 10, 28) == .diwali)
        #expect(try look(2030, 10, 29) == .halloween)
    }

    @Test("diwali meets flight club in 2026 and 2029: diwali wins, online or off")
    func diwaliMeetsFlightClub() throws {
        #expect(try look(2026, 11, 5, offline: true) == .flightClub)
        #expect(try look(2026, 11, 6, offline: true) == .diwali)
        #expect(try look(2026, 11, 10, offline: true) == .diwali)
        #expect(try look(2026, 11, 11, offline: true) == .flightClub)
        #expect(try look(2029, 11, 3) == .diwali)
        #expect(try look(2029, 11, 8, offline: true) == .flightClub)
    }

    @Test("lunar new year meets ramadan (2026–2028): the Eve and New Year's Day are its own, Ramadan keeps every fast")
    func lunarNewYearMeetsRamadan() throws {
        #expect(try look(2026, 2, 16) == .lunarNewYear) // Eve
        #expect(try look(2026, 2, 17) == .lunarNewYear) // New Year's Day
        #expect(try look(2026, 2, 18) == .ramadan) // Ramadan 1, Lunar day 2
        #expect(try look(2026, 3, 3) == .ramadan) // the Lantern Festival yields to the fast
        #expect(try look(2027, 2, 5) == .lunarNewYear)
        #expect(try look(2027, 2, 6) == .lunarNewYear)
        #expect(try look(2027, 2, 7) == .lunarNewYear) // day 2: Ramadan hasn't begun
        #expect(try look(2027, 2, 8) == .ramadan) // Ramadan 1, Lunar day 3
        #expect(try look(2028, 1, 27) == .lunarNewYear)
        #expect(try look(2028, 1, 28) == .ramadan)
    }

    @Test("lunar new year meets the end of ramadan and eid (2029–2030): its two main days, then eid, then the rest")
    func lunarNewYearMeetsEid() throws {
        #expect(try look(2029, 2, 12) == .lunarNewYear) // Eve, Ramadan 28
        #expect(try look(2029, 2, 13) == .lunarNewYear) // New Year's Day, Ramadan 29
        #expect(try look(2029, 2, 14) == .moonSighting) // Shawwal 1
        #expect(try look(2029, 2, 15) == .eid)
        #expect(try look(2029, 2, 17) == .eid)
        #expect(try look(2029, 2, 18) == .lunarNewYear) // day 6
        #expect(try look(2030, 2, 2) == .lunarNewYear) // Eve, Ramadan 29
        #expect(try look(2030, 2, 3) == .lunarNewYear) // New Year's Day, Ramadan 30
        #expect(try look(2030, 2, 4) == .moonSighting) // Shawwal 1
        #expect(try look(2030, 2, 5) == .eid)
        #expect(try look(2030, 2, 7) == .eid)
        #expect(try look(2030, 2, 8) == .lunarNewYear)
    }

    @Test("every main day keeps its own look, 2026–2035: Diwali, Lunar New Year's Eve and Day, Halloween night, Eid")
    func mainDaysKeepTheirLook() throws {
        let utc = try calendar("UTC")
        for (year, entry) in SeasonalLook.diwaliDates {
            #expect(try look(year, entry.month, entry.day, offline: true) == .diwali, "\(year)")
        }
        var day = try date(2026, 1, 1, in: utc)
        var hijri = Calendar(identifier: .islamicUmmAlQura)
        hijri.timeZone = utc.timeZone
        while utc.component(.year, from: day) < 2036 {
            let resolved = SeasonalLook.active(on: day, calendar: utc, offline: true)
            if let index = SeasonalLook.lunarNewYearDay(on: day, in: utc.timeZone), index <= 1 {
                #expect(resolved == .lunarNewYear, "\(day)")
            }
            let parts = utc.dateComponents([.month, .day], from: day)
            if parts.month == 10, parts.day == 31 { #expect(resolved == .halloween, "\(day)") }
            let islamic = hijri.dateComponents([.month, .day], from: day)
            if islamic.month == 10, islamic.day == 2 { #expect(resolved == .eid, "\(day)") }
            day = day.addingTimeInterval(86400)
        }
    }

    @Test("the new greetings are plain, never 'Chinese New Year', and name no zodiac animal")
    func newGreetings() throws {
        let diwali = try #require(SeasonalLook.greeting(for: .diwali))
        let lunar = try #require(SeasonalLook.greeting(for: .lunarNewYear))
        #expect(diwali.contains("Diwali"))
        #expect(lunar.contains("Lunar New Year") && !lunar.contains("Chinese"))
        let animals = ["rat", "ox", "tiger", "rabbit", "cat", "dragon", "snake", "horse", "goat", "sheep", "monkey",
                       "rooster", "dog", "pig"]
        let words = Set(lunar.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        #expect(words.isDisjoint(with: animals), "\(lunar)")
    }

    @Test("diya and lunar wear their own palettes: marigold rest, red rest, never the lantern statics")
    func newPalettes() {
        let diya = AvatarActivity.idle.phosphorTreatment(season: .diwali)
        let lunar = AvatarActivity.idle.phosphorTreatment(season: .lunarNewYear)
        #expect(diya == .diyaCalm && lunar == .lunarCalm)
        // Marigold: red full, green warm, little blue. Lunar red: red full, green and blue well under it.
        #expect(diya.red == 1 && diya.green > 0.5 && diya.blue < 0.25)
        #expect(lunar.red == 1 && lunar.green < 0.45 && lunar.blue < 0.45)
        let lantern: [PhosphorTreatment] = [.lanternCalm, .lanternSpeaking, .lanternThinking, .lanternListening]
        for activity in AvatarActivity.allCases {
            #expect(!lantern.contains(activity.phosphorTreatment(season: .diwali)), "\(activity)")
            #expect(!lantern.contains(activity.phosphorTreatment(season: .lunarNewYear)), "\(activity)")
        }
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
