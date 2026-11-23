//
//  SeasonalLook.swift
//  M1K3Avatar
//
//  The date-gated seasonal wardrobe. Halloween: Oct 24 00:00 through Nov 1 23:59:59 in
//  the USER's calendar (their time zone, not UTC), M1K3 wears a pumpkin / ember / violet
//  phosphor and greets you in costume. Pure and dependency-free so the window, the
//  opt-out and the launch-argument override are all unit-tested off-device; the shader
//  and the greeting are verify-by-launch.
//
//  Offline AI Flight Club: Nov 3 00:00 through Dec 1 23:59:59 (same local-Gregorian rules), but
//  ONLY while the device is offline — the companion wears flight colours and the greeting says it
//  keeps working. The network signal is an INPUT (`offline:`), never read here: the shells pass
//  `NetworkPathWatch.shared.isOffline`, so this file stays pure and the gate is unit-tested.
//
//  Launch argument: `M1K3 -seasonalLook <look>` (halloween, flightclub, christmas, ramadan, eid, nowruz,
//  stpatricks, lunarnewyear, diwali) forces the look on (flightclub
//  regardless of date AND network), `-seasonalLook none` forces it off (screenshots, store art,
//  verification). Read from the ARGUMENT domain only, like `GenerationActivity.isEnabled`: on
//  macOS 27 `defaults write` never reaches the sandboxed app, and a persisted key must never force
//  a look in a shipped build.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.85 (pure date maths pinned by
//  tests; the on-screen look is verify-by-launch). Prior: Unknown.
//  Review: Kev + claude-opus-5.5, 2026-10-11 — review fold: month/day are read on the GREGORIAN
//  calendar in the caller's zone (Calendar.current follows a Hebrew/Islamic/Persian/Chinese
//  regional calendar, whose month 10 is another season); the launch override is read once
//  (`launchOverride`, the avatar resolves ~30 Hz); `now(enabled:offline:)` is the shells' one call, on
//  `.autoupdatingCurrent` so a traveller's zone follows them. Confidence 0.9.
//  Review: Kev + claude-opus-5.5, 2026-10-11 (CI fold) — the costume line moves here from the shared
//  M1K3App/SeasonalGreeting.swift (`greeting(for:)`, tested): a new Mac-shell file compiled by the
//  mobile target is a landing-gate change (MOBILE_PATH_PREFIXES); a package function is not.
//  Confidence 0.9.
//  Review: Kev + claude-sonnet-5.5, 2026-10-22 — Offline AI Flight Club: `.flightClub` (Nov 3 – Dec 1, offline
//  only, Halloween checked first), `Override.flightClub`, and a REQUIRED `offline:` on active / resolve / now
//  (no default, so the compiler finds every call site). Copy promises only what ships: flight colours + one
//  greeting while offline. Confidence 0.85 (maths pinned; the look and real Airplane Mode are verify-on-device).
//  Review: claude-opus-5-5, 2026-11-19 — localisation Phase 0: the costume lines resolve from M1K3Avatar's catalog
//  (`bundle: .module`); they are card copy, never chat history. English unchanged.
//
//  Review: Kev + claude-opus-5-5, 2026-11-23 (Kev: "do them as often as possible and capitalize on the reach") — the
//  seasonal calendar: Christmas / New Year (Dec 2 – Jan 7, the day after Flight Club through Orthodox Christmas),
//  Ramadan (Umm al-Qura month 9) and Eid al-Fitr (Shawwal 1–3), Nowruz (Farvardin 1–7), St Patrick's (Mar 14–17).
//  The Halloween event drew 10–18k search impressions a day in PK / KZ / DZ / IN / IQ / UZ, so the calendar follows
//  those storefronts' feasts. Ramadan, Eid and Nowruz read their own calendars (no date table to rot); the user's
//  regional calendar is never used for any window. Overlaps: Halloween, Eid, St Patrick's, Nowruz, Ramadan,
//  Christmas, Flight Club — a short feast wins a long season, Eid wins Nowruz (2026). `Override` is now `.look(_)` or
//  `.off`, so a new look needs no new override case. Umm al-Qura is Saudi Arabia's reckoning: a country that sights
//  the moon can begin a day either side. Ramadan and Eid wear no villain costume: lantern gold and quiet lines.
//  Confidence 0.8 (maths pinned in SeasonalCalendarTests; the looks are verify-by-launch).
//  Review: Kev + claude-opus-5-5, 2026-11-23 (pre-push review fold) — Pakistan and India sight the moon a day or two
//  after Umm al-Qura, so "Eid Mubarak" on Saudi Shawwal 1 lands on their last fast day. Ramadan 29–30 and Shawwal 1 are
//  now `.moonSighting`: the lantern look with a line true on both days. Ramadan's greeting runs days 1–28 and Eid's
//  Shawwal 2–4. `now` memoises per (zone, minute, inputs): it is read ~30 Hz and built three calendars a call.
//  Confidence 0.8.
//  Review: Kev + claude-opus-5-5, 2026-11-23 (Kev: events "as often as possible"; India is a top-3 reach country, and
//  zh-Hans / ko / vi users matter) — Lunar New Year (Chinese calendar: the Eve through the Lantern Festival, day 15; the
//  ordinary first month only, never a leap one) and Diwali (Dhanteras through Bhai Dooj: Lakshmi Puja ± 2 days, from a
//  dated table, `diwaliDates`, because no Foundation calendar names the day: see the table). Both DO overlap other looks
//  in 2026–2030 (Diwali meets Halloween in 2027 and 2030 and Flight Club in 2026 and 2029; Lunar New Year meets Ramadan
//  or Eid every year from 2026 to 2031), so the order grows a first rule: a feast's MAIN days keep their own look.
//  Halloween night, Diwali's five days, and Lunar New Year's Eve and Day go first; the rest of Lunar New Year yields to
//  Ramadan and Eid, so the Ramadan event's "Through Ramadan" stays true. Confidence 0.75 (maths pinned in
//  SeasonalCalendarTests; the precedence is a judgement call Kev may flip; the looks are verify-by-launch).
//  Review: Kev + claude-opus-5-5, 2026-11-23 (Kev: "Halloween wins...") — Halloween's whole season (Oct 24 – Nov 1) now
//  comes before Diwali: Diwali 2027 and 2030 show Halloween throughout; other years keep all five Diwali days.
//  Confidence 0.85 (pinned for 2026–2035).
//

import Foundation
import Synchronization

public enum SeasonalLook: String, Sendable, CaseIterable {
    case halloween
    /// Offline AI Flight Club — Nov 3 – Dec 1, only while offline.
    case flightClub = "flightclub"
    /// Christmas and New Year — Dec 2 – Jan 7 (through Orthodox Christmas).
    case christmas
    /// Ramadan — days 1–28 of the ninth month of the Umm al-Qura calendar.
    case ramadan
    /// The moon-sighting days — Ramadan 29–30 and Shawwal 1, when Eid may or may not have begun where the user is.
    case moonSighting = "moonsighting"
    /// Eid al-Fitr — Shawwal 2–4 (a day late for Saudi Arabia, on time for moon-sighting countries).
    case eid
    /// Nowruz / Nauryz — Farvardin 1–7 of the Persian calendar.
    case nowruz
    /// St Patrick's — Mar 14–17, the Dublin festival days.
    case stPatricks = "stpatricks"
    /// Lunar New Year (Spring Festival, Seollal, Tết) — the Eve through the Lantern Festival, Chinese calendar.
    case lunarNewYear = "lunarnewyear"
    /// Diwali / Deepavali — Dhanteras through Bhai Dooj: Lakshmi Puja ± 2 days (`diwaliDates`).
    case diwali

    /// Launch-argument key: `-seasonalLook <look> | none` (a look's raw value, any case).
    public static let overrideKey = "seasonalLook"

    /// A forced answer from the launch argument.
    public enum Override: Sendable, Hashable {
        case look(SeasonalLook)
        case off

        public static let halloween = Override.look(.halloween)
        public static let flightClub = Override.look(.flightClub)

        public init?(argument: String?) {
            guard let word = argument?.lowercased() else { return nil }
            if word == "none" {
                self = .off
            } else if let season = SeasonalLook(rawValue: word) {
                self = .look(season)
            } else {
                return nil
            }
        }

        /// The override in `defaults`' ARGUMENT domain; nil when absent or unrecognised.
        public init?(in defaults: UserDefaults) {
            let raw = defaults.volatileDomain(forName: UserDefaults.argumentDomain)[SeasonalLook.overrideKey]
            self.init(argument: raw as? String)
        }
    }

    /// The look in season on `date` in `calendar`'s time zone, else nil. `offline` gates Flight Club
    /// only. Each window is read on its OWN calendar in the caller's zone, never the caller's calendar
    /// system. Order: Halloween's whole season first (Kev, 2026-11-23: "Halloween wins"); then a
    /// feast's main days keep their own look (Diwali's five days, all of them feast days; Lunar New
    /// Year's Eve and Day). Then a short feast wins a long season (Eid, St Patrick's, Nowruz, then
    /// Ramadan, the rest of Lunar New Year, Christmas, Flight Club; the moon-sighting days sit with
    /// Eid, under Lunar New Year's Day).
    ///
    /// Why (2026–2031 all collide): Halloween's event is M1K3's biggest reach (10–18k impressions a
    /// day), so it keeps Oct 24 – Nov 1 unbroken; Diwali 2027 and 2030 fall wholly inside it and get no
    /// look those years (2026 and 2029 beat Flight Club; 2028 is clear). Lunar New Year (16 days) meets Ramadan
    /// or Eid every year from 2026: its Eve and Day win, its tail yields to the fast and to Eid, so the
    /// Ramadan event's "Through Ramadan" stays true and each feast keeps the days its people mark most.
    public static func active(on date: Date, calendar: Calendar, offline: Bool) -> SeasonalLook? {
        let zone = calendar.timeZone
        let gregorian = parts(of: date, on: .gregorian, in: zone)
        let hijri = parts(of: date, on: .islamicUmmAlQura, in: zone)
        let persian = parts(of: date, on: .persian, in: zone)
        let lunar = lunarNewYearDay(on: date, in: zone)
        if case (10, 24...) = gregorian { return .halloween }
        if case (11, 1) = gregorian { return .halloween }
        if diwaliDay(on: date, in: zone) != nil { return .diwali }
        if case (10, 2 ... 4) = hijri { return .eid }
        if let lunar, lunar <= 1 { return .lunarNewYear }
        if case (9, 29 ... 30) = hijri { return .moonSighting }
        if case (10, 1) = hijri { return .moonSighting }
        if case (3, 14 ... 17) = gregorian { return .stPatricks }
        if case (1, 1 ... 7) = persian { return .nowruz }
        if case (9, 1 ... 28) = hijri { return .ramadan }
        if lunar != nil { return .lunarNewYear }
        if case (12, 2...) = gregorian { return .christmas }
        if case (1, 1 ... 7) = gregorian { return .christmas }
        if case (11, 3...) = gregorian { return offline ? .flightClub : nil }
        if case (12, 1) = gregorian { return offline ? .flightClub : nil }
        return nil
    }

    /// Month and day of `date` on `identifier`'s calendar in `zone`; (0, 0) if it cannot say.
    private static func parts(of date: Date, on identifier: Calendar.Identifier, in zone: TimeZone) -> (month: Int, day: Int) {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.month, .day], from: date)
        return (parts.month ?? 0, parts.day ?? 0)
    }

    /// Lunar New Year on `date`'s local day: 0 on New Year's Eve, 1–15 from New Year's Day through the
    /// Lantern Festival, else nil. Only the ORDINARY first month opens the year: a leap month repeats a
    /// month's number (2033's leap 11th runs into January 2034), so `isLeapMonth` must be false.
    static func lunarNewYearDay(on date: Date, in zone: TimeZone) -> Int? {
        var chinese = Calendar(identifier: .chinese)
        chinese.timeZone = zone
        let today = chinese.dateComponents([.month, .day, .isLeapMonth], from: date)
        if today.month == 1, today.isLeapMonth == false, let day = today.day, day <= 15 { return day }
        // The Eve is the twelfth month's last day, its 29th or 30th: ask the calendar whether tomorrow is New Year.
        guard today.month == 12, (today.day ?? 0) >= 29,
              let tomorrow = chinese.date(byAdding: .day, value: 1, to: date) else { return nil }
        let next = chinese.dateComponents([.month, .day, .isLeapMonth], from: tomorrow)
        return next.month == 1 && next.day == 1 && next.isLeapMonth == false ? 0 : nil
    }

    /// Lakshmi Puja, Diwali's main day, by Gregorian year: the date India keeps (Amavasya at dusk, New Delhi).
    ///
    /// A table, not a calendar: Foundation's Indian lunisolar calendars (`.gujarati`, `.vikram`, … macOS 15+)
    /// number a day by the tithi at SUNRISE, but Diwali is the evening Amavasya holds, so it lands on Ashvin 29
    /// in some years and Ashvin 30 in others (2026: 12/29, 2027: 12/30 on `.gujarati` in Asia/Kolkata), and
    /// the Gujarati new year is not always the next day (2026: Diwali Nov 8, Bestu Varas Nov 10). Probed
    /// 2026-11-23: no calendar rule reproduced all five of 2026–2030, and the answer moved with the time zone.
    ///
    /// Sources, checked 2026-11-23: drikpanchang.com/diwali/diwali-puja-calendar.html?year=N (2026–2031) and
    /// timeanddate.com/holidays/india/diwali (2026–2031); for 2032–2035, testbook.com/articles/
    /// diwali-dates-for-next-20-years and calendardate.com/diwali_N.htm (that site's own 2029 page is
    /// inconsistent; drikpanchang and timeanddate agree on Nov 5). SeasonalCalendarTests fails two years
    /// before the table runs out: extend it from two sources.
    static let diwaliDates: [Int: (month: Int, day: Int)] = [
        2026: (11, 8), 2027: (10, 29), 2028: (10, 17), 2029: (11, 5), 2030: (10, 26),
        2031: (11, 14), 2032: (11, 2), 2033: (10, 22), 2034: (11, 10), 2035: (10, 30),
    ]

    /// Days from Lakshmi Puja on `date`'s local day, -2 (Dhanteras) through 2 (Bhai Dooj), else nil.
    /// Dhanteras falls 1–2 days before and Bhai Dooj 2–3 after (2026: Nov 6 and Nov 11), so the window is
    /// the five days centred on the main day.
    static func diwaliDay(on date: Date, in zone: TimeZone) -> Int? {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = zone
        let today = gregorian.dateComponents([.year, .month, .day], from: date)
        guard let year = today.year, let puja = diwaliDates[year] else { return nil }
        // Whole days between two civil dates, counted at UTC noon so no daylight-saving hour can shave one off.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        guard let day = utc.date(from: DateComponents(year: year, month: today.month, day: today.day, hour: 12)),
              let main = utc.date(from: DateComponents(year: year, month: puja.month, day: puja.day, hour: 12)),
              let offset = utc.dateComponents([.day], from: main, to: day).day,
              (-2 ... 2).contains(offset) else { return nil }
        return offset
    }

    /// The look to wear: a launch override wins (regardless of date and network), then the user's
    /// opt-out, then the date and the network.
    public static func resolve(on date: Date, calendar: Calendar, enabled: Bool, offline: Bool, override: Override?) -> SeasonalLook? {
        switch override {
        case let .look(season): season
        case .off: nil
        case nil: enabled ? active(on: date, calendar: calendar, offline: offline) : nil
        }
    }

    /// The one line M1K3 says in costume (at most 70 characters), nil out of season. Copy only:
    /// the persona / system prompt is untouched (prompt edits have measured security costs).
    public static func greeting(for season: SeasonalLook?) -> String? {
        switch season {
        case .halloween:
            String(
                localized: "Happy Halloween! I carved the pumpkin; you bring the questions.",
                bundle: .module,
                comment: "Seasonal greeting shown 24 Oct - 1 Nov. M1K3 is a theatrical villain who is entirely on the user's side; keep it playful and family-safe, one short line."
            )
        case .flightClub:
            String(
                localized: "Offline? I'm still right here, on your device.",
                bundle: .module,
                comment: "Seasonal greeting shown 3 Nov - 1 Dec, ONLY while the device is offline (Offline AI Flight Club). M1K3 is a theatrical villain who is entirely on the user's side; keep it playful, honest (it must be true when offline, even with no brain downloaded yet, so it promises presence, never answers) and family-safe, one short line of at most 70 characters."
            )
        case .christmas:
            String(
                localized: "Merry Christmas! I made the nice list this year. Mostly.",
                bundle: .module,
                comment: "Greeting shown 2 Dec - 7 Jan (Christmas, New Year). M1K3 is a playful villain on the user's side; family-safe, one line, at most 70 characters."
            )
        case .ramadan:
            String(
                localized: "Ramadan Kareem. I'm here whenever you need me, day or night.",
                bundle: .module,
                comment: "Greeting shown during Ramadan. Respectful and warm, NO villain play or jokes; 'Ramadan Kareem' is customary. One line, at most 70 characters."
            )
        case .eid:
            String(
                localized: "Eid Mubarak! Wishing you and yours a joyful Eid.",
                bundle: .module,
                comment: "Greeting shown on the first three days of Eid al-Fitr. Warm, respectful, NO villain play; 'Eid Mubarak' is customary. One line, at most 70 characters."
            )
        case .moonSighting:
            String(
                localized: "Wishing you and yours peace and blessings.",
                bundle: .module,
                comment: "Greeting for the last days of Ramadan and Eid's first day, when either may be true; must name neither. Respectful, NO villain play, at most 70 characters."
            )
        case .nowruz:
            String(
                localized: "Happy Nowruz! A new spring, a fresh start.",
                bundle: .module,
                comment: "Greeting for the first 7 days of Nowruz (Nauryz in Kazakhstan, Navruz in Uzbekistan); use the local name. Warm, family-safe, at most 70 characters."
            )
        case .stPatricks:
            String(
                localized: "Happy St Patrick's Day from an AI made in Ireland!",
                bundle: .module,
                comment: "Seasonal greeting shown 14-17 March. M1K3 is made in Ireland (true: Round Tower, Ireland). Playful and family-safe, one short line of at most 70 characters."
            )
        case .lunarNewYear:
            String(
                localized: "Happy Lunar New Year! Wishing you luck and good health.",
                bundle: .module,
                comment: "Greeting from Lunar New Year's Eve through the Lantern Festival (Spring Festival, Seollal, Tết). Say Lunar New Year or the local name, NEVER 'Chinese New Year'; name no zodiac animal. Warm, plain, NO villain play, at most 70 characters."
            )
        case .diwali:
            String(
                localized: "Happy Diwali! May your home be full of light.",
                bundle: .module,
                comment: "Greeting for the five days of Diwali (Deepavali in South India, Malaysia and Singapore), Dhanteras to Bhai Dooj. Warm, plain, NO villain play, at most 70 characters."
            )
        case nil:
            nil
        }
    }

    /// The launch-argument override, read once: the argument domain is fixed at launch, and the
    /// avatar resolves the season on every sync.
    public static let launchOverride: Override? = Override(in: .standard)

    /// The look to wear right now — the shells' one call. `enabled` is the Seasonal looks
    /// opt-out the caller already observes (`@AppStorage(CompanionDefaults.seasonalLooksKey)`);
    /// `offline` is `NetworkPathWatch.shared.isOffline`, read where the view observes it.
    public static func now(enabled: Bool, offline: Bool) -> SeasonalLook? {
        let date = Date()
        let calendar = Calendar.autoupdatingCurrent
        let key = Memo.Key(zone: calendar.timeZone.identifier, minute: Int(date.timeIntervalSince1970 / 60),
                           enabled: enabled, offline: offline, override: launchOverride)
        return memo.value(for: key) {
            resolve(on: date, calendar: calendar, enabled: enabled, offline: offline, override: launchOverride)
        }
    }

    private static let memo = Memo()

    /// The last answer, keyed by everything it depends on. A window only moves at a local midnight,
    /// so a minute bucket is exact to the minute and spares the five calendars on every frame.
    final class Memo: Sendable {
        struct Key: Hashable {
            let zone: String
            let minute: Int
            let enabled: Bool
            let offline: Bool
            let override: Override?
        }

        private let last = Mutex<(key: Key, value: SeasonalLook?)?>(nil)

        func value(for key: Key, compute: () -> SeasonalLook?) -> SeasonalLook? {
            if let hit = last.withLock({ $0 }), hit.key == key { return hit.value }
            let value = compute()
            last.withLock { $0 = (key, value) }
            return value
        }
    }
}
