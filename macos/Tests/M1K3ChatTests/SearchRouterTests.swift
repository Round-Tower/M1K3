//
//  SearchRouterTests.swift
//  M1K3ChatTests
//
//  The search head (#713): its logistic reading over a synthetic head, the ways it fails toward
//  NO veto (no vector, a wrong-sized one, a zero vector, a non-finite score, no weights), and the
//  shipped weights over the real embedder on fixtures they never trained on. Until a teacher pass
//  trains it, the shipped head is an UNTRAINED stub that never vetoes: the web-read pin holds
//  either way, and the stable-knowledge pin arms itself the day trained weights land.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-26, Confidence 0.8 (math and fail-open pinned; the
//  fixture pins wait on trained weights). Prior: none (new file).
//

import Foundation
@testable import M1K3Chat
@testable import M1K3Eval
import NaturalLanguage
import Testing

struct SearchRouterTests {
    /// Four dimensions, the first axis "needs the web".
    private let head = SearchRouter.Head(threshold: 0.6, bias: -0.5, weights: [2, 0, 0, -1])

    @Test("fails toward no veto: no vector, a wrong-sized one, a zero vector or a non-finite score reads web")
    func failsTowardNoVeto() {
        #expect(SearchRouter.decide(for: "q", embed: { _ in nil }, head: head).verdict == .web)
        #expect(SearchRouter.decide(for: "q", embed: { _ in [1, 0] }, head: head).verdict == .web)
        #expect(SearchRouter.probability([0, 0, 0, 0], head: head) == nil)
        #expect(SearchRouter.probability([.nan, 0, 0, 0], head: head) == nil)
        #expect(SearchRouter.verdict(probability: nil, head: head) == .web)
        #expect(SearchRouter.verdict(probability: .nan, head: head) == .web)
        #expect(SearchRouter.verdict(probability: .infinity, head: head) == .web)
    }

    @Test("the threshold splits the verdict: at or above reads web, below stays local")
    func threshold() {
        #expect(SearchRouter.verdict(probability: 0.6, head: head) == .web)
        #expect(SearchRouter.verdict(probability: 0.599, head: head) == .local)
        #expect(SearchRouter.verdict(probability: 1, head: head) == .web)
        #expect(SearchRouter.verdict(probability: 0, head: head) == .local)
    }

    @Test("probability is the logistic of the L2-normalised dot product, whatever the vector's scale")
    func probabilityMath() throws {
        let p1 = try #require(SearchRouter.probability([1, 0, 0, 0], head: head))
        let p7 = try #require(SearchRouter.probability([7, 0, 0, 0], head: head))
        #expect(abs(p1 - p7) < 1e-12)
        #expect(abs(p1 - 1 / (1 + exp(-(2 - 0.5)))) < 1e-12)
        // The fourth axis pulls toward local: normalised [0, 0, 0, 1] → z = -1 - 0.5.
        let local = try #require(SearchRouter.probability([0, 0, 0, 3], head: head))
        #expect(abs(local - 1 / (1 + exp(1.5))) < 1e-12)
        let decision = SearchRouter.decide(for: "q", embed: { _ in [0, 0, 0, 3] }, head: head)
        #expect(decision.verdict == .local)
        #expect(decision.probability.map { abs($0 - local) < 1e-12 } == true)
    }

    @Test("an untrained head (no weights) scores nothing and never vetoes")
    func untrainedNeverVetoes() {
        let untrained = SearchRouter.Head(threshold: 1, bias: 0, weights: [])
        #expect(!untrained.isTrained)
        #expect(head.isTrained)
        #expect(SearchRouter.probability([], head: untrained) == nil)
        let decision = SearchRouter.decide(
            for: "tell me the history of Dublin", embed: { _ in [1, 0, 0, 0] }, head: untrained
        )
        #expect(decision == SearchRouter.Decision(verdict: .web, probability: nil))
    }

    @Test("the shipped head is the untrained stub, or 512 finite weights with a threshold inside (0, 1)")
    func shippingShape() {
        let shipping = SearchRouter.Head.shipping
        guard shipping.isTrained else {
            #expect(shipping.weights.isEmpty)
            return
        }
        #expect(shipping.weights.count == 512)
        let finite = shipping.weights.allSatisfy { $0.isFinite }
        #expect(finite)
        #expect(shipping.bias.isFinite)
        #expect(shipping.threshold > 0 && shipping.threshold < 1)
    }
}

/// The shipped search head over the real embedder, scored on the eval fixtures and the #680 lines
/// it was NOT trained on. Needs Apple's English sentence embedding.
@Suite(.enabled(if: NLEmbedding.sentenceEmbedding(for: .english) != nil))
struct SearchRouterFixtureTests {
    private let embedder = NLSentenceEmbedder()

    /// #680, live on 2026-10-25 (voice, Big): both turns web-searched a stable history.
    static let issue680Lines = ["tell me the history of Dublin", "what about Cork?"]

    @Test("every tool-use fixture that must read the web is never vetoed (a veto would hide the read it needs)")
    func webReadFixturesAreNeverVetoed() {
        let webReads = ChatEvalFixtures.toolUse.filter { fixture in
            let required = (fixture.expectation.mustCallTool.map { [$0] } ?? []) + fixture.expectation.alsoCallTools
            return required.contains { ToolDispatch.webSourced.contains($0) }
        }
        #expect(webReads.count >= 6, "the web-read fixtures went missing: \(webReads.map(\.id))")
        let vetoed = webReads.filter { SearchRouter.decide(for: $0.prompt, embed: embedder.vector).verdict == .local }
        #expect(vetoed.isEmpty, "vetoed: \(vetoed.map(\.id))")
    }

    @Test("stable knowledge and the #680 lines stay local", .enabled(if: SearchRouter.Head.shipping.isTrained))
    func stableKnowledgeStaysLocal() {
        let prompts = ChatEvalFixtures.worldKnowledge.map(\.prompt) + Self.issue680Lines
        let searched = prompts.filter { SearchRouter.decide(for: $0, embed: embedder.vector).verdict == .web }
        #expect(searched.isEmpty, "still searching: \(searched)")
    }

    @Test("most open chat and humour stays local", .enabled(if: SearchRouter.Head.shipping.isTrained))
    func chatMostlyStaysLocal() {
        let chat = ChatEvalFixtures.openChat + ChatEvalFixtures.humour
        let local = chat.filter { SearchRouter.decide(for: $0.prompt, embed: embedder.vector).verdict == .local }
        #expect(local.count * 2 >= chat.count, "only \(local.count)/\(chat.count) chat fixtures stayed local")
    }
}
