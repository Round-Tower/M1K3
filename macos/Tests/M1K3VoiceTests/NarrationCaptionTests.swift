//
//  NarrationCaptionTests.swift
//  M1K3VoiceTests
//

import Foundation
@testable import M1K3Voice
import Testing

struct NarrationCaptionTests {
    @Test("M1K3's own speech is captioned M1K3")
    func residentIsM1K3() {
        #expect(NarrationCaption.text(for: .m1k3) == "M1K3")
    }

    @Test("a visiting client is named, uppercased, dashes to spaces, via M1K3")
    func visitorNamed() {
        #expect(NarrationCaption.text(for: .visitor("claude-code")) == "CLAUDE CODE · VIA M1K3")
    }

    @Test("a visitor that gave no name gets the honest fallback, never a blank")
    func visitorUnnamed() {
        #expect(NarrationCaption.text(for: .visitor(nil)) == "A VISITING AGENT · VIA M1K3")
        #expect(NarrationCaption.text(for: .visitor("  ")) == "A VISITING AGENT · VIA M1K3")
    }

    @Test("the narrator is an equatable value the highlight can hold")
    func narratorEquality() {
        #expect(Narrator.visitor("x") == .visitor("x"))
        #expect(Narrator.visitor("x") != .m1k3)
    }
}
