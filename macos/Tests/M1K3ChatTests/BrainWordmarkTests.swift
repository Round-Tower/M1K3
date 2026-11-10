//
//  BrainWordmarkTests.swift
//  M1K3ChatTests
//
//  The small pixel tag beside the M1K3 wordmark: which brain is in.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-10, Confidence 0.9, Prior: none (new file)
//

@testable import M1K3Chat
import M1K3Inference
import Testing

struct BrainWordmarkTests {
    @Test("each brain has a short tag, and a brain that is not on this device has none")
    func tags() {
        #expect(BrainWordmark.tag(for: .mini, elsewhere: false) == "MINI")
        #expect(BrainWordmark.tag(for: .lil, elsewhere: false) == "LIL")
        #expect(BrainWordmark.tag(for: .big, elsewhere: false) == "BIG")
        #expect(BrainWordmark.tag(for: .lil, elsewhere: true) == nil)
    }

    @Test("only a short label the app wrote wears the pixel face: nothing quoting the user, no site name")
    func whichLabelsWearThePixelFace() {
        for fixed in ["Thinking…", "Recalling what I know…", "Looking…", "Checking the time…"] {
            #expect(BrainWordmark.suitsPixelFace(fixed), "\(fixed)")
        }
        for dynamic in [
            "Searching the web for “leica m6 film camera”…", "Reading en.wikipedia.org…", "",
            "A note that runs on for rather longer than a label should",
        ] {
            #expect(!BrainWordmark.suitsPixelFace(dynamic), "\(dynamic)")
        }
    }

    @Test("the tag types on one letter at a time and ends whole")
    func typing() {
        #expect(BrainWordmark.typed("MINI", step: 0) == "")
        #expect(BrainWordmark.typed("MINI", step: 2) == "MI")
        #expect(BrainWordmark.typed("MINI", step: 4) == "MINI")
        #expect(BrainWordmark.typed("MINI", step: 9) == "MINI")
        #expect(BrainWordmark.typed("MINI", step: -1) == "")
    }
}
