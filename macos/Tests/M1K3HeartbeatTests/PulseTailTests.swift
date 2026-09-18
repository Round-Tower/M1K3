//
//  PulseTailTests.swift
//  M1K3HeartbeatTests
//
//  A pulse's note may trail TWO control lines — `ASK:` (M1K3Heartbeat's
//  PulseAskLine) and `TODO:` (M1K3Todos' TodoProposalLine). The app composes the
//  two parsers; neither module knows the other. This pins the COMPOSITION, in
//  the order the app uses (ASK first, then TODO), against every order a model
//  might write them in. The failure it exists for was silent twice over: with a
//  fixed extraction order, a model that wrote TODO above ASK lost its proposal
//  AND left `TODO: …` sitting inside the stored narrative (PR #382 review).
//
//  Signed: Kev + claude-fable-5.1, 2026-09-18, Confidence 0.9 (the invariant is
//  small and total: whatever the order, both writes are recovered and the
//  narrative carries neither control line). Prior: none (new file).
//  Review: Kev + claude-fable-5.1, 2026-09-18 (4) — PR #382 second-pass fold: the suite now calls `PulseTail.lift` — the function the APP calls — instead of a hand-copied
//  twin of the app's lines, and pins that the flag-off path is `TodoProposalLine.extract` alone. Confidence 0.9.
//  Review: Kev + claude-fable-5.1, 2026-09-18 (6) — PR #382, the two SUMMONED passes I had not read: two tail TODOs and a stranded control line, through the REAL composition. Confidence 0.9.
//

@testable import M1K3Heartbeat
import M1K3Todos
import Testing

struct PulseTailTests {
    /// The function the APP calls (AppEnvironment+Heartbeat.renderHeartbeatNarrative),
    /// handed the real TODO parser exactly as the app hands it. Not a twin of the
    /// app's lines: a twin stays green while the call site drifts (PR #382 second pass).
    private func lift(_ raw: String, mayAuthorChips: Bool = true) -> (narrative: String, asks: [String], todo: String?) {
        let out = PulseTail.lift(raw, mayAuthorChips: mayAuthorChips, todo: TodoProposalLine.extract)
        return (out.narrative, out.asks, out.todoTitle)
    }

    @Test(
        "whatever order the model writes them in, both writes are recovered and neither line reaches the narrative",
        arguments: [
            "Busy day.\nASK: What did I miss?\nASK: And the todo?\nTODO: Renew the domain", // the prompt's order
            "Busy day.\nTODO: Renew the domain\nASK: What did I miss?\nASK: And the todo?", // flipped
            "Busy day.\nASK: What did I miss?\nTODO: Renew the domain\nASK: And the todo?", // sandwiched
            "Busy day.\n\n- ask: What did I miss?\n* Ask: And the todo?\n\n• todo: Renew the domain.\n", // decorated
        ]
    )
    func everyOrder(raw: String) {
        let out = lift(raw)
        #expect(out.narrative == "Busy day.")
        #expect(out.asks == ["What did I miss?", "And the todo?"])
        #expect(out.todo == "Renew the domain")
        #expect(!out.narrative.lowercased().contains("todo:"))
        #expect(!out.narrative.lowercased().contains("ask:"))
    }

    @Test("either write alone still works through the composition")
    func eitherAlone() {
        let onlyTodo = lift("Busy day.\nTODO: Renew the domain")
        #expect(onlyTodo.narrative == "Busy day." && onlyTodo.asks.isEmpty && onlyTodo.todo == "Renew the domain")
        let onlyAsk = lift("Busy day.\nASK: What did I miss?")
        #expect(onlyAsk.narrative == "Busy day." && onlyAsk.asks == ["What did I miss?"] && onlyAsk.todo == nil)
        let neither = lift("Busy day.")
        #expect(neither.narrative == "Busy day." && neither.asks.isEmpty && neither.todo == nil)
    }

    @Test("a note that is ONLY control lines leaves empty prose — the guard's `.empty` path, not a leak")
    func onlyControlLines() {
        let out = lift("ASK: What did I miss?\nTODO: Renew the domain")
        #expect(out.narrative.isEmpty)
        #expect(out.asks == ["What did I miss?"])
        #expect(out.todo == "Renew the domain")
    }

    @Test("chips not asked for: the old path exactly — the TODO parser alone, and an unasked ASK line is left where it lay")
    func flagOffIsTheOldPath() {
        let raw = "Busy day.\nASK: What did I miss?\nTODO: Renew the domain"
        let off = lift(raw, mayAuthorChips: false)
        let old = TodoProposalLine.extract(from: raw)
        #expect(off.narrative == old.narrative)
        #expect(off.todo == old.title)
        #expect(off.asks.isEmpty)
        #expect(off.narrative.contains("ASK: What did I miss?"), "nothing lifts what nobody asked for")
    }

    @Test("★ two TODO lines at the tail: nothing control-shaped reaches the narrative, and ONE proposal is filed")
    func twoTodosAtTheTail() {
        let out = lift("Day.\nASK: Hidden above?\nTODO: first\nTODO: second\nASK: Tail?")
        #expect(out.narrative == "Day.")
        #expect(out.asks == ["Hidden above?", "Tail?"])
        #expect(out.todo == "second") // the one nearest the end — TodoProposalLine's own last-line rule
    }

    @Test("a control line stranded INSIDE the prose fails closed: the digest ships, nothing is filed, no chips")
    func aStrandedControlLineFailsClosed() {
        // extract only reads the tail (a model that scatters ASKs gets none of them) —
        // but the note must not then be PUBLISHED with `ASK: …` sitting in it, and
        // NarrativeGuard has no rule that would stop it. Empty narrative → the guard's
        // `.empty` verdict → the deterministic digest ships instead.
        for raw in [
            "Busy day.\nASK: is this a chip?\nNo — the day went on after that.",
            "Busy day.\n- todo: stranded\nMore prose here.\nASK: What did I miss?",
        ] {
            let out = lift(raw)
            #expect(out.narrative.isEmpty, "\(raw)")
            #expect(out.asks.isEmpty)
            #expect(out.todo == nil)
        }
        // Prose that merely MENTIONS the words is prose.
        let honest = lift("Busy day. I did ask: nobody knew. The todo list grew.\nASK: What did I miss?")
        #expect(honest.narrative == "Busy day. I did ask: nobody knew. The todo list grew.")
        #expect(honest.asks == ["What did I miss?"])
    }
}
