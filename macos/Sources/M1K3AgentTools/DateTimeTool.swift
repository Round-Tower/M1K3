//
//  DateTimeTool.swift
//  M1K3AgentTools
//
//  Local models have no clock — "what's the date?" is unanswerable without
//  this. The describer is pure (deterministic under injected Date/TimeZone/
//  Locale); the tool wraps it with an injectable `now` so tests pin exact
//  strings and the app gets the real clock by default.
//
//  Signed: Kev + claude-fable-5, 2026-06-09, Confidence 0.9, Prior: Unknown
//  Review: Kev + claude-opus-5-5, 2026-09-27 — the tool returns a `reading`: the line
//  plus the values people ask for next (until midnight, tomorrow's date). 375 read 13:55
//  and answered "3 hours and 15 minutes until midnight"; a small model quotes arithmetic
//  well and does it badly (#429). Until-midnight is real elapsed time, so a DST day is
//  23 or 25 hours. Confidence 0.9.

import Foundation
import M1K3Agent
import M1K3Inference

/// Pure date → human-sentence formatting, exact under injected inputs.
enum DateTimeDescriber {
    /// "Tuesday, 9 June 2026, 15:32 (Europe/Dublin)"
    static func describe(_ date: Date, timeZone: TimeZone, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE, d MMMM yyyy, HH:mm"
        return "\(formatter.string(from: date)) (\(timeZone.identifier))"
    }

    /// `describe` plus the follow-ups a model would otherwise compute:
    /// "…15:32 (Europe/Dublin)\nUntil midnight: 8 hours and 28 minutes. Tomorrow is Wednesday, 10 June."
    /// "Until midnight:" and "Tomorrow is" stay English whatever the locale (the model reads
    /// them, the user never does); the weekday and month names follow `locale`, as in `describe`.
    /// Not handled: a zone whose DST jump skips 00:00 itself (none in the current tz
    /// database) would count to the day's first valid instant.
    static func reading(_ date: Date, timeZone: TimeZone, locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // Count from the minute `describe` shows, so the two lines agree.
        let shown = calendar.dateInterval(of: .minute, for: date)?.start ?? date
        let today = calendar.startOfDay(for: shown)
        let line = describe(date, timeZone: timeZone, locale: locale)
        // Unreachable for real zones; without a midnight the reading is just the line.
        guard let midnight = calendar.date(byAdding: .day, value: 1, to: today) else { return line }
        let minutes = Int(midnight.timeIntervalSince(shown) / 60)
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE, d MMMM"
        return line
            + "\nUntil midnight: \(duration(minutes: minutes)). Tomorrow is \(formatter.string(from: midnight))."
    }

    /// "1 hour and 1 minute", "59 minutes", "24 hours".
    static func duration(minutes: Int) -> String {
        let hours = minutes / 60, rest = minutes % 60
        let parts = [
            hours > 0 ? "\(hours) hour\(hours == 1 ? "" : "s")" : nil,
            rest > 0 ? "\(rest) minute\(rest == 1 ? "" : "s")" : nil,
        ].compactMap(\.self)
        return parts.joined(separator: " and ")
    }
}

public struct DateTimeTool: AgentTool {
    public let name = "datetime"
    public let description =
        "Get the current date and time on \(HostPlatform.thisDevice). Argument: optional, ignored."
    public let parameters = [
        ToolParameter(name: "query", description: "ignored"),
    ]

    private let now: @Sendable () -> Date
    private let timeZone: TimeZone
    private let locale: Locale

    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) {
        self.now = now
        self.timeZone = timeZone
        self.locale = locale
    }

    public func execute(input _: [String: String]) async throws -> ToolResult {
        ToolResult(output: DateTimeDescriber.reading(now(), timeZone: timeZone, locale: locale))
    }
}
