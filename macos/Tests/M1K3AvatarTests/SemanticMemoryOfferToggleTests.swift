//
//  SemanticMemoryOfferToggleTests.swift
//  M1K3AvatarTests
//
//  A source-scan pin on the pre-ticked "Also get semantic memory" checkbox view (the decision it shows
//  for is pure and pinned in SemanticMemoryOfferTests): it is static, uses the pure copy, and ticks like
//  every other selection. It sits inside glass (the upgrade card), so nothing in it may tick.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.6 (a text tripwire; the look is
//  verify-by-launch). Prior: none (new file).

import Foundation
import Testing

struct SemanticMemoryOfferToggleTests {
    @Test("the offer toggle is a static checkbox over the pure copy, with the selection tick")
    func staticCheckbox() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("M1K3App/SemanticMemoryOfferToggle.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
        #expect(code.contains("SemanticMemoryOffer.toggleTitle(size: env.semanticMemorySizeLabel)"))
        #expect(code.contains("SemanticMemoryOffer.toggleDetail"))
        #expect(code.contains(".toggleStyle(.checkbox)") && code.contains("soundEffects.play(.selectionTick)"))
        #expect(!code.contains("ProgressView"), "a ticking view inside the upgrade card's glass")
    }
}
