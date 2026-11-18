//
//  WeightsRefreshWiringScanTests.swift
//  M1K3InferenceTests
//
//  The shells' half of WeightsRefresh is a rule, not a type: a tier becomes a folder only through the resolver
//  (`loadableModelID(for:)` / `weightsResolution(for:)`). `MLXBrainProvider` loads through a downloader that fetches
//  whatever is missing, so ONE bare `tier.mlxModelID` handed to a provider or an install check is a silent 3 GB
//  fetch of the update, against "downloads only when you ask" (challenger pass, 2026-11-18). This scan holds the
//  Mac and iPhone shells to it: a bare read is allowed only as a nil check or in a file named below, with why.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-18, Confidence 0.7 (a text tripwire: it catches the spelling, not every
//  way to reach the id). Prior: none (new file).

import Foundation
import Testing

struct WeightsRefreshWiringScanTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Files that may read the bare id, and why. Anything else fails.
    private static let allowed: [String: String] = [
        // The update's own fetch and its row: the current id IS the update (after the person's tap).
        "M1K3iOSApp/AppCore+WeightsRefresh.swift": "fetches the update the person tapped for",
        "M1K3App/AppEnvironment+WeightsRefresh.swift": "the header names the rule",
        "M1K3App/AppEnvironment+Downloads.swift": "the manager's fetch: a tap on Download or Update",
        "M1K3App/AppEnvironment+BrainUpgrade.swift": "the ladder's fetch: consented, disk only",
        // Evals measure the shipped current weights on purpose.
        "M1K3App/ReadEvalStage.swift": "eval",
        "M1K3App/ChatCurveStage.swift": "eval",
        "M1K3App/EnergyProbeStage.swift": "eval",
        "M1K3App/MemBlockProbeStage.swift": "eval",
        "M1K3App/SelfTest.swift": "eval",
        // Not a folder: whether the shipped Lil reads the thinking toggle.
        "M1K3App/Settings/M1K3SettingsPane.swift": "a capability read, never a load",
    ]

    private static func swiftFiles(in folder: String) -> [String] {
        let base = root.appendingPathComponent(folder)
        guard let walk = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
        return walk.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .map { String($0.path.dropFirst(root.path.count + 1)) }
    }

    @Test("the shells read a tier's bare model id only as a nil check, outside the named files")
    func noBareModelIDReads() throws {
        let files = Self.swiftFiles(in: "M1K3App") + Self.swiftFiles(in: "M1K3iOSApp")
        #expect(files.count > 50, "the scan must see the shells (found \(files.count))")
        let bare = try Regex(#"\.mlxModelID\b(?!\s*[!=]=\s*nil)"#)
        var offenders: [String] = []
        for file in files where Self.allowed[file] == nil {
            let text = try String(contentsOf: Self.root.appendingPathComponent(file), encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                where line.contains(bare)
            {
                offenders.append("\(file):\(index + 1)")
            }
        }
        #expect(offenders.isEmpty, "route these through loadableModelID(for:) / weightsResolution(for:): \(offenders)")
    }

    @Test("every allowed file still exists, so the list cannot rot into a blanket pass")
    func allowListIsLive() {
        for file in Self.allowed.keys {
            #expect(FileManager.default.fileExists(atPath: Self.root.appendingPathComponent(file).path), "\(file)")
        }
    }
}
