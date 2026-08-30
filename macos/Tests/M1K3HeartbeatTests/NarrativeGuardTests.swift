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

    @Test("the Mac noun is rejected — the machine is the word (first live pulse said Mac)")
    func macNounRejected() {
        #expect(!NarrativeGuard.validate(narrative: "Mac's breathing easy today.", digest: digest))
        #expect(!NarrativeGuard.validate(narrative: "The Mac is cool.", digest: digest))
        #expect(!NarrativeGuard.validate(narrative: "Both Macs are cool.", digest: digest))
    }

    @Test("lowercase mac is caught too (#103 review: the tripwire was case-sensitive)")
    func lowercaseMacRejected() {
        #expect(!NarrativeGuard.validate(narrative: "the mac's cool tonight.", digest: digest))
        #expect(NarrativeGuard.verdict(narrative: "two macs hum.", digest: digest) == .macNoun)
    }

    @Test("machine and MacBook-free compounds are not false-positives for the Mac check")
    func macNounBoundaries() {
        let narrative = "The machine is cool as ever."
        #expect(NarrativeGuard.validate(narrative: narrative, digest: digest))
    }

    @Test("digits from the day's earlier DIGESTS are allowed — the arc threads faithfully (pulse 2 live rejection)")
    func earlierDigestDigitsAllowed() {
        let narrative = "Disk's breathing again — 4GB this morning, 210 now."
        #expect(!NarrativeGuard.validate(narrative: narrative, digest: digest))
        #expect(NarrativeGuard.validate(
            narrative: narrative,
            digest: digest,
            earlierDigests: ["Cool and steady, 4GB of space to spare."]
        ))
    }

    @Test("the laundering path is closed — evidence is digests ONLY, never earlier narratives (2026-08-30 addendum, fix 6)")
    func launderedDigitStaysInvented() {
        // Pulse 1's model invented "the 19th". Under the old rule pulse 1's
        // NARRATIVE joined the evidence set, so the fabrication was permanently
        // allowed for every later pulse that day. The evidence parameter now
        // takes digests — code-composed facts — so a fabricated digit stays
        // invented no matter how many pulses ago it was fabricated.
        let narrative = "You were busy exploring local foodies on the 19th."
        #expect(NarrativeGuard.verdict(
            narrative: narrative,
            digest: digest,
            earlierDigests: ["The machine is running cool. Battery at 84%, charging."]
        ) == .inventedDigit)
    }

    @Test("the verdict names the rejection reason, content-free")
    func verdictReasons() {
        #expect(NarrativeGuard.verdict(narrative: "", digest: digest) == .empty)
        #expect(NarrativeGuard.verdict(narrative: "The Mac hums.", digest: digest) == .macNoun)
        #expect(NarrativeGuard.verdict(narrative: "Battery hit 12%.", digest: digest) == .inventedDigit)
        #expect(NarrativeGuard.verdict(narrative: "All calm at 84%.", digest: digest) == .pass)
        let long = String(repeating: "cool ", count: 400)
        #expect(NarrativeGuard.verdict(narrative: long, digest: digest) == .tooLong)
    }
}
