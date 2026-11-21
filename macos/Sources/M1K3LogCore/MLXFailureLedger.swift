//
//  MLXFailureLedger.swift
//  M1K3LogCore
//
//  The last few MLX errors this device hit, kept on disk so a report can say what failed. On 2026-11-21 the
//  Organizer held 15 iPhone crash logs (1.1.0 to 1.4.0, mostly 4 GB A13 phones running Pocket), every one an
//  MLX error with no handler, and not one carried MLX's message: the trap happens before anything is written,
//  and MetricKit's summary arrives a day after the next launch drafts the "didn't close cleanly" email. So the
//  message is written here, synchronously, by whoever sees it first: the guarded scope that turns it into a
//  "couldn't answer" (1.5), or the global handler just before it traps. The next report reads it back.
//
//  What goes in is MLX's own error text (shapes, sizes, "[METAL] Command buffer execution failed: …"), never
//  the person's words; it can name a file path, so the reports run their path redactor over these lines too.
//  One line each, trimmed and capped; the last `maxEntries`; a report shows only the last `reportWindow`.
//
//  Signed: claude-opus-5-5, 2026-11-21, Confidence 0.8 (pure and tested; whether MLX's message names the cause
//  of the A13 failures is what the next report will tell). Prior: none (new file).
//

import Foundation

public struct MLXFailureLedger: Sendable {
    /// How many errors are kept (a loop of the same failure needs no more).
    public static let maxEntries = 5
    /// A message longer than this is cut, with an ellipsis.
    public static let maxMessageLength = 240
    /// A report shows only errors from this recent past.
    public static let reportWindow: TimeInterval = 7 * 24 * 3600

    /// The app's own ledger, in Application Support (it survives a crash and a relaunch; not a cache).
    public static let standard = MLXFailureLedger(fileURL: defaultURL)

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    private struct Entry: Codable {
        let at: Date
        let message: String
    }

    /// One lock for every instance: the C error handler may call in from any thread.
    private static let lock = NSLock()

    /// Record `message`. Synchronous and never throws: it may be the last thing the process does.
    public func record(_ message: String, at date: Date = Date()) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var entries = read()
        entries.append(Entry(at: date, message: Self.sanitize(message)))
        entries = Array(entries.suffix(Self.maxEntries))
        guard let data = try? JSONEncoder.ledger.encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    /// The recent errors as report lines, newest first: "2026-11-21T12:00:00Z <message>".
    public func lines(now: Date = Date()) -> [String] {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return read()
            .filter { (0 ... Self.reportWindow).contains(now.timeIntervalSince($0.at)) } // a skewed future isn't recent
            .sorted { $0.at > $1.at }
            .map { "\(formatter.string(from: $0.at)) \($0.message)" }
    }

    /// One line, whitespace collapsed, capped at `maxMessageLength`.
    static func sanitize(_ message: String) -> String {
        // mlx-c appends the C source it threw from (" at /…/mlx-c/mlx/c/ops.cpp:123"): build-machine noise that
        // would spend the cap. MLX's own words come first, so keep those.
        let ownWords = message.range(of: " at /").map { String(message[..<$0.lowerBound]) } ?? message
        let oneLine = ownWords.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !oneLine.isEmpty else { return "unknown MLX error" }
        guard oneLine.count > maxMessageLength else { return oneLine }
        return String(oneLine.prefix(maxMessageLength - 1)) + "…"
    }

    private func read() -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder.ledger.decode([Entry].self, from: data)) ?? []
    }

    private static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("mlx-failures.json")
    }
}

private extension JSONEncoder {
    static var ledger: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }
}

private extension JSONDecoder {
    static var ledger: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
