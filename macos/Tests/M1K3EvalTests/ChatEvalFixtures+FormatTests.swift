//
//  ChatEvalFixtures+FormatTests.swift
//  M1K3EvalTests
//
//  The `format` kind's fixtures are hand-data; this pins the shape the scorer and the stage assume
//  (#716): closed-book, no prompt names the shape it scores (the difference from `document`), each
//  family's expectation is the one the kind exists to measure, at least two fixtures carry
//  `spokenNoMarkup`, and the kind is LAST so every older report's row order holds. The shared pins
//  (five per kind, unique ids, every forbidden marker fires, `all` is the concatenation) live in
//  ChatEvalFixturesTests and cover these fixtures too.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-26, Confidence 0.85. Prior: none (new file).
//  Review: same day (pre-push review fold) — the how-to pin is three dotted steps in `mustContainAll` (the scorer
//  reads the first line as a line start now, so step 1 may open the answer); bold is forbidden only on the pure
//  banter bid, because the shape bullet allows the key fact bold once and the Cork bid carries one. Confidence 0.85.
//  Review: Kev + claude-opus-5.5, 2026-10-27 — #729's master merge appends `mechanic` after `format`: the order pin
//  reads "right after grounded-long" instead of "last". Confidence 0.9.
//

import Foundation
@testable import M1K3Eval
import Testing

struct ChatEvalFixturesFormatTests {
    /// Shape follows content UNPROMPTED: a compare wants a GFM separator and both names, a how-to a "1." at a
    /// line start, small talk no markdown at all (and no mustComply: a bid for an opinion may read as a decline
    /// and still be the right answer), and the voice-path fixtures carry `spokenNoMarkup`.
    @Test("format fixtures: closed-book, shape never named in the prompt, each family pinned, kind last")
    func formatFixturesShape() {
        let fixtures = ChatEvalFixtures.fixtures(for: .format)
        #expect(fixtures.count >= 5)
        let separators = ["|---", "| ---", "|:--", "| :--"]
        var families: Set<String> = []
        var spoken = 0
        for fixture in fixtures {
            let exp = fixture.expectation
            #expect(fixture.seedDoc == nil && fixture.images.isEmpty, "\(fixture.id) is closed-book")
            #expect(!exp.lengthIsHard, "\(fixture.id): a long answer is not a defect")
            #expect(exp.mustNotContain.contains("<think>"), "\(fixture.id) guards the scaffolding leak")
            let prompt = fixture.prompt.lowercased()
            for word in ["table", "numbered", "markdown", "bullet", "list", "bold", "heading"] {
                #expect(!prompt.contains(word), "\(fixture.id) asks for the shape it scores: \(word)")
            }
            if exp.spokenNoMarkup { spoken += 1 }
            let family = fixture.id.split(separator: "-").dropFirst().first.map(String.init) ?? ""
            families.insert(family)
            switch family {
            case "compare":
                #expect(exp.mustContainAny.contains { separators.contains($0) }, "\(fixture.id) wants a table")
                #expect(exp.mustContainAll.count >= 2, "\(fixture.id) wants both names")
                #expect(exp.mustComply && exp.wholeWordFacts)
            case "howto":
                // Three dotted steps at line starts; the answer may open with step 1 (the scorer's first-line read).
                for step in ["\n1.", "\n2.", "\n3."] {
                    #expect(exp.mustContainAll.contains(step), "\(fixture.id) wants step \(step.debugDescription)")
                }
                #expect(exp.mustContainAny.isEmpty && exp.mustComply && exp.wholeWordFacts)
            case "smalltalk":
                #expect(exp.mustContainAny.isEmpty && exp.mustContainAll.isEmpty)
                for marker in ["|", "```", "\n#", "\n- ", "\n* ", "\n1. "] {
                    #expect(exp.mustNotContain.contains(marker), "\(fixture.id) allows \(marker.debugDescription)")
                }
                #expect(!exp.mustComply && !exp.spokenNoMarkup)
            case "voice":
                #expect(exp.spokenNoMarkup && exp.mustComply)
            default:
                Issue.record("\(fixture.id): unknown format family \(family)")
            }
        }
        #expect(families == ["compare", "howto", "smalltalk", "voice"])
        #expect(spoken >= 2)
        // Bold is the one markup banter may carry (the shape bullet: the key fact, once), so only the bid with
        // nothing to bold forbids it; the Cork bid invites a fact.
        #expect(fixtures.filter { $0.expectation.mustNotContain.contains("**") }.map(\.id) == ["fmt-smalltalk-mind"])
        // Right after grounded-long, with newer kinds (#697's mechanic) only appended after it, so every older
        // report's row order is unchanged.
        #expect(TaskKind.allCases.firstIndex(of: .format).map { TaskKind.allCases[$0 - 1] } == .groundedLong)
        #expect(TaskKind.format.rawValue == "format")
    }

    /// The small-talk markers are punctuation, so the whole-word matcher needs no boundary: each fires on a
    /// banter answer that uses it, and a clean paragraph fires none. Bold is the shape bullet's own allowance
    /// (the key fact, once): the fact-bearing Cork bid takes one, the pure banter bid has nothing to bold.
    @Test("a small-talk fixture fails on structure, pure banter fails on bold too, and clean prose passes both")
    func smallTalkMarkersFire() throws {
        let cork = try #require(ChatEvalFixtures.format.first { $0.id == "fmt-smalltalk-cork" })
        let mind = try #require(ChatEvalFixtures.format.first { $0.id == "fmt-smalltalk-mind" })
        func forbidden(_ fixture: ChatEvalFixture, _ answer: String) -> CheckOutcome? {
            ChatEvalScorer.score(fixture: fixture, observation: EvalObservation(rawText: answer))
                .checks.first { $0.name == "excludes forbidden" }?.outcome
        }
        let clean = "Grand, if you like your rain sideways. The jazz weekend is the reason to come; "
            + "the English Market is the reason to stay dry. Bring a proper coat and you'll be fine."
        #expect(forbidden(cork, clean) == .pass)
        #expect(forbidden(mind, clean) == .pass)
        for marked in [
            "Cork in October:\n\n| Month | Rain |\n|---|---|\n| Oct | plenty |",
            "Two things:\n- the jazz weekend\n- the market",
            "Two things:\n* the jazz weekend\n* the market",
            "Here's the plan:\n1. Pack a coat.\n2. Go anyway.",
            "# Cork in October\nGrand, mostly.",
            "Try this:\n```\nbring a coat\n```",
        ] {
            #expect(forbidden(cork, marked) == .fail, Comment(rawValue: marked))
            #expect(forbidden(mind, marked) == .fail, Comment(rawValue: marked))
        }
        let oneBoldFact = "Grand: the **jazz weekend** is the last of October, and the rain is sideways either way."
        #expect(forbidden(cork, oneBoldFact) == .pass)
        #expect(forbidden(mind, "I used to think **tabs** were right. Spaces, now.") == .fail)
    }
}
