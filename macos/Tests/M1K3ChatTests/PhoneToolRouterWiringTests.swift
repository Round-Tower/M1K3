//
//  PhoneToolRouterWiringTests.swift
//  M1K3ChatTests
//
//  The phone routes every brain, as the Mac has since the 2026-10-10 router arm. Without the
//  route, every Lil message on iOS was an agent turn with the earlier turns pasted into the
//  system prompt as text, and Lil copied its last answer back word for word (Kev's phone,
//  2026-11-02); "what's in tech news" never reached web_search either.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-02. Prior: Unknown.
//  Confidence: 0.75 — the Mac arm is measured; the phone smoke is Kev's chat on device.
//

import Foundation
import Testing

struct PhoneToolRouterWiringTests {
    @Test("every brain on the phone takes the tool route unless the setting says no")
    func phoneRoutesEveryTier() throws {
        let core = try Self.source("M1K3iOSApp/AppCore.swift")
        #expect(
            core.contains("allTiers: ToolRouterWiring.allTiersEnabled(whenUnset: true)"),
            "an unset toolRouterAllTiers is ON on the phone, as on the Mac"
        )
    }

    private static func source(_ relative: String) throws -> String {
        let macos = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: macos.appendingPathComponent(relative), encoding: .utf8)
    }
}
