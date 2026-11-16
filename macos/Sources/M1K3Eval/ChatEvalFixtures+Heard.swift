//
//  ChatEvalFixtures+Heard.swift
//  M1K3Eval
//
//  heard (#852): voice turns as the recogniser hands them over. Kev said "How're you keeping, are you
//  well?" on his iPhone (2026-11-16) and the brain got "You're my curry keeping, are you well?", then
//  riffed on the curry. Every fixture here is `spoken`, so the in-app stage gives it the voice turn's
//  heard line exactly as the shells do (`HeardClause`), and `M1K3_SELFTEST_CHATEVAL_HEARD=off` runs the
//  same turns without it: the arm is the line, nothing else.
//
//  Three groups:
//  - **Garbles** (12): a sound-alike swap of the kind Apple's fast recogniser makes. Each has a fact
//    that only appears if the brain read past the swap (Canberra for "oz trail ya"), and the swap
//    itself as a `mustNotContain` (parroting "moaner Lisa" back is building on it). Kev's real one
//    has no fact to check, so it scores on not building on the curry.
//  - **Idioms** (2): Hiberno-English read literally ("giving out" is scolding, not handing out).
//  - **Guards** (6): what the line must not break. A real odd word stays ("a crack in my screen" is
//    not the craic; a chicken curry is a curry), a clean turn doesn't talk about speech recognition,
//    and a tool turn still calls its tool.
//
//  The swaps are written by ear, not taken from a recogniser log (only Kev's is real), so the
//  fixture set measures whether the line helps a brain recover, not how often the recogniser
//  makes these mistakes. None of them appears in `HeardClause.text` (a test pins that).
//
//  Run: `--kinds heard --router dispatch` on lil,big, the arm on and off; Mini via MiniLiveEvalTests.
//
//  Signed: Kev + claude-opus-5-5, 2026-11-16, Confidence 0.6 (by-ear garbles, n = 20; the arm's
//  verdict needs paired per-fixture results, not the aggregate). Prior: Unknown.
//

import Foundation

/// What a clean voice turn must never say about itself: the line is for the brain, not the answer.
private let heardLeak = ["speech recognition", "speech-recognition", "transcri", "misheard", "mishear"]

public extension ChatEvalFixtures {
    static let heard: [ChatEvalFixture] = [
        // Kev's own, 2026-11-16: "How're you keeping, are you well?"
        .init(
            id: "heard-curry-keeping", kind: .heard, spoken: true,
            prompt: "You're my curry keeping, are you well?",
            expectation: .init(mustNotContain: ["curry"] + leakMarkers, mustComply: true, minChars: 1)
        ),
        .init(
            id: "heard-oz-capital", kind: .heard, spoken: true,
            prompt: "What's the capital of oz trail ya?",
            expectation: .init(mustContainAny: ["Canberra"], mustNotContain: ["oz trail"] + leakMarkers, minChars: 1)
        ),
        .init(
            id: "heard-moaner-lisa", kind: .heard, spoken: true,
            prompt: "Who painted the moaner Lisa?",
            expectation: .init(mustContainAny: ["Leonardo", "da Vinci"], mustNotContain: ["moaner"] + leakMarkers, minChars: 1)
        ),
        .init(
            id: "heard-tie-tannic", kind: .heard, spoken: true,
            prompt: "What year did the tie tannic sink?",
            expectation: .init(mustContainAny: ["1912"], mustNotContain: ["tie tannic"] + leakMarkers, minChars: 1)
        ),
        .init(
            id: "heard-spider-legs", kind: .heard, spoken: true,
            prompt: "How many legs does a spider half?",
            expectation: .init(
                mustContainAny: ["eight", "8"], mustNotContain: ["spider half"] + leakMarkers, minChars: 1, wholeWordFacts: true
            )
        ),
        .init(
            id: "heard-fair-and-hate", kind: .heard, spoken: true,
            prompt: "What's the boiling point of water in fair and hate?",
            expectation: .init(mustContainAny: ["212"], mustNotContain: ["fair and hate"] + leakMarkers, minChars: 1)
        ),
        .init(
            id: "heard-square-route", kind: .heard, spoken: true,
            prompt: "What's the square route of one forty four?",
            expectation: .init(
                mustContainAny: ["12", "twelve"], mustNotContain: ["square route"] + leakMarkers, minChars: 1,
                wholeWordFacts: true
            )
        ),
        .init(
            id: "heard-you-list-ease", kind: .heard, spoken: true,
            prompt: "Who wrote the novel you list ease?",
            expectation: .init(mustContainAny: ["Joyce"], mustNotContain: ["you list ease"] + leakMarkers, minChars: 1)
        ),
        .init(
            id: "heard-photo-sin", kind: .heard, spoken: true,
            prompt: "Explain photo sin thesis in two sentences for a kid.",
            expectation: .init(mustContainAny: ["sunlight", "light"], mustNotContain: ["photo sin"] + leakMarkers, minChars: 1)
        ),
        .init(
            id: "heard-gall-way", kind: .heard, spoken: true,
            prompt: "How long would it take me to drive from gall way to west port?",
            expectation: .init(mustContainAll: ["Galway", "Westport"], mustNotContain: ["gall way"] + leakMarkers, minChars: 1)
        ),
        .init(
            id: "heard-shakes-beer", kind: .heard, spoken: true,
            prompt: "What's the most famous play by shakes beer?",
            expectation: .init(mustContainAny: ["Shakespeare"], mustNotContain: ["shakes beer"] + leakMarkers, minChars: 1)
        ),
        .init(
            id: "heard-ever-rest", kind: .heard, spoken: true,
            prompt: "How tall is mount ever rest?",
            expectation: .init(
                mustContainAny: ["8,84", "8848", "8849", "8 84", "29,0", "29 0"], mustNotContain: ["ever rest"] + leakMarkers,
                minChars: 1
            )
        ),

        // Idioms read literally.
        .init(
            id: "heard-idiom-giving-out", kind: .heard, spoken: true,
            prompt: "My boss was giving out to me about the report, what should I say to her?",
            expectation: .init(
                mustNotContain: ["handing out", "hand out", "distribut"] + leakMarkers, mustComply: true, minChars: 1
            )
        ),
        .init(
            id: "heard-idiom-craic", kind: .heard, spoken: true,
            prompt: "What's the crack with you today?",
            expectation: .init(mustNotContain: ["cocaine", "drug"] + leakMarkers, mustComply: true, minChars: 1)
        ),

        // Guards: the line must not break these.
        .init(
            id: "heard-guard-real-curry", kind: .heard, spoken: true,
            prompt: "Give me a quick recipe for a chicken curry.",
            expectation: .init(mustContainAll: ["curry"], mustNotContain: heardLeak + leakMarkers, mustComply: true, minChars: 80)
        ),
        .init(
            id: "heard-guard-real-crack", kind: .heard, spoken: true,
            prompt: "There's a crack in my phone screen, is it worth fixing?",
            expectation: .init(
                mustContainAny: ["screen", "crack", "repair"], mustNotContain: ["craic"] + heardLeak + leakMarkers,
                mustComply: true, minChars: 1
            )
        ),
        .init(
            id: "heard-guard-plain-fact", kind: .heard, spoken: true,
            prompt: "What's the capital of France?",
            expectation: .init(mustContainAny: ["Paris"], mustNotContain: heardLeak + leakMarkers, minChars: 1)
        ),
        .init(
            id: "heard-guard-greeting", kind: .heard, spoken: true,
            prompt: "Hey, how are you doing today?",
            expectation: .init(mustNotContain: heardLeak + leakMarkers, mustComply: true, minChars: 1)
        ),
        .init(
            id: "heard-guard-time", kind: .heard, spoken: true,
            prompt: "What time is it right now?",
            expectation: .init(mustNotContain: heardLeak + leakMarkers, mustCallTool: "datetime")
        ),
        .init(
            id: "heard-guard-sums", kind: .heard, spoken: true,
            prompt: "What's seventeen times twenty three?",
            expectation: .init(mustContainAny: ["391"], mustNotContain: heardLeak + leakMarkers, minChars: 1)
        ),
    ]
}
