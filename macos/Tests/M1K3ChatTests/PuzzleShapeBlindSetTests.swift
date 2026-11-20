//
//  PuzzleShapeBlindSetTests.swift
//  M1K3ChatTests
//
//  The #713 check on `PuzzleShape.detects`: Resources/puzzle-shape-blind.json is 243 messages labelled puzzle / not
//  by four writers who never saw the detector (2026-11-20; everyday and work traffic in English, everyday traffic
//  and new puzzles in de, fr, es and pt, written in each language, not translated). A false positive costs a
//  speed-tier turn ~30 s on the `think` arm, a false negative a wrong answer, so both rates are reported per
//  language. The run prints COUNTS only, never the failing texts, so the set stays blind for the next measurement.
//
//  Signed: Kev + claude-opus-5-5, 2026-11-20, Confidence 0.75 (one set of writers; labels are theirs). Prior: none.
//  Review: claude-opus-5-5, 2026-11-20 (pre-push review) — the run is now a ratchet: overall recall at least 66/121
//  and false fire at most 8/122 (measured 72/121 and 5/122; the slack is about 5 points of recall and 2 of false
//  fire, room for a tweak but not a regression). The set has been spent once (one fix after its first count), so
//  the next real measurement needs a fresh set from new writers. Confidence 0.8.

import Foundation
@testable import M1K3Chat
import Testing

struct PuzzleShapeBlindSetTests {
    struct Item: Decodable {
        let id: String
        let lang: String
        let puzzle: Bool
        let text: String
    }

    static func load() throws -> [Item] {
        let url = try #require(Bundle.module.url(forResource: "puzzle-shape-blind", withExtension: "json",
                                                 subdirectory: "Resources"))
        return try JSONDecoder().decode([Item].self, from: Data(contentsOf: url))
    }

    @Test("blind set: recall and false fire per language (counts only), with a floor on both")
    func blindSetScore() throws {
        let items = try Self.load()
        #expect(items.count == 243)
        var line: [String] = []
        for lang in ["en", "de", "fr", "es", "pt", "all"] {
            let slice = lang == "all" ? items : items.filter { $0.lang == lang }
            let tp = slice.filter { $0.puzzle && PuzzleShape.detects($0.text) }.count
            let fn = slice.filter { $0.puzzle && !PuzzleShape.detects($0.text) }.count
            let fp = slice.filter { !$0.puzzle && PuzzleShape.detects($0.text) }.count
            let tn = slice.filter { !$0.puzzle && !PuzzleShape.detects($0.text) }.count
            line.append("\(lang): recall \(tp)/\(tp + fn) false-fire \(fp)/\(fp + tn)")
            if lang == "all" {
                #expect(tp >= 66, "blind recall fell below the floor: \(tp)/\(tp + fn)")
                #expect(fp <= 8, "blind false fire rose above the ceiling: \(fp)/\(fp + tn)")
            }
        }
        print("PUZZLESHAPE-BLIND " + line.joined(separator: " | "))
    }
}
