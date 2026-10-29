//
//  ScreenSaverParkedScanTests.swift
//  M1K3AvatarTests
//
//  The screensaver is parked for 1.3.0 (Kev, 2026-10-29: "a poor implementation as it stands …
//  park it for later fun"). Its source stays: the `M1K3Screensaver` target and scheme still build,
//  and `M1K3ScreensaverCore` stays linked because the Settings backdrop draws its `LifeField`.
//  What leaves is the app's copy of the .saver and the Settings row that installs it. These
//  tripwires keep both out until someone unparks it on purpose (restore the embed block in
//  project.yml and the row in GeneralSettingsPane, then delete this file).
//
//  Signed: Kev + claude-opus-5.5, 2026-10-29, Confidence 0.8 (coarse string tripwires over
//  project.yml and the Settings pane). Prior: none (new file).
//

import Foundation
import Testing

struct ScreenSaverParkedScanTests {
    private static var root: URL {
        // …/macos/Tests/M1K3AvatarTests/<this file>
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func read(_ relative: String) throws -> String {
        let src = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
        #expect(!src.isEmpty, "scan read an empty file — \(relative) moved")
        return src
    }

    /// project.yml with comment lines dropped, so the PARKED note may name what it took out.
    private static func manifest() throws -> [String] {
        try read("project.yml").split(separator: "\n").map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
    }

    @Test("the app no longer copies the .saver into its bundle")
    func appDoesNotEmbedTheSaver() throws {
        let lines = try Self.manifest()
        #expect(!lines.contains { $0.trimmingCharacters(in: .whitespaces) == "- target: M1K3Screensaver" })
        // The target itself stays, parked, so it can still be built by its own scheme.
        #expect(lines.contains("  M1K3Screensaver:"))
    }

    @Test("Settings no longer shows the Screen Saver row")
    func settingsDoesNotMountTheRow() throws {
        let pane = try Self.read("M1K3App/Settings/GeneralSettingsPane.swift")
            .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(!pane.contains("ScreenSaverSettingsSection("))
    }
}
