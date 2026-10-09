//
//  VoiceModeFloorTests.swift
//  M1K3AvatarTests
//
//  A source-scan pin on a taste decision (Kev, 2026-10-09): voice mode on the Mac
//  sits on the window's own glass, not on a private dark gradient. VoiceModeView is
//  a SwiftUI body with no pure seam, so the guard reads the file from disk (the
//  SubsystemGuardTests idiom) and fails if the private floor comes back. It does
//  not catch every spelling (`.black`, asset colours) — it catches the regression
//  that happened: a `LinearGradient(` / `Color(red:` floor or `VoiceBackdrop`.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-09, Confidence 0.6 (a coarse tripwire;
//  the look itself is verify-by-launch). Prior: none (new file).
//

import Foundation
import Testing

struct VoiceModeFloorTests {
    private static func source(_ relative: String) throws -> String {
        // …/macos/Tests/M1K3AvatarTests/<this file>
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test("the Mac voice hero draws no private floor of its own")
    func macVoiceHeroHasNoPrivateFloor() throws {
        let src = try Self.source("M1K3App/VoiceModeView.swift")
        #expect(!src.isEmpty, "scan read an empty file — the path moved")
        #expect(src.contains("struct VoiceModeView"), "scan is not reading the voice hero")
        // Strip comment lines so the header may still explain what was removed.
        let code = src.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(!code.contains("LinearGradient("), "voice mode paints a gradient floor again")
        #expect(!code.contains("Color(red:"), "voice mode paints a literal-colour floor again")
        #expect(!code.contains("VoiceBackdrop"), "the private VoiceBackdrop is back")
        #expect(code.contains(".glassBackdrop()"), "voice mode must sit on the window glass")
    }
}
