//
//  NotchHUDAppearanceScanTests.swift
//  M1K3AvatarTests
//
//  Source-scan tripwires for the notch HUD's appearance (Kev, 2026-11-05: "the HUD should respect
//  the dark & light modes of the device"). The docked row (every Mac without a notch, and every
//  external display) sat on `.regularMaterial`, which follows the appearance, but its text was
//  hard-coded `.white`: white on a pale card in Light mode. The notch panel stays dark on purpose
//  (it continues the physical notch), so it pins `.dark` and everything else uses semantic colours.
//  The app shell has no unit-test target, so these hold the wiring as text.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-05, Confidence 0.7 (coarse tripwires over text; how each
//  appearance looks on both screen kinds is verify-by-launch). Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-11-05 (later) — the docked-tile test now pins NO pin: the HUD capture
//  harness showed the `.dark` pin was a no-op (light tile, dark fox in Light mode). Confidence 0.8.
//

import Foundation
import Testing

struct NotchHUDAppearanceScanTests {
    private static var root: URL {
        // …/macos/Tests/M1K3AvatarTests/<this file>
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Source with comment lines stripped, so the header may explain what is kept out.
    private static func code(_ relative: String) throws -> String {
        let src = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
        #expect(!src.isEmpty, "scan read an empty file — \(relative) moved")
        return src.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private static let hud = "M1K3App/NotchHUDContentView.swift"

    @Test("No HUD text or rim is hard-coded white: they use semantic colours that follow the appearance")
    func noHardCodedWhiteForeground() throws {
        let src = try Self.code(Self.hud)
        #expect(!src.contains("foregroundStyle(.white"), "text must follow Light and Dark (.primary / .secondary)")
        #expect(!src.contains("strokeBorder(.white"), "the docked rim must follow the appearance too")
    }

    @Test("The notch panel pins the dark appearance, so it renders as before in Light mode")
    func notchPanelPinsDark() throws {
        let src = try Self.code(Self.hud)
        #expect(src.contains("geometry.growsFromNotch ? .dark : systemScheme"),
                "the notch panel stays dark; the docked row follows the system")
        #expect(src.contains("@Environment(\\.colorScheme) private var systemScheme"))
    }

    @Test("The docked creature slot carries no appearance pin: the tile follows the card")
    func dockedCreatureSlotFollowsTheCard() throws {
        // Measured 2026-11-05 with the HUD capture harness: a `.dark` pin on the docked avatar slot
        // changed nothing. CRTOverlay paints no backing, and the fox's lattice colour doesn't follow the
        // SwiftUI colorScheme: Light renders a dark fox on the light card, which is legible and was
        // approved. A pin here would only be a comment that lies.
        let src = try Self.code(Self.hud)
        let docked = try #require(src.range(of: "HStack(spacing: NotchHUDLayout.interItemSpacing)"), "docked row moved")
        let rest = src[docked.upperBound...]
        let text = try #require(rest.range(of: "narrationText("))
        #expect(!rest[..<text.lowerBound].contains(".environment(\\.colorScheme"),
                "no colorScheme pin on the docked avatar slot")
    }
}
