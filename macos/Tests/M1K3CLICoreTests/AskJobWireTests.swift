//
//  AskJobWireTests.swift
//  M1K3CLICoreTests
//
//  The one contract the CLI can't see the other side of: `ask_m1k3` answers a
//  slow turn with PROSE carrying a job id, and `get_answer` answers a running
//  job with more prose. `m1k3 ask` reads both by matching fragments — so the
//  fragments live here, the server builds its sentences FROM them, and this
//  file pins the round trip.
//
//  Before this existed, an editor's pass over IntelligenceMCPTools' wording
//  would have made `m1k3 ask` print the receipt instead of the answer, and no
//  test anywhere would have gone red.
//
//  Signed: Kev + claude-opus-5, 2026-09-11, Confidence 0.9 (round-trip pinned
//  both ways, plus the two sentences as they read today held verbatim so a
//  reword is a visible diff). Prior: Unknown.
//

@testable import M1K3CLICore
import Testing

struct AskJobWireTests {
    @Test("a busy line hands back the id it quoted")
    func roundTripsBusyLine() {
        #expect(AskJobWire.jobID(in: AskJobWire.busyLine(id: "7F2A-91")) == "7F2A-91")
    }

    @Test("the still-working line is recognised, and is not mistaken for an answer")
    func recognisesStillWorking() {
        #expect(AskJobWire.isStillWorking(AskJobWire.stillWorkingLine(id: "7F2A-91")))
        #expect(!AskJobWire.isStillWorking("Dublin is the capital of Ireland."))
    }

    @Test("an ordinary answer carries no job id — ask prints it instead of polling")
    func plainAnswerHasNoJobID() {
        #expect(AskJobWire.jobID(in: "Dublin is the capital of Ireland.") == nil)
        #expect(AskJobWire.jobID(in: "") == nil)
    }

    @Test("a marker with nothing quoted after it is not an id")
    func emptyQuoteIsNotAnID() {
        #expect(AskJobWire.jobID(in: "Call get_answer with job_id \"\" in a moment") == nil)
        #expect(AskJobWire.jobID(in: "Call get_answer with job_id \"unterminated") == nil)
    }

    /// ★ The two sentences as M1K3MCPKit emits them TODAY, byte for byte. The
    /// server builds them from the same constants, so this is belt and braces —
    /// but it makes a reword show up as a diff in a test, not as a silent
    /// regression in `m1k3 ask`.
    @Test("the server's own wording still parses")
    func serverWordingParses() {
        let busy = "M1K3 is still working on this one — it's taking longer than usual "
            + "(a long think or a web search). Call get_answer with job_id \"AB12\" in a "
            + "few seconds to fetch the result. (If get_answer isn't in your tool list, "
            + "call ask_m1k3 again with just that job_id.)"
        #expect(AskJobWire.jobID(in: busy) == "AB12")
        #expect(busy == AskJobWire.busyLine(id: "AB12"))

        let running = "M1K3 is still working on job \"AB12\" — poll again in a few seconds "
            + "(get_answer, or ask_m1k3 with just this job_id)."
        #expect(AskJobWire.isStillWorking(running))
        #expect(running == AskJobWire.stillWorkingLine(id: "AB12"))
    }
}
