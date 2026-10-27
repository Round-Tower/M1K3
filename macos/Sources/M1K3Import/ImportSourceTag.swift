//
//  ImportSourceTag.swift
//  M1K3Import
//
//  `import/<provider>/<yyyy-MM-dd>` (#711): the source every row an import writes carries, in the
//  memory graph (`Memory.source`) and the corpus (`KnowledgeItem.source`) alike — which is what
//  makes "forget everything from this import" one action. The day is UTC so the tag a user sees
//  on Monday is the tag the forget button finds on Friday, whatever the clock's zone did.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85 (two imports of one provider on one
//  UTC day share a tag, so forgetting one forgets both — named in the PR's follow-ups).
//  Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-27 (pre-push review fold) — the day parses only in its canonical spelling
//  (ASCII digits, no sign), so "+026-10-26" can't become a second tag for one day that Forget would miss; the
//  formatter takes `Int` as `%ld`. Confidence 0.9.

import Foundation
import M1K3Knowledge

public struct ImportSourceTag: Sendable, Hashable {
    public let provider: ImportProvider
    /// `yyyy-MM-dd`, UTC.
    public let day: String

    public init(provider: ImportProvider, date: Date) {
        self.provider = provider
        let parts = Self.utc.dateComponents([.year, .month, .day], from: date)
        day = String(format: "%04ld-%02ld-%02ld", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Parses exactly `import/<known provider>/<valid yyyy-MM-dd>`; anything else is nil.
    public init?(rawValue: String) {
        let parts = rawValue.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "import",
              let provider = ImportProvider(rawValue: String(parts[1])),
              Self.isDay(String(parts[2]))
        else { return nil }
        self.provider = provider
        day = String(parts[2])
    }

    public var rawValue: String {
        "import/\(provider.rawValue)/\(day)"
    }

    /// The corpus half of the tag.
    public var knowledgeSource: KnowledgeSource {
        KnowledgeSource(rawValue: rawValue)
    }

    /// The graph half of the tag (`Memory.source`).
    public var graphSource: String {
        rawValue
    }

    /// The filed conversation's `sourceRef`: provider + the provider's conversation id, and NOT
    /// the day, so a later export of the same account re-files nothing an earlier import filed
    /// (DocumentIngester no-ops on a known sourceRef) and forgetting the later import leaves the
    /// earlier one's conversations where they are.
    public func conversationSourceRef(id: String) -> String {
        "import/\(provider.rawValue)/conversation/\(id)"
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    private static func isDay(_ text: String) -> Bool {
        let fields = text.split(separator: "-", omittingEmptySubsequences: false)
        guard fields.count == 3, fields[0].count == 4, fields[1].count == 2, fields[2].count == 2,
              fields.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let year = Int(fields[0]), let month = Int(fields[1]), let day = Int(fields[2]),
              let date = utc.date(from: DateComponents(year: year, month: month, day: day))
        else { return false }
        // Calendar normalises an impossible day (Feb 31 → Mar 3); a real day reads back unchanged.
        let back = utc.dateComponents([.year, .month, .day], from: date)
        return back.year == year && back.month == month && back.day == day
    }
}
