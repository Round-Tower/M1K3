//
//  SeasonalEventSpecTests.swift
//  M1K3AvatarTests
//
//  The App Store event specs against the app's own windows. A yearly spec
//  (`macos/fastlane/events/*/event.json` with `"looks"`) may be live only while the app wears one of
//  its looks, from UTC−10 (where the 10:00Z start is local midnight) to UTC+14 (where a 10:00Z end
//  is): an event live on a day the look is off shows the store a look the app doesn't have.
//  `events.py next` dates the specs from this same SeasonalLook (it compiles SeasonalLook.swift), and
//  this test is the guard for a hand edit, a look whose window moved, or a spec dated before its look.
//
//  Signed: Kev + claude-opus-5-5, 2026-11-23, Confidence 0.85 (reads the real specs; the look windows
//  are pinned by SeasonalCalendarTests). Prior: Unknown (new file).
//

import Foundation
@testable import M1K3Avatar
import Testing

struct SeasonalEventSpecTests {
    private struct Spec: Decodable {
        let referenceName: String
        let eventStart: String
        let eventEnd: String
        let looks: [String]?
    }

    /// Built to the older eastern edge, UTC+13 (NZ daylight time; test_events.py pins both), before the
    /// calendar moved the edge to UTC+14 on 2026-11-23. Keyed by referenceName, so `events.py next --write`
    /// (a new year in the name) puts a re-dated spec under the UTC+14 rule.
    private static let easternEdgeUTC13: Set<String> = ["halloween-2026", "offline-ai-flight-club-2026"]

    private static let eventsDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // M1K3AvatarTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // macos
        .appending(path: "fastlane/events")

    private static func specs() throws -> [(name: String, spec: Spec)] {
        let dirs = try FileManager.default.contentsOfDirectory(at: eventsDir, includingPropertiesForKeys: nil)
        var out: [(name: String, spec: Spec)] = []
        for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let file = dir.appending(path: "event.json")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            try out.append((dir.lastPathComponent, JSONDecoder().decode(Spec.self, from: Data(contentsOf: file))))
        }
        return out
    }

    /// Each instant in [start, end) at which the app, in a zone `hours` from UTC, wears none of `looks`.
    /// Checked at the start, every local midnight inside, and the last second: a look changes only at a
    /// local midnight.
    private static func strays(start: Date, end: Date, looks: Set<SeasonalLook>, hours: Int) throws -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: hours * 3600))
        var instants = [start]
        var midnight = calendar.startOfDay(for: start)
        while let next = calendar.date(byAdding: .day, value: 1, to: midnight), next < end {
            instants.append(next)
            midnight = next
        }
        instants.append(end.addingTimeInterval(-1))
        return instants.compactMap { instant in
            let look = SeasonalLook.active(on: instant, calendar: calendar, offline: true)
            if let look, looks.contains(look) { return nil }
            return "UTC\(hours >= 0 ? "+" : "")\(hours) at \(instant): the app wears \(look?.rawValue ?? "nothing")"
        }
    }

    @Test("the yearly event specs name their looks")
    func yearlySpecsNameTheirLooks() throws {
        let yearly = try Set(Self.specs().filter { $0.spec.looks != nil }.map(\.name))
        #expect(yearly.isSuperset(of: ["christmas", "flight-club", "halloween", "nowruz", "ramadan", "st-patricks"]))
    }

    @Test("every yearly event is live only while the app wears one of its looks, from UTC-10 to UTC+14")
    func eventsSitInsideTheirLooks() throws {
        let iso = ISO8601DateFormatter()
        for (name, spec) in try Self.specs() {
            guard let names = spec.looks else { continue }
            var looks = Set<SeasonalLook>()
            for raw in names {
                try looks.insert(#require(SeasonalLook(rawValue: raw), "\(name): the app has no look \(raw)"))
            }
            let start = try #require(iso.date(from: spec.eventStart), "\(name): eventStart")
            let end = try #require(iso.date(from: spec.eventEnd), "\(name): eventEnd")
            let east = Self.easternEdgeUTC13.contains(spec.referenceName) ? 13 : 14
            for hours in [-10, east] {
                let strays = try Self.strays(start: start, end: end, looks: looks, hours: hours)
                #expect(strays.isEmpty, "\(name) (\(spec.referenceName)): \(strays)")
            }
        }
    }

    @Test("the guard bites: a card a day early, or an hour late at UTC+14, is live without its look")
    func strayDaysAreCaught() throws {
        let iso = ISO8601DateFormatter()
        let early = try #require(iso.date(from: "2027-03-13T10:00:00Z"))
        let start = try #require(iso.date(from: "2027-03-14T10:00:00Z"))
        let end = try #require(iso.date(from: "2027-03-17T10:00:00Z"))
        let late = try #require(iso.date(from: "2027-03-17T11:00:00Z"))
        #expect(try Self.strays(start: start, end: end, looks: [.stPatricks], hours: -10).isEmpty)
        #expect(try Self.strays(start: start, end: end, looks: [.stPatricks], hours: 14).isEmpty)
        #expect(try !Self.strays(start: early, end: end, looks: [.stPatricks], hours: -10).isEmpty)
        #expect(try !Self.strays(start: start, end: late, looks: [.stPatricks], hours: 14).isEmpty)
        #expect(try Self.strays(start: start, end: late, looks: [.stPatricks], hours: 13).isEmpty)
    }
}
