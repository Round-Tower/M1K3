//
//  SubsystemGuardTests.swift
//  M1K3LogCoreTests
//
//  The mechanical drift guard. Walks the actual source tree (Sources/ + M1K3App/
//  + M1K3iOSApp/)
//  and asserts, for every `Logger(subsystem:category:)` construction:
//    1. the subsystem is the ONE canonical value ("app.m1k3" or M1K3Log.subsystem)
//       — anything else (e.g. the historical "dev.m1k3.kokoro") is invisible to
//       IssueReporter's subsystem filter + the documented `log stream` recipe; and
//    2. the category is in the M1K3Log.Category catalogue — so a typo like
//       "mlx-lod" can't silently de-correlate a module's logs.
//
//  This is a TEXT scan, not a compile dependency: it covers M1K3App/ and the
//  iOS/visionOS shell M1K3iOSApp/ too (neither is a SwiftPM target) by reading
//  the files from disk. It is pure and runs
//  under plain `swift test` — no Metal, no app bundle.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-30, Confidence 0.9 (the lint the Kokoro
//  drift needed; subsystem + category both enforced end-to-end). Prior: Unknown.
//
//  Review: Kev + claude-fable-5.1, 2026-09-10 — the scan covers M1K3iOSApp/ (#245: a hand-built
//  `ios-core` category had drifted there unseen). Confidence now 0.9.
//

import Foundation
@testable import M1K3LogCore
import Testing

struct SubsystemGuardTests {
    /// Allowed non-literal forms after `subsystem:` — the constant, or the bare
    /// `subsystem` identifier (the M1K3Log factory forwarding its own param).
    private static let allowedSubsystemForms: Set<String> = ["M1K3Log.subsystem", "subsystem"]

    /// A `Logger(subsystem:category:)` construction found in the source tree.
    private struct LoggerSite {
        /// Path relative to the package root, for unambiguous failure messages.
        let file: String
        /// The raw token after `subsystem:` — a quoted literal (incl. quotes) or an identifier.
        let subsystem: String
        /// The raw token after `category:` — a quoted literal (incl. quotes) or an identifier.
        let category: String
    }

    @Test("no Logger uses a subsystem other than the canonical app.m1k3")
    func everyLoggerUsesCanonicalSubsystem() throws {
        let sites = try Self.allLoggerSites()

        // Sanity: the scan actually found loggers (guards against a silently empty
        // walk that would make this vacuously pass). Count direct constructions
        // PLUS catalogue-factory calls, so the floor tracks total logging sites
        // even as sites migrate from `Logger(…)` to `M1K3Log.logger(_:)`.
        let totalSites = try sites.count + (Self.factoryCallCount())
        #expect(totalSites >= 20, "expected to scan many logging sites, found \(totalSites)")

        let violations = sites.filter { !Self.isCanonicalSubsystem($0.subsystem) }
        let report = "non-canonical Logger subsystems (must be \"app.m1k3\" or M1K3Log.subsystem):\n"
            + violations.map { "  \($0.file): subsystem: \($0.subsystem)" }.joined(separator: "\n")
        #expect(violations.isEmpty, Comment(rawValue: report))
    }

    @Test("every Logger category literal is in the M1K3Log.Category catalogue")
    func everyLoggerCategoryIsCatalogued() throws {
        let catalogue = Set(M1K3Log.Category.allCases.map(\.rawValue))
        let sites = try Self.allLoggerSites()

        // Only string-literal categories are checked; identifier forms (e.g. the
        // factory's `category.rawValue`) are catalogue-bound by construction.
        let violations = sites.compactMap { site -> LoggerSite? in
            guard let literal = Self.stringLiteralValue(site.category) else { return nil }
            return catalogue.contains(literal) ? nil : site
        }
        let report = "Logger categories not in the M1K3Log.Category catalogue "
            + "(add the case to M1K3Log.Category, or use M1K3Log.logger(_:)):\n"
            + violations.map { "  \($0.file): category: \($0.category)" }.joined(separator: "\n")
        #expect(violations.isEmpty, Comment(rawValue: report))
    }

    // MARK: - Checks

    private static func isCanonicalSubsystem(_ token: String) -> Bool {
        if token == "\"\(M1K3Log.subsystem)\"" { return true } // "app.m1k3"
        return allowedSubsystemForms.contains(token)
    }

    /// The inner value of a `"…"` token, or nil if the token isn't a string literal.
    private static func stringLiteralValue(_ token: String) -> String? {
        guard token.hasPrefix("\""), token.hasSuffix("\""), token.count >= 2 else { return nil }
        return String(token.dropFirst().dropLast())
    }

    // MARK: - Scan

    /// A whole `Logger(subsystem:…, category:…)` construction. Tying the category
    /// capture to a Logger call (rather than scanning every `category:` label)
    /// avoids false positives from unrelated APIs that also take a `category:`.
    /// `\s*` spans newlines after the comment-strip + rejoin, so multi-line
    /// constructions are matched too.
    private nonisolated(unsafe) static let loggerCall =
        /Logger\(\s*subsystem:\s*("[^"]*"|[A-Za-z_][A-Za-z0-9_.]*)\s*,\s*category:\s*("[^"]*"|[A-Za-z_][A-Za-z0-9_.()]*)/

    /// `M1K3Log.logger(<case>)` factory calls — counted toward the sanity floor.
    private nonisolated(unsafe) static let factoryCall = /M1K3Log\.logger\(/

    private static func allLoggerSites() throws -> [LoggerSite] {
        let root = try packageRoot()
        return try ["Sources", "M1K3App", "M1K3iOSApp"].flatMap { sub -> [LoggerSite] in
            try scan(dir: root.appending(path: sub), root: root)
        }
    }

    private static func factoryCallCount() throws -> Int {
        let root = try packageRoot()
        var count = 0
        for sub in ["Sources", "M1K3App", "M1K3iOSApp"] {
            try forEachSwiftFile(in: root.appending(path: sub)) { _, code in
                count += code.matches(of: factoryCall).count
            }
        }
        return count
    }

    private static func scan(dir: URL, root: URL) throws -> [LoggerSite] {
        var found: [LoggerSite] = []
        try forEachSwiftFile(in: dir) { url, code in
            for match in code.matches(of: loggerCall) {
                found.append(LoggerSite(
                    file: relativePath(of: url, from: root),
                    subsystem: String(match.1),
                    category: String(match.2)
                ))
            }
        }
        return found
    }

    /// Read each `.swift` file under `dir`, strip `//` comments (so a prose mention
    /// of the `Logger(subsystem:category:)` selector isn't taken for a real call —
    /// subsystem/category values never contain "//"), and hand the code to `body`.
    private static func forEachSwiftFile(in dir: URL, _ body: (URL, String) throws -> Void) throws {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let code = text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> Substring in
                    if let slashes = line.range(of: "//") { return line[line.startIndex ..< slashes.lowerBound] }
                    return line
                }
                .joined(separator: "\n")
            try body(url, code)
        }
    }

    private static func relativePath(of url: URL, from root: URL) -> String {
        let full = url.path
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count)) : url.lastPathComponent
    }

    /// Walk up from this test file until we find the directory containing
    /// `Package.swift`. Robust to the test runner's working directory.
    private static func packageRoot() throws -> URL {
        var dir = URL(filePath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 10 {
            if FileManager.default.fileExists(atPath: dir.appending(path: "Package.swift").path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        throw GuardError.packageRootNotFound
    }

    private enum GuardError: Error { case packageRootNotFound }
}
