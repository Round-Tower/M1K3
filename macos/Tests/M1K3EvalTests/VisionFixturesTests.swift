//
//  VisionFixturesTests.swift
//  M1K3EvalTests
//
//  The `vision` kind's invariants: every vision fixture carries an image that
//  really ships in the bundle, nothing else carries one, and a brain that
//  cannot see is reported as n/a — never folded into a pass rate.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-06, Confidence 0.85, Prior: none (new
//  file; GEMMA_1_1_PLAN Stream A).

import Foundation
@testable import M1K3Eval
import Testing

struct VisionFixturesTests {
    @Test("vision fixtures each carry at least one image; no other kind carries any")
    func imagesOnlyOnVision() {
        for fixture in ChatEvalFixtures.all {
            if fixture.kind == .vision {
                #expect(!fixture.images.isEmpty, "\(fixture.id) is a vision fixture with no image")
            } else {
                #expect(fixture.images.isEmpty, "\(fixture.id) is \(fixture.kind.label) but carries images")
            }
        }
    }

    @Test("every image a fixture names resolves to a PNG in the bundle")
    func everyImageShips() throws {
        let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        for fixture in ChatEvalFixtures.vision {
            for name in fixture.images {
                let url = try #require(VisionFixtureAssets.url(for: name), "\(fixture.id): \(name) missing")
                let head = try [UInt8](Data(contentsOf: url).prefix(4))
                #expect(head == pngMagic, "\(name) is not a PNG")
            }
        }
    }

    @Test("an unknown asset name resolves to nil, not a crash")
    func unknownAssetIsNil() {
        #expect(VisionFixtureAssets.url(for: "no-such-image") == nil)
    }

    @Test("vision fixtures are closed-book, deterministic, and fail a blind deflection")
    func visionShape() {
        for fixture in ChatEvalFixtures.vision {
            #expect(fixture.seedDoc == nil, "\(fixture.id): the image IS the material")
            #expect(
                !(fixture.expectation.mustContainAny.isEmpty && fixture.expectation.mustContainAll.isEmpty),
                "\(fixture.id) needs a deterministic expected answer"
            )
            // A seeing brain that answers "I can't see images" — or a route that
            // silently drops the attachment — must FAIL, not pass on a hedge.
            for marker in ["can't see the image", "unable to view the image"] {
                #expect(
                    fixture.expectation.mustNotContain.contains(marker),
                    "\(fixture.id) must fail the blind marker \"\(marker)\""
                )
            }
        }
    }

    @Test("a not-applicable score is flagged and never counted as a pass")
    func notApplicableIsNotAPass() {
        let fixture = ChatEvalFixtures.vision[0]
        let score = ChatEvalScore.notApplicable(fixture, reason: "lil can't see")
        #expect(!score.isApplicable)
        #expect(score.fixtureID == fixture.id)
        #expect(score.kind == .vision)
    }

    @Test("n/a scores leave a brain's totals and the matrix cell")
    func reportExcludesNotApplicable() {
        let vision = ChatEvalFixtures.vision[0]
        let text = ChatEvalFixtures.openChat[0]
        let passing = ChatEvalScore(
            fixtureID: text.id, kind: text.kind,
            checks: [EvalCheck(name: "non-empty", outcome: .pass)], latencyMS: 100
        )
        let blind = BrainRunFixture.run(scores: [passing, .notApplicable(vision, reason: "text-only")])
        #expect(blind.total == 1)
        #expect(blind.passedCount == 1)
        #expect(blind.notApplicableCount == 1)

        let matrix = ChatEvalReport.matrix([blind])
        let visionRow = matrix.split(separator: "\n").first { $0.hasPrefix("vision") }
        #expect(visionRow?.contains("n/a") == true, "matrix: \(matrix)")
        let overall = matrix.split(separator: "\n").first { $0.hasPrefix("overall") }
        #expect(overall?.contains("1/1") == true, "overall must exclude n/a: \(matrix)")
    }
}

extension VisionFixturesTests {
    @Test("blind markers are about the IMAGE — 'I can't see the hidden part of your logic' is not blindness")
    func blindMarkersAreImageAnchored() throws {
        // Big, 2026-10-06 vision baseline: a correct off-by-one answer hedging about unseen code.
        let fixture = try #require(ChatEvalFixtures.vision.first { $0.id == "vis-code-bug" })
        let hedge = "The bug is an off-by-one: use 0..<items.count. Since I can't see the hidden part of your logic, that's my best read."
        let hedged = ChatEvalScorer.score(fixture: fixture, observation: EvalObservation(rawText: hedge))
        #expect(hedged.checks.first { $0.name == "excludes forbidden" }?.outcome == .pass)
        for blind in ["I can't see the image you attached.", "I cannot see any image here.", "No image came through."] {
            let score = ChatEvalScorer.score(fixture: fixture, observation: EvalObservation(rawText: blind))
            #expect(score.checks.first { $0.name == "excludes forbidden" }?.outcome == .fail, "\(blind)")
        }
    }
}

extension VisionFixturesTests {
    private func passes(_ id: String, _ answer: String) throws -> Bool {
        let fixture = try #require(ChatEvalFixtures.vision.first { $0.id == id })
        return ChatEvalScorer.score(fixture: fixture, observation: EvalObservation(rawText: answer)).passed
    }

    @Test("a confabulating answer can't pass on a substring — vision facts match whole words")
    func confabulationDoesNotPassOnASubstring() throws {
        // The pre-push review's cases: each would have passed a raw substring match.
        #expect(try !passes("vis-receipt-count", "I see 3 hinges, total €46.08."))
        #expect(try !passes("vis-chart-max", "May appears highest, approximately."))
        #expect(try !passes("vis-count-circles", "There are 17 red circles."))
        #expect(try !passes("vis-count-squares", "I count 13 blue squares."))
        #expect(try !passes("vis-whiteboard-owner", "Aoife's friend drafts it."))
        // …and the right answers still pass.
        #expect(try passes("vis-receipt-count", "You bought 4 brass hinges."))
        #expect(try passes("vis-chart-max", "April — 67 units."))
        #expect(try passes("vis-count-circles", "1, 2, 3, 4, 5, 6, 7 — seven red circles."))
        #expect(try passes("vis-whiteboard-owner", "Aoife, by Friday."))
        #expect(try passes("vis-dialog-code", "It's error code -36."))
    }

    @Test("yes/no fixtures need the fact behind the answer, not a coin flip")
    func yesNoNeedsTheFact() throws {
        #expect(try !passes("vis-sign-sunday", "Yes."))
        #expect(try passes("vis-sign-sunday", "Yes — the restriction is 8am–6pm Mon–Sat only."))
        #expect(try !passes("vis-ui-bluetooth", "Bluetooth is on; the hotspot is off."))
        #expect(try passes("vis-ui-bluetooth", "Wi-Fi is turned on but Bluetooth is off."))
    }
}

private enum BrainRunFixture {
    static func run(scores: [ChatEvalScore]) -> ChatEvalReport.BrainRun {
        ChatEvalReport.BrainRun(brainID: "lil", scores: scores)
    }
}
