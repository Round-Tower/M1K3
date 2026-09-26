import Foundation
@testable import M1K3Eval
import Testing

struct CallSummaryScorerTests {
    private let fixture = CallSummaryFixture(
        id: "t",
        title: "test",
        transcript: "A: ship Monday\nB: I'll send the deck",
        facts: [["monday"], ["deck", "slides"]],
        actions: [["send", "deck"]],
        traps: ["friday"]
    )

    @Test("a summary that names every fact and action, and no trap, passes")
    func cleanPass() {
        let output = CallSummaryOutput(
            quick: "They agreed to ship Monday.",
            overview: "Shipping moves to Monday; B owns the slides.",
            keyPoints: ["Ship Monday"],
            actionItems: ["B to send the deck"]
        )
        let score = CallSummaryScorer.score(output, against: fixture)
        #expect(score.factRecall == 1)
        #expect(score.actionRecall == 1)
        #expect(score.trapsHit.isEmpty)
        #expect(score.passed)
    }

    @Test("any alias in a fact group counts, case-insensitively")
    func aliases() {
        let output = CallSummaryOutput(quick: nil, overview: "MONDAY launch, SLIDES from B", keyPoints: [], actionItems: [])
        #expect(CallSummaryScorer.score(output, against: fixture).factRecall == 1)
    }

    @Test("an action counts only when every term lands in ONE action item")
    func actionsNeedAllTermsInOneItem() {
        let split = CallSummaryOutput(quick: nil, overview: "", keyPoints: [], actionItems: ["send it", "the deck"])
        #expect(CallSummaryScorer.score(split, against: fixture).actionRecall == 0)
        let whole = CallSummaryOutput(quick: nil, overview: "", keyPoints: [], actionItems: ["Send the deck"])
        #expect(CallSummaryScorer.score(whole, against: fixture).actionRecall == 1)
    }

    @Test("an action term can list alternatives with |")
    func actionAlternatives() {
        let home = CallSummaryFixture(id: "h", title: "h", transcript: "T: I'll be home", facts: [], actions: [["home|present"]], traps: [])
        let output = CallSummaryOutput(quick: nil, overview: "x", keyPoints: [], actionItems: ["Tenant will be present"])
        #expect(CallSummaryScorer.score(output, against: home).actionRecall == 1)
    }

    @Test("a trap anywhere in the output is a hallucination and fails the case")
    func trapFails() {
        let output = CallSummaryOutput(
            quick: "Ship Friday.", overview: "Monday, deck", keyPoints: [], actionItems: ["send the deck"]
        )
        let score = CallSummaryScorer.score(output, against: fixture)
        #expect(score.trapsHit == ["friday"])
        #expect(!score.passed)
    }

    @Test("a missing deep summary fails even when the quick one is fine")
    func missingDeepFails() {
        let output = CallSummaryOutput(quick: "Ship Monday, deck.", overview: nil, keyPoints: [], actionItems: [])
        let score = CallSummaryScorer.score(output, against: fixture)
        #expect(!score.deepPresent)
        #expect(!score.passed)
    }

    @Test("a call with no actions passes only if none are invented")
    func noInventedActions() {
        let chat = CallSummaryFixture(
            id: "c", title: "chat", transcript: "A: hi", facts: [["hi"]], actions: [], traps: []
        )
        let quiet = CallSummaryOutput(quick: nil, overview: "They said hi", keyPoints: [], actionItems: [])
        #expect(CallSummaryScorer.score(quiet, against: chat).passed)
        let invented = CallSummaryOutput(
            quick: nil, overview: "They said hi", keyPoints: [], actionItems: ["Schedule a follow-up"]
        )
        let score = CallSummaryScorer.score(invented, against: chat)
        #expect(score.inventedActions == 1)
        #expect(!score.passed)
    }

    @Test("\"None\" style placeholders are not invented actions")
    func placeholdersAreNotActions() {
        let chat = CallSummaryFixture(id: "c", title: "chat", transcript: "A: hi", facts: [], actions: [], traps: [])
        let output = CallSummaryOutput(quick: nil, overview: "hi", keyPoints: [], actionItems: ["None.", "N/A"])
        #expect(CallSummaryScorer.score(output, against: chat).inventedActions == 0)
    }

    @Test("every shipped fixture is well-formed: facts are said in the transcript, traps are not asserted")
    func fixturesAreHonest() {
        #expect(CallSummaryFixtures.all.count >= 5)
        #expect(Set(CallSummaryFixtures.all.map(\.id)).count == CallSummaryFixtures.all.count)
        for fixture in CallSummaryFixtures.all {
            let said = fixture.transcript.lowercased()
            for group in fixture.facts {
                #expect(group.contains { said.contains($0) }, "\(fixture.id): \(group) never said")
            }
            for terms in fixture.actions {
                for term in terms {
                    let options = term.split(separator: "|").map(String.init)
                    #expect(options.contains { said.contains($0) }, "\(fixture.id): \(term) never said")
                }
            }
        }
    }

    @Test("the long call is longer than Mini's whole window")
    func longCallOverflowsMini() throws {
        let long = try #require(CallSummaryFixtures.all.first { $0.id == "long-planning" })
        // ~4 chars a token: over 4,096 tokens of transcript alone.
        #expect(long.transcript.count > 4096 * 4)
    }
}
