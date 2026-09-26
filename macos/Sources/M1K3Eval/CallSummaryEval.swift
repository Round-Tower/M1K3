//
//  CallSummaryEval.swift
//  M1K3Eval
//
//  Call summarisation had unit tests for its plumbing (two tiers, error
//  isolation, the parser) and nothing that asked whether a summary is any
//  good. This is the quality half: synthetic calls (never a real recording),
//  each with the facts a summary must carry, the action items it must list,
//  and traps it must not assert (a date that was retracted, a number that was
//  corrected, a name never said). The scorer is deterministic and plain-string
//  so this target stays free of M1K3Calls; the live runner lives in
//  M1K3CallsTests (CallSummaryLiveEvalTests).
//
//  Signed: Kev + claude-opus-5-5, 2026-09-26, Confidence 0.8 (substring scoring
//  is blunt: it can miss a paraphrase and can't judge tone; the traps are the
//  sharp edge). Prior: ChatEvalScorer's must/must-not shape.
//

import Foundation

public struct CallSummaryFixture: Sendable, Equatable {
    public let id: String
    public let title: String
    /// Speaker-prefixed, the shape `CallSession.plainTranscript` produces.
    public let transcript: String
    /// Each group is one fact; any alias in it counts (lowercased substrings).
    public let facts: [[String]]
    /// Each group is one action item; EVERY term must land in the same item.
    /// A term may list alternatives: "home|present".
    public let actions: [[String]]
    /// Things the call retracted, corrected or never said. Any hit is a fail.
    public let traps: [String]

    public init(id: String, title: String, transcript: String, facts: [[String]], actions: [[String]], traps: [String]) {
        self.id = id
        self.title = title
        self.transcript = transcript
        self.facts = facts
        self.actions = actions
        self.traps = traps
    }
}

/// The pipeline's output as plain strings (quick gist + the deep sections).
public struct CallSummaryOutput: Sendable, Equatable, Codable {
    public let quick: String?
    public let overview: String?
    public let keyPoints: [String]
    public let actionItems: [String]

    public init(quick: String?, overview: String?, keyPoints: [String], actionItems: [String]) {
        self.quick = quick
        self.overview = overview
        self.keyPoints = keyPoints
        self.actionItems = actionItems
    }
}

public struct CallSummaryScore: Sendable, Equatable, Codable {
    public let fixtureID: String
    public let quickPresent: Bool
    public let deepPresent: Bool
    public let factRecall: Double
    public let actionRecall: Double
    public let trapsHit: [String]
    /// Action items listed on a call that had none to list.
    public let inventedActions: Int

    /// The bar: a deep summary exists, carries most facts and every action,
    /// asserts no trap, and invents no work.
    public var passed: Bool {
        deepPresent && factRecall >= 0.75 && actionRecall == 1 && trapsHit.isEmpty && inventedActions == 0
    }
}

public enum CallSummaryScorer {
    public static func score(_ output: CallSummaryOutput, against fixture: CallSummaryFixture) -> CallSummaryScore {
        let whole = ([output.quick, output.overview].compactMap { $0 } + output.keyPoints + output.actionItems)
            .joined(separator: "\n").lowercased()
        let items = output.actionItems.map { $0.lowercased() }.filter { !isPlaceholder($0) }

        let factHits = fixture.facts.count { group in group.contains { whole.contains($0) } }
        let actionHits = fixture.actions.count { terms in
            items.contains { item in
                terms.allSatisfy { term in term.split(separator: "|").contains { item.contains($0) } }
            }
        }
        return CallSummaryScore(
            fixtureID: fixture.id,
            quickPresent: !(output.quick ?? "").isEmpty,
            deepPresent: !(output.overview ?? "").isEmpty || !output.keyPoints.isEmpty || !items.isEmpty,
            factRecall: ratio(factHits, fixture.facts.count),
            actionRecall: ratio(actionHits, fixture.actions.count),
            trapsHit: fixture.traps.filter { whole.contains($0) },
            inventedActions: fixture.actions.isEmpty ? items.count : 0
        )
    }

    private static func ratio(_ hits: Int, _ total: Int) -> Double {
        total == 0 ? 1 : Double(hits) / Double(total)
    }

    private static func isPlaceholder(_ item: String) -> Bool {
        let bare = item.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return ["none", "n/a", "na", "no action items", "no actions", "nothing"].contains(bare)
    }
}
