//
//  season_days.swift
//  tools/asc
//
//  The app's seasonal looks, day by day, for `events.py next` and `events.py check`. events.py
//  compiles this file WITH the app's own `Sources/M1K3Avatar/SeasonalLook.swift` (plain swiftc,
//  never part of the package), so an event is dated to the window the app actually wears: no
//  calendar rule (Umm al-Qura, Persian, Gregorian, or the precedence between looks) is copied
//  here or in Python. A look added to SeasonalLook shows up here with no edit.
//
//    season_days <yyyy-mm-dd> <days>   →   {"days": {"yyyy-mm-dd": "<look>", …}, "looks": [every case]}
//
//  Each day is read at noon UTC on a UTC calendar, which is that LOCAL day's look in every zone:
//  every window in SeasonalLook is a local-day window. The scan asks as an OFFLINE device, which
//  adds Flight Club (offline-only, checked last) and changes nothing else.
//
//  Signed: Kev + claude-opus-5-5, 2026-11-23, Confidence 0.85 (output pinned by test_events.py's
//  darwin test against the published 2028 dates; it breaks loudly, not silently, if SeasonalLook.swift
//  starts using a type from another file: add that file to events.py's SEASON_SOURCES).
//  Prior: Unknown (new file).
//  Review: Kev + claude-opus-5-5, 2026-11-23 (pre-commit SwiftLint) — a long guard wrapped, and the JSON goes to
//  stdout as Data instead of through String(decoding:). Output unchanged. Confidence 0.9.
//

import Foundation

/// SwiftPM generates `Bundle.module` for M1K3Avatar; a bare swiftc build has none. Only the
/// greetings read it, and nothing here asks for one.
extension Bundle {
    static let module = Bundle.main
}

@main
enum SeasonDays {
    static func main() {
        let args = CommandLine.arguments
        guard args.count == 3, let count = Int(args[2]), (1 ... 5000).contains(count) else {
            fail("usage: season_days <yyyy-mm-dd> <days (1-5000)>")
        }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        let ymd = args[1].split(separator: "-").compactMap { Int($0) }
        guard ymd.count == 3,
              let first = utc.date(from: DateComponents(year: ymd[0], month: ymd[1], day: ymd[2], hour: 12)),
              stamp(first, on: utc) == args[1]
        else {
            fail("not a date: \(args[1]) (yyyy-mm-dd)")
        }
        var days: [String: String] = [:]
        for offset in 0 ..< count {
            guard let day = utc.date(byAdding: .day, value: offset, to: first) else {
                fail("no day \(offset) after \(args[1])")
            }
            if let look = SeasonalLook.active(on: day, calendar: utc, offline: true) {
                days[stamp(day, on: utc)] = look.rawValue
            }
        }
        let body: [String: Any] = ["looks": SeasonalLook.allCases.map(\.rawValue), "days": days]
        do {
            let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        } catch {
            fail("json: \(error)")
        }
    }

    private static func stamp(_ date: Date, on calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(2)
    }
}
