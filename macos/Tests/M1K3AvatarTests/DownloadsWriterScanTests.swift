//
//  DownloadsWriterScanTests.swift
//  M1K3AvatarTests
//
//  A source-scan pin on the "one writer per brain folder" rule across the three things that
//  can fetch a brain: the downloads manager, the background upgrade fetch, and a foreground
//  `selectBrain`. The rule is symmetric — whichever starts second takes the folder over by
//  cancelling the manager's fetch, or (the manager's own entry) refuses. The bodies are
//  SwiftUI-free glue with no pure seam, so the guard reads the shell files from disk (the
//  SettingsPaneLayoutTests idiom).
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11 (pre-push review fold, B1), Confidence 0.7 (a coarse
//  tripwire over text; the real race is verify-by-launch). Prior: none (new file).

import Foundation
import Testing

struct DownloadsWriterScanTests {
    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func code(_ relative: String) throws -> String {
        let src = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
        #expect(!src.isEmpty, "scan read an empty file — \(relative) moved")
        return src.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The text from `marker` to the next function-level declaration.
    private static func body(of marker: String, in source: String) throws -> String {
        let start = try #require(source.range(of: marker), "\(marker) moved")
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    func ")?.lowerBound ?? rest.range(of: "\n    private func ")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    @Test("B1: the background upgrade fetch takes the folder over from the manager's fetch of the same tier")
    func upgradeFetchCancelsManager() throws {
        let upgrade = try Self.code("M1K3App/AppEnvironment+BrainUpgrade.swift")
        let run = try Self.body(of: "private func runBrainUpgradeFetch(attempt: Int) {", in: upgrade)
        #expect(run.contains("cancelManagerBrainFetch(for: target)"),
                "runBrainUpgradeFetch (and so its retry) must stop a manager fetch of the same tier")
    }

    @Test("B1: the manager refuses to start beside a foreground load or the upgrade fetch of the same tier")
    func managerRefusesBesideOtherWriters() throws {
        let downloads = try Self.code("M1K3App/AppEnvironment+Downloads.swift")
        let start = try Self.body(of: "private func startBrainDownload(_ kind: DownloadKind) {", in: downloads)
        #expect(start.contains("selectedBrain == tier, modelLoad.isActive"))
        #expect(start.contains("case .fetching = brainUpgrade, brainUpgradeTarget == tier"))
    }

    @Test("B1: selectBrain and the directed fetch cancel the manager's fetch")
    func selectAndDirectedCancelManager() throws {
        #expect(try Self.code("M1K3App/AppEnvironment.swift").contains("cancelManagerBrainFetch(for: tier)"))
        #expect(try Self.code("M1K3App/AppEnvironment+BrainUpgrade.swift").contains("cancelManagerBrainFetch(for: tier)"))
    }
}
