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
//  Review: Kev + claude-fable-5.1, 2026-09-18 (6) — PR #382, the two SUMMONED passes I had not read: `lift` FAILS CLOSED when a control line is still inside the note after
//  both parsers (they read only the tail; NarrativeGuard has no rule for it): empty narrative → the guard's `.empty` → the digest ships,
//  no chips, nothing filed. Only when chips were asked for — the flag-off path is still TodoProposalLine alone. Confidence 0.9.
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

    /// ASK first, then TODO, then a fail-closed check that no control line is left
    /// inside the note. `PulseAskLine.extract` is order-independent with the
    /// TODO line and hands it on as the LAST line — the only place the TODO parser
    /// looks. With `mayAuthorChips` false nothing is lifted that nobody asked for:
    /// the text goes to the TODO parser untouched, exactly the path that existed
    /// before chips did.
    public static func lift(_ answer: String, mayAuthorChips: Bool, todo: TodoLifter) -> Lifted {
        guard mayAuthorChips else {
            let split = todo(answer)
            return Lifted(narrative: split.narrative, asks: [], todoTitle: split.title)
        }
        let asked = PulseAskLine.extract(from: answer)
        let split = todo(asked.narrative)
        // FAIL CLOSED on a control line still inside the note. The two parsers read
        // only the tail, so `ASK: …` or `TODO: …` stranded mid-prose survives them —
        // and NarrativeGuard has no rule for it, so it would be stored and SHOWN as
        // the pulse. An empty narrative is the guard's `.empty` verdict: the digest
        // ships, no chips ride it, and nothing is filed from a note this malformed.
        let stranded = split.narrative.split(separator: "\n").contains { PulseAskLine.controlKind(of: String($0)) != nil }
        guard !stranded else { return Lifted(narrative: "", asks: [], todoTitle: nil) }
        return Lifted(narrative: split.narrative, asks: asked.asks, todoTitle: split.title)
    }
}
