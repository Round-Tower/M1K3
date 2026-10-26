//
//  ChatEvalFixtures+GroundedLongTests.swift
//  M1K3EvalTests
//
//  grounded-long exists to overfill the 1,100-token grounding budget, so its shape is the point:
//  six one-chunk sections (`DocumentChunker.targetChars` is 1,200) whose top five hits come to
//  more than the budget, no answer given away by its prompt, and the tail fixture's fact still
//  the last sentence of its section, where `GroundingBudget` truncates first.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-26, Confidence 0.9 (pure). Prior: none (new file).
//

@testable import M1K3Eval
import Testing

struct ChatEvalFixturesGroundedLongTests {
    @Test("the kind is the grounded-long set, five fixtures or more, each over a seeded doc")
    func kindIsTheSet() {
        #expect(ChatEvalFixtures.groundedLong.count >= 5)
        #expect(ChatEvalFixtures.fixtures(for: .groundedLong) == ChatEvalFixtures.groundedLong)
        for fixture in ChatEvalFixtures.groundedLong {
            #expect(fixture.seedDoc != nil, "\(fixture.id) needs a seed doc")
        }
    }

    @Test("every doc is six headed sections of 800–1,150 chars: one chunk each, five overfill the budget")
    func sectionsAreOneChunkEach() {
        let heading = #/\d+ \p{L}.{2,79}/#
        for fixture in ChatEvalFixtures.groundedLong {
            let lines = (fixture.seedDoc ?? "").split(separator: "\n").map(String.init)
            let bodies = lines.filter { (try? heading.wholeMatch(in: $0)) == nil }
            #expect(lines.count - bodies.count == 6, "\(fixture.id): six headed sections")
            for body in bodies {
                #expect((800 ... 1150).contains(body.count), "\(fixture.id): a \(body.count)-char section")
            }
        }
    }

    @Test("no prompt gives its answer away")
    func promptsHideTheirAnswers() {
        for fixture in ChatEvalFixtures.groundedLong where !fixture.id.hasSuffix("-absent") {
            let prompt = fixture.prompt.lowercased()
            let facts = fixture.expectation.mustContainAny + fixture.expectation.mustContainAll
            for fact in facts where fact.count > 3 {
                #expect(!prompt.contains(fact), "\(fixture.id) gives away \(fact)")
            }
        }
    }

    /// Lil's own answers from the first wired 1100 run (2026-10-26), scored as the run scores them.
    @Test("the scorer reads the 1100 run's answers right: honest abstentions pass, a coincidental 145 fails")
    func scorerReadsRealAnswers() throws {
        func passes(_ id: String, _ answer: String) throws -> Bool {
            let fixture = try #require(ChatEvalFixtures.groundedLong.first { $0.id == id })
            return ChatEvalScorer.score(fixture: fixture, observation: EvalObservation(rawText: answer, latencyMS: 1))
                .checks.first { $0.name == "contains expected" }?.outcome == .pass
        }
        // Two honest abstentions the first marker list failed.
        #expect(try passes("long-absent", "Based on the manual snippet you just pulled up, the document itself "
                + "doesn't explicitly state a specific number of years or months for the warranty on the axles."))
        #expect(try passes("long-absent", "Based on the service manual for T-series trailers you just had pulled up, "
                + "there isn't a specific \"warranty period\" listed in the text we found."))
        // An invented term must not pass on the seeded doc's title.
        #expect(try !passes("long-absent", "The warranty on the trailer axle is 24 months (Notes)."))
        // lookup_fact's generic spec carried "145" in the wrong unit: not the manual's figure.
        #expect(try !passes("long-hub-torque", "Standard hub nut torque specifications for most trailer axles "
                + "typically fall between **120 and 145 ft-lbs**."))
        #expect(try passes("long-hub-torque", "The manual says to torque the hub nuts to **145 Nm** in a star pattern."))
    }

    @Test("the torque fact is the last sentence of its section, where a budget truncates first")
    func tailFactStaysLast() {
        let torque = ChatEvalFixtures.groundedLong.first { $0.id == "long-hub-torque" }
        let hubs = torque?.seedDoc?.split(separator: "\n").first { $0.contains("cartridge units") }
        #expect(hubs?.hasSuffix("torque the hub nuts to 145 Nm in a star pattern.") == true)
    }
}
