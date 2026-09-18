//
//  PulseTail.swift
//  M1K3Heartbeat
//
//  The ORDER in which a pulse's two trailing control lines come off — `ASK:`
//  (PulseAskLine, here) and `TODO:` (TodoProposalLine, in M1K3Todos) — as a
//  function the app CALLS rather than three lines it re-derives.
//
//  Why it exists: the order is load-bearing and was silently wrong once. With
//  TODO: lifted first, a model that wrote its TODO above its ASKs lost the
//  proposal and left `TODO: …` inside the stored narrative. The first fix pinned
//  the right order in a test that re-implemented the app's lines "verbatim" —
//  which stays green while the real call site drifts (M1K3App is outside the
//  package's tests). So the order lives HERE, and both the app and
//  PulseTailTests call it (PR #382, second review pass).
//
//  The TODO parser is INJECTED: M1K3Heartbeat and M1K3Todos do not import each
//  other, and this keeps it that way. The app hands in `TodoProposalLine.extract`;
//  so does the test.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-18, Confidence 0.9 (three lines of
//  ordering, pinned against every tail order and against the flag-off path).
//  Prior: none (new file).
//

import Foundation

public enum PulseTail {
    /// What came off the end of a rendered note, and what is left.
    public struct Lifted: Equatable, Sendable {
        /// The note with neither control line in it.
        public var narrative: String
        /// The ASK lines as written — NOT yet through `PulseAskLine.admit`.
        public var asks: [String]
        public var todoTitle: String?
    }

    /// `TodoProposalLine.extract`'s shape, so it can be passed by name.
    public typealias TodoLifter = (String) -> (narrative: String, title: String?)

    /// ASK first, then TODO. `PulseAskLine.extract` is order-independent with the
    /// TODO line and hands it on as the LAST line — the only place the TODO parser
    /// looks. With `mayAuthorChips` false nothing is lifted that nobody asked for:
    /// the text goes to the TODO parser untouched, exactly the path that existed
    /// before chips did.
    public static func lift(_ answer: String, mayAuthorChips: Bool, todo: TodoLifter) -> Lifted {
        let asked = mayAuthorChips ? PulseAskLine.extract(from: answer) : (narrative: answer, asks: [])
        let split = todo(asked.narrative)
        return Lifted(narrative: split.narrative, asks: asked.asks, todoTitle: split.title)
    }
}
