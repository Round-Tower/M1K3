//
//  PostToolAnswerTests.swift
//  M1K3ChatTests
//
//  The post-tool answer policy's decision table (plan item 2, 2026-10-25): the default keeps
//  today's synthesis byte for byte; the `use` arm keeps an answer-shaped conclusion and
//  synthesises after a preamble.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-25, Confidence 0.9 (pure). Prior: none (new file).
//

@testable import M1K3Chat
import Testing

struct PostToolAnswerTests {
    @Test("the argv switch: unset or unknown is the shipped synthesis; `use` is the arm, any case")
    func policyFromArguments() {
        #expect(PostToolAnswer.policy(arguments: [:]) == .synthesise)
        #expect(PostToolAnswer.policy(arguments: ["postToolAnswer": "use"]) == .use)
        #expect(PostToolAnswer.policy(arguments: ["postToolAnswer": "USE"]) == .use)
        #expect(PostToolAnswer.policy(arguments: ["postToolAnswer": "synthesise"]) == .synthesise)
        #expect(PostToolAnswer.policy(arguments: ["postToolAnswer": "banana"]) == .synthesise)
        #expect(PostToolAnswer.policy(arguments: ["postToolAnswer": 1]) == .synthesise, "argv values are strings")
    }

    @Test("under the default policy every post-tool conclusion is synthesised, whatever it said")
    func synthesiseIsToday() {
        let answer = String(repeating: "The capital is Dublin. ", count: 5)
        #expect(PostToolAnswer.verdict(policy: .synthesise, conclusion: answer, streamed: true)
            == .synthesise(afterPreamble: false))
        #expect(PostToolAnswer.verdict(policy: .synthesise, conclusion: "", streamed: false)
            == .synthesise(afterPreamble: false))
    }

    @Test("under `use`, an answer-shaped conclusion stands and the preamble shape still synthesises")
    func useKeepsAnswers() {
        let answer = String(repeating: "The capital is Dublin. ", count: 5)
        #expect(PostToolAnswer.verdict(policy: .use, conclusion: answer, streamed: true) == .keepConclusion)
        // "Let me look that up." — the 2026-09-04 shape synthesis exists for: short, content-free.
        #expect(PostToolAnswer.verdict(policy: .use, conclusion: "Let me look that up.", streamed: true)
            == .synthesise(afterPreamble: true))
        // An empty conclusion streamed nothing, so there is no preamble to continue from.
        #expect(PostToolAnswer.verdict(policy: .use, conclusion: "", streamed: false)
            == .synthesise(afterPreamble: false))
        #expect(PostToolAnswer.verdict(policy: .use, conclusion: "   \n", streamed: true)
            == .synthesise(afterPreamble: false), "whitespace is not a preamble")
    }

    @Test("under `use`, a conclusion over nothing informative still synthesises (the plain-RAG degradation)")
    func useWithoutEvidenceSynthesises() {
        // A rate-limited search leaves only an error observation; the default filters it and degrades to
        // plain RAG. A 40+ char "I couldn't reach the web" from the loop must not stand instead.
        let apology = "I searched the web but the service was unavailable just now, sorry about that."
        #expect(PostToolAnswer.verdict(policy: .use, conclusion: apology, streamed: true, evidence: false)
            == .synthesise(afterPreamble: true))
        #expect(PostToolAnswer.verdict(policy: .use, conclusion: "", streamed: false, evidence: false)
            == .synthesise(afterPreamble: false))
        #expect(PostToolAnswer.verdict(policy: .use, conclusion: apology, streamed: true, evidence: true)
            == .keepConclusion)
    }

    @Test("the usable length is a character floor, met exactly")
    func floorIsInclusive() {
        let exact = String(repeating: "x", count: PostToolAnswer.usableConclusionChars)
        #expect(PostToolAnswer.verdict(policy: .use, conclusion: exact, streamed: true) == .keepConclusion)
        #expect(PostToolAnswer.verdict(policy: .use, conclusion: String(exact.dropLast()), streamed: true)
            == .synthesise(afterPreamble: true))
    }
}
