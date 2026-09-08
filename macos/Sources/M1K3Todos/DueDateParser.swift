//
//  DueDateParser.swift
//  M1K3Todos
//
//  The Add field's one trick: a TRAILING due phrase comes off the title and
//  becomes a date — "by friday", "tomorrow", "in 3 days", "next week",
//  "on 14 sep", "3/10", "2026-10-03". Trailing only, so "Buy the Friday
//  paper" keeps its Friday; weekdays need by/on/next so a bare noun is never
//  mistaken for a deadline. A due date is the END of that local day: "due
//  today" holds all day, overdue begins at midnight (TodoGroundingBlock's
//  bands read whole days off the clock, so this lines the two up).
//
//  Pure: clock and calendar injected; the app passes Date() + .current.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-08, Confidence 0.85 (every
//  phrase pinned by DueDateParserTests under a UTC calendar; the phrase set
//  is deliberately small — grow it from what Kev actually types).
//  Prior: none (new file).
//

import Foundation

public enum DueDateParser {
    public static func parse(_ text: String, now: Date, calendar: Calendar) -> (title: String, due: Date?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for rule in rules {
            guard let match = rule.regex.firstMatch(
                in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)
            ) else { continue }
            let groups = (1 ..< match.numberOfRanges).map { i -> String in
                guard let r = Range(match.range(at: i), in: trimmed) else { return "" }
                return String(trimmed[r]).lowercased()
            }
            guard let day = rule.resolve(groups, now, calendar) else { continue }
            var title = String(trimmed[..<Range(match.range, in: trimmed)!.lowerBound])
            title = title.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-–—"))
            // A draft that is only the phrase keeps it as its title (review
            // fold): stripping it would hand the caller an empty title and
            // the todo would vanish without a word.
            guard !title.isEmpty else { return (trimmed, nil) }
            return (title, endOfDay(day, calendar))
        }
        return (trimmed, nil)
    }

    // MARK: - Rules (each anchored at the END of the title)

    /// NSRegularExpression is immutable after init (documented thread-safe);
    /// the resolver closures capture nothing mutable.
    private struct Rule: @unchecked Sendable {
        let regex: NSRegularExpression
        let resolve: @Sendable ([String], Date, Calendar) -> Date?
    }

    private static let weekdays = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    private static func rule(
        _ pattern: String, _ resolve: @escaping @Sendable ([String], Date, Calendar) -> Date?
    ) -> Rule? {
        // A leading separator (space or comma) is part of the match so it
        // comes off the title with the phrase.
        let full = "(?:^|[\\s,]+)(?:by\\s+|on\\s+|due\\s+)?" + pattern + "\\s*$"
        // A pattern that fails to compile drops its rule (nil) — the table is
        // hand-written and pinned, so this never fires; no force-try.
        guard let regex = try? NSRegularExpression(pattern: full, options: [.caseInsensitive]) else { return nil }
        return Rule(regex: regex, resolve: resolve)
    }

    private static let rules: [Rule] = [Rule?]([
        rule("(today|tomorrow)") { g, now, cal in
            cal.date(byAdding: .day, value: g[0] == "today" ? 0 : 1, to: now)
        },
        rule("in\\s+(\\d{1,3})\\s+(day|days|week|weeks)") { g, now, cal in
            guard let n = Int(g[0]) else { return nil }
            return cal.date(byAdding: .day, value: g[1].hasPrefix("week") ? n * 7 : n, to: now)
        },
        rule("next\\s+week") { _, now, cal in cal.date(byAdding: .day, value: 7, to: now) },
        // "by friday" / "on tue" / "next friday" — the by/on is consumed by
        // the shared prefix; "next" is captured to push a week out.
        // Weekdays REQUIRE by/on/next: "Denis's wedding" must not read as
        // Wednesday. The abbreviation is whole-word (wed, weds? no — wed,
        // wednesday), never a prefix of another word.
        rule("(by|on|next)\\s+(sun|mon|tue|wed|thu|fri|sat)(?:day|sday|nesday|rsday|urday)?\\b") { g, now, cal in
            guard let target = weekdays.firstIndex(of: g[1]) else { return nil }
            let today = cal.component(.weekday, from: now) - 1 // Sunday = 0
            var ahead = (target - today + 7) % 7
            if g[0] == "next" { ahead += 7 }
            return cal.date(byAdding: .day, value: ahead, to: now)
        },
        rule("(\\d{4})-(\\d{2})-(\\d{2})") { g, _, cal in
            guard let y = Int(g[0]), let m = Int(g[1]), let d = Int(g[2]) else { return nil }
            return validDate(year: y, month: m, day: d, cal)
        },
        // Month names are a CLOSED alternation + word boundary (the weekday
        // rule's shape): "Buy 2 novels" is not November, "maybe" is not May.
        rule("(\\d{1,2})\\s+\(monthPattern)") { g, now, cal in
            monthDay(day: g[0], month: g[1], now: now, cal)
        },
        rule("\(monthPattern)\\s+(\\d{1,2})") { g, now, cal in
            monthDay(day: g[1], month: g[0], now: now, cal)
        },
        rule("(\\d{1,2})/(\\d{1,2})") { g, now, cal in
            guard let d = Int(g[0]), let m = Int(g[1]) else { return nil }
            return nextOccurrence(day: d, month: m, now: now, cal)
        },
    ]).compactMap { $0 }

    private static let monthPattern = "(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?"
        + "|aug(?:ust)?|sep(?:t|tember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\\b"

    private static func monthDay(day: String, month: String, now: Date, _ cal: Calendar) -> Date? {
        guard let d = Int(day), let m = months.firstIndex(of: String(month.prefix(3))) else { return nil }
        return nextOccurrence(day: d, month: m + 1, now: now, cal)
    }

    /// The date only if the components are real (Gregorian `date(from:)`
    /// silently normalises month 13 / day 32 — reject those instead).
    private static func validDate(year: Int, month: Int, day: Int, _ cal: Calendar) -> Date? {
        guard let date = cal.date(from: DateComponents(year: year, month: month, day: day)),
              cal.component(.day, from: date) == day, cal.component(.month, from: date) == month
        else { return nil }
        return date
    }

    /// This year's date, or next year's once it has passed (today counts).
    private static func nextOccurrence(day: Int, month: Int, now: Date, _ cal: Calendar) -> Date? {
        let year = cal.component(.year, from: now)
        for y in [year, year + 1] {
            guard let date = validDate(year: y, month: month, day: day, cal) else { continue }
            if cal.startOfDay(for: date) >= cal.startOfDay(for: now) { return date }
        }
        return nil
    }

    /// Calendar arithmetic, not 86 399 raw seconds: a DST day is 23 or 25
    /// hours long and a fixed interval lands an hour off local 23:59:59
    /// (review fold; pinned against Europe/Dublin's two transition days).
    private static func endOfDay(_ date: Date, _ cal: Calendar) -> Date {
        let start = cal.startOfDay(for: date)
        return cal.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? start
    }
}
