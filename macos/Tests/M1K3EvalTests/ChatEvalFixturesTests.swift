//
//  ChatEvalFixturesTests.swift
//  M1K3EvalTests
//
//  The fixtures are hand-data; these tests guard the invariants the runner and
//  scorer assume — every kind populated, ids unique, expectations matched to
//  their kind — so a careless edit can't silently weaken the eval.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-14, Confidence 0.9. Prior: Unknown

@testable import M1K3Eval
import Testing

struct ChatEvalFixturesTests {
    @Test("every task-kind has at least five fixtures")
    func everyKindCovered() {
        for kind in TaskKind.allCases {
            let count = ChatEvalFixtures.fixtures(for: kind).count
            #expect(count >= 5, "\(kind.label) has only \(count)")
        }
    }

    @Test("fixture ids are unique")
    func uniqueIDs() {
        let ids = ChatEvalFixtures.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("security fixtures are closed-book leak vectors that must decline")
    func securityShape() {
        let security = ChatEvalFixtures.fixtures(for: .security)
        #expect(security.count >= 5)
        for fixture in security {
            #expect(fixture.kind == .security)
            #expect(fixture.seedDoc == nil, "\(fixture.id) is closed-book")
            #expect(fixture.expectation.mustRefuse, "\(fixture.id) must require a decline")
        }
    }

    @Test("world-knowledge fixtures are closed-book, must be ANSWERED, and never cite")
    func worldKnowledgeShape() {
        let world = ChatEvalFixtures.fixtures(for: .worldKnowledge)
        #expect(world.count >= 5)
        for fixture in world {
            #expect(fixture.kind == .worldKnowledge)
            // Closed-book by definition: this kind measures what the model
            // KNOWS, not what it can look up. A seed doc would turn it into a
            // grounded-Q fixture wearing the wrong label.
            #expect(fixture.seedDoc == nil, "\(fixture.id) must be closed-book")
            // Must not cite: with nothing seeded, any citation is a phantom.
            #expect(!fixture.expectation.mustCite, "\(fixture.id) has nothing to cite")
            // ★ Must COMPLY — the failure mode this kind is really hunting is
            // abstention overreach: a RAG-first persona deflecting "what is the
            // capital of Australia?" into "that isn't in your documents". A
            // deflection is a fail even if the model knew the answer.
            #expect(fixture.expectation.mustComply, "\(fixture.id) must require an answer, not a deflection")
            // The scorer is a pure heuristic — every fixture needs a
            // deterministic substring to check against.
            #expect(
                !fixture.expectation.mustContainAny.isEmpty,
                "\(fixture.id) needs a deterministic expected answer"
            )
        }
    }

    @Test("humour and interview fixtures reject the AI-cliché non-answer and must engage")
    func personalityKindsShape() {
        for fixture in ChatEvalFixtures.humour + ChatEvalFixtures.interview {
            #expect(fixture.seedDoc == nil, "\(fixture.id) is closed-book")
            // ★ These kinds must NOT set mustComply. It runs RefusalHeuristic,
            // whose markers ("i can't", "i'm sorry", "i don't make", "nope")
            // are ordinary words in witty prose and in honest self-assessment —
            // a good answer to "what are you bad at?" is full of "I can't…".
            // The check would systematically fail the best answers, so the
            // precise cliché markers do that job instead. Pinned so nobody
            // "helpfully" adds it back.
            #expect(
                !fixture.expectation.mustComply,
                "\(fixture.id) must not use the refusal heuristic — it inverts on this kind"
            )
            #expect(
                fixture.expectation.mustNotContain.contains("as an ai language model"),
                "\(fixture.id) must reject the cliché non-answer"
            )
            // A bound both ways: humour that runs to an essay has explained the
            // joke, and a one-word interview answer is not an answer.
            #expect(fixture.expectation.maxChars != nil, "\(fixture.id) needs a length ceiling")
        }
    }

    @Test("humour fixtures never claim to score funniness — only structure")
    func humourScoresStructureNotFunniness() {
        // Guard rail on the design, not the data: if someone ever adds a
        // mustContainAll of "expected joke text" here, the kind has quietly
        // become a fake metric. Funniness is a human call (see TaskKind.humour).
        for fixture in ChatEvalFixtures.humour {
            #expect(
                fixture.expectation.mustContainAll.isEmpty,
                "\(fixture.id) must not assert specific joke content"
            )
            #expect(!fixture.expectation.mustCite, "\(fixture.id) has nothing to cite")
        }
    }

    @Test("instruction-following fixtures are hard, deterministic bounds")
    func instructionFollowingShape() {
        let fixtures = ChatEvalFixtures.instructionFollowing
        #expect(fixtures.count >= 5)
        for fixture in fixtures {
            #expect(fixture.seedDoc == nil, "\(fixture.id) is closed-book")
            #expect(fixture.expectation.mustComply, "\(fixture.id) must obey, not deflect")
            // Every fixture must carry at least one MECHANICAL check — a length
            // ceiling or a literal format assertion. Without one it is measuring
            // vibes, which is the whole point of this kind not to do.
            let mechanical = fixture.expectation.maxChars != nil
                || !fixture.expectation.mustContainAny.isEmpty
                || !fixture.expectation.mustContainAll.isEmpty
                || !fixture.expectation.mustNotContain.isEmpty
            #expect(mechanical, "\(fixture.id) needs a deterministic bound")
        }
    }

    @Test("all is the concatenation of the per-kind sets")
    func allIsEverything() {
        let perKind = TaskKind.allCases.flatMap { ChatEvalFixtures.fixtures(for: $0) }
        #expect(perKind.count == ChatEvalFixtures.all.count)
    }

    @Test("grounded-Q fixtures seed a doc; non-absent ones require a citation")
    func groundedShape() {
        for fixture in ChatEvalFixtures.groundedQ {
            #expect(fixture.seedDoc != nil, "\(fixture.id) needs a seed doc")
        }
        // The deliberately-absent fixture abstains (no citation possible); the
        // rest demand one.
        let citing = ChatEvalFixtures.groundedQ.filter { $0.expectation.mustCite }
        #expect(citing.count >= 4)
    }

    @Test("plausible-but-wrong fixtures exist and never demand a citation (nothing citable)")
    func falsePremiseShape() {
        let ids: Set = ["ground-wrong-author", "ground-wrong-nobel", "ground-fictional-accord"]
        let fixtures = ChatEvalFixtures.groundedQ.filter { ids.contains($0.id) }
        #expect(fixtures.count == 3)
        for fixture in fixtures {
            #expect(!fixture.expectation.mustCite, "\(fixture.id) has nothing citable")
            #expect(
                !fixture.expectation.mustContainAny.isEmpty,
                "\(fixture.id) needs a correction/abstention marker"
            )
        }
    }

    @Test("tool-use fixtures each name a required tool")
    func toolShape() {
        for fixture in ChatEvalFixtures.toolUse {
            #expect(fixture.expectation.mustCallTool != nil, "\(fixture.id) names no tool")
        }
    }

    @Test("refusal fixtures all expect a refusal")
    func refusalShape() {
        for fixture in ChatEvalFixtures.refusal {
            #expect(fixture.expectation.mustRefuse, "\(fixture.id) doesn't expect refusal")
        }
    }

    @Test("code-gen fixtures are closed-book, must comply, and assert artifact markers")
    func codeGenShape() {
        let codeGen = ChatEvalFixtures.fixtures(for: .codeGen)
        #expect(codeGen.count >= 5)
        for fixture in codeGen {
            #expect(fixture.kind == .codeGen)
            #expect(fixture.seedDoc == nil, "\(fixture.id) is closed-book — generation, not lookup")
            #expect(fixture.expectation.mustComply, "\(fixture.id) must require compliance")
            #expect(!fixture.expectation.mustRefuse, "\(fixture.id) must not expect a refusal")
            #expect(!fixture.expectation.mustContainAny.isEmpty, "\(fixture.id) needs artifact markers")
        }
    }

    @Test("open-chat fixtures guard against scaffolding leak")
    func openChatGuardsLeak() {
        for fixture in ChatEvalFixtures.openChat {
            #expect(fixture.expectation.mustNotContain.contains("<think>"))
        }
    }

    @Test("no fixture sets both mustRefuse and mustComply — the scorer renders them as opposing checks")
    func noFixtureSetsBothRefusalFlags() {
        for fixture in ChatEvalFixtures.all {
            #expect(
                !(fixture.expectation.mustRefuse && fixture.expectation.mustComply),
                "\(fixture.id) sets mutually exclusive flags"
            )
        }
    }
}
