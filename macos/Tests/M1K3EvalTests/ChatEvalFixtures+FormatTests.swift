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
                #expect(exp.mustContainAny.contains("\n1.") || exp.mustContainAny.contains("\n1)"))
                #expect(exp.mustComply)
            case "smalltalk":
                #expect(exp.mustContainAny.isEmpty && exp.mustContainAll.isEmpty)
                for marker in ["|", "**", "```", "\n#", "\n- ", "\n1. "] {
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
        // Last in the enum, so every older report's row order is unchanged.
        #expect(TaskKind.allCases.last == .format)
        #expect(TaskKind.format.rawValue == "format")
    }

    /// The small-talk markers are punctuation, so the whole-word matcher needs no boundary: each fires on a
    /// banter answer that uses it, and a clean paragraph fires none.
    @Test("a small-talk fixture fails on any markdown and passes clean prose")
    func smallTalkMarkersFire() throws {
        let banter = try #require(ChatEvalFixtures.format.first { $0.id.hasPrefix("fmt-smalltalk-") })
        func forbidden(_ answer: String) -> CheckOutcome? {
            ChatEvalScorer.score(fixture: banter, observation: EvalObservation(rawText: answer))
                .checks.first { $0.name == "excludes forbidden" }?.outcome
        }
        let clean = "Grand, if you like your rain sideways. The jazz weekend is the reason to come; "
            + "the English Market is the reason to stay dry. Bring a proper coat and you'll be fine."
        #expect(forbidden(clean) == .pass)
        for marked in [
            "Cork in October:\n\n| Month | Rain |\n|---|---|\n| Oct | plenty |",
            "**Cork** is grand in October.",
            "Two things:\n- the jazz weekend\n- the market",
            "Here's the plan:\n1. Pack a coat.\n2. Go anyway.",
            "# Cork in October\nGrand, mostly.",
            "Try this:\n```\nbring a coat\n```",
        ] {
            #expect(forbidden(marked) == .fail, Comment(rawValue: marked))
        }
    }
}
