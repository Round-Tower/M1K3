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

    @Test("an untrusted, unbounded client name is capped and kept to one printable line")
    func visitorNameCapped() {
        let long = String(repeating: "x", count: 200)
        let capped = NarrationCaption.text(for: .visitor(long))
        #expect(capped.hasSuffix("… · VIA M1K3"))
        #expect(capped.count <= NarrationCaption.maxNameLength + " · VIA M1K3".count)
        #expect(NarrationCaption.text(for: .visitor("bad\nactor\u{07}here")) == "BAD ACTOR HERE · VIA M1K3")
        #expect(NarrationCaption.text(for: .visitor("  spaced   out  ")) == "SPACED OUT · VIA M1K3")
    }

    @Test("the narrator is an equatable value the highlight can hold")
    func narratorEquality() {
        #expect(Narrator.visitor("x") == .visitor("x"))
        #expect(Narrator.visitor("x") != .m1k3)
    }
}
