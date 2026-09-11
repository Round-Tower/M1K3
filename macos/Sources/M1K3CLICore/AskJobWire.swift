//
//  AskJobWire.swift
//  M1K3CLICore
//
//  The submit-and-poll contract between `ask_m1k3` and whoever is waiting on
//  it. A turn that outruns its ~8s inline grace comes back not as an answer
//  but as a SENTENCE carrying a job id, and `get_answer` answers a running job
//  with another sentence. That makes the wording load-bearing: `m1k3 ask`
//  decides whether to print or to keep polling by reading it.
//
//  So the fragments live in one place and BOTH sides use them — M1K3MCPKit's
//  IntelligenceMCPTools composes its two sentences here, and CommandRunner
//  reads them back. A reword can no longer break the CLI silently, because
//  there is only one copy of the words to change.
//
//  (Direction of the dependency: M1K3MCPKit imports M1K3CLICore, not the other
//  way round. This module is Foundation-only, so that costs the server nothing
//  — and the contract genuinely belongs on the side that must stay stable for
//  every client, not just ours.)
//
//  Signed: Kev + claude-opus-5, 2026-09-11, Confidence 0.9 (round-trip pinned
//  in M1K3CLICoreTests, and the sentences as they read today held verbatim
//  there so a reword is a visible diff). Prior: Unknown.
//

import Foundation

public enum AskJobWire {
    /// What precedes a quoted job id in the busy line.
    public static let jobIDMarker = "job_id \""
    /// The fragment that means "not finished, ask again".
    public static let stillWorkingOnJob = "still working on job"

    /// What `ask_m1k3` says when a turn outruns its inline grace.
    public static func busyLine(id: String) -> String {
        "M1K3 is still working on this one — it's taking longer than usual "
            + "(a long think or a web search). Call get_answer with \(jobIDMarker)\(id)\" in a "
            + "few seconds to fetch the result. (If get_answer isn't in your tool list, "
            + "call ask_m1k3 again with just that job_id.)"
    }

    /// What `get_answer` says while the job is still running.
    public static func stillWorkingLine(id: String) -> String {
        "M1K3 is \(stillWorkingOnJob) \"\(id)\" — poll again in a few seconds "
            + "(get_answer, or ask_m1k3 with just this job_id)."
    }

    /// The id quoted after the marker, or nil when this is just an answer.
    public static func jobID(in text: String) -> String? {
        guard let marker = text.range(of: jobIDMarker) else { return nil }
        let rest = text[marker.upperBound...]
        guard let close = rest.firstIndex(of: "\"") else { return nil }
        let id = String(rest[..<close])
        return id.isEmpty ? nil : id
    }

    public static func isStillWorking(_ text: String) -> Bool {
        text.contains(stillWorkingOnJob)
    }
}
