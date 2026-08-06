//
//  NarrativeGuardTests.swift
//  M1K3HeartbeatTests
//
//  Pins the confabulation tripwire: the model may retell the digest, never
//  extend it. The guard is deliberately heuristic — any digit run in the
//  narrative must already exist in the digest (a model can't quietly invent
//  a precise-sounding number), plus emptiness and length bounds. On failure
//  the caller falls back to the deterministic digest, so a false REJECT
//  costs style, never facts; a false PASS is bounded to unnumbered prose.
//
//  Signed: Kev + claude-fable-5, 2026-08-06, Confidence 0.85 (the digit
//  heuristic's limits are named above; behaviour pinned red-first).
//  Prior: none (new file).
//

@testable import M1K3Heartbeat
import Testing

struct NarrativeGuardTests {
    private let digest = """
    The machine is running cool. Battery at 84%, charging.
    Learned 3 new things: Ardmore round tower, Kokoro voice, Sparrow.
    210 GB free of 994 GB on disk.
    """

    @Test("a faithful retelling passes")
    func faithfulPasses() {
        let narrative =
            "Easy afternoon. The machine's cool, battery sitting at 84% on the charger — "
                + "and I picked up 3 new things, the Ardmore round tower among them."
        #expect(NarrativeGuard.validate(narrative: narrative, digest: digest))
    }

    @Test("an invented number is rejected")
    func inventedNumberRejected() {
        let narrative = "All calm. I answered 47 questions and the battery hit 12%."
        #expect(!NarrativeGuard.validate(narrative: narrative, digest: digest))
    }

    @Test("empty or whitespace narratives are rejected")
    func emptyRejected() {
        #expect(!NarrativeGuard.validate(narrative: "", digest: digest))
        #expect(!NarrativeGuard.validate(narrative: "   \n", digest: digest))
    }

    @Test("a runaway narrative is rejected on length")
    func lengthBound() {
        let long = String(repeating: "The machine is running cool. ", count: 100)
        #expect(!NarrativeGuard.validate(narrative: long, digest: digest))
    }

    @Test("numbers the digest already carries may repeat")
    func digestNumbersMayRepeat() {
        let narrative = "84% and 84% again — the 3 new things can wait."
        #expect(NarrativeGuard.validate(narrative: narrative, digest: digest))
    }

    @Test("prose without numbers passes on the digest's authority")
    func numberFreeProsePasses() {
        let narrative = "A quiet one. The machine's cool and I learned a few things worth keeping."
        #expect(NarrativeGuard.validate(narrative: narrative, digest: digest))
    }
}
