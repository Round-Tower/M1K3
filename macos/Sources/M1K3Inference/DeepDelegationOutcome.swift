//
//  DeepDelegationOutcome.swift
//  M1K3Inference
//
//  The escalation instrument: one pure, greppable line per delegate_deep
//  invocation, whatever happened to it.
//
//  Why this exists. `startDeepDelegation` logged a `.notice` only on the START
//  path, so both refusal branches — single-flight and eligibility — returned
//  their model-facing "Error: …" observation and left no trace at all. Eight
//  days of unified log with the tool in every palette showed ZERO
//  `delegate_deep` entries, and that reading was ambiguous in the worst
//  possible way: "the model never called it" (a prompting/description problem)
//  and "the app refused every call" (a plumbing problem) are indistinguishable
//  from silence, and they demand opposite fixes.
//
//  The invariant that resolves it — pinned in DeepDelegationOutcomeTests — is
//  that EVERY invocation renders exactly one line under the shared
//  `delegate_deep ` prefix. Once that holds, an empty grep is evidence rather
//  than a shrug.
//
//  Pure and dependency-free so the wording is unit-pinned rather than living
//  untested in app glue — the same reason ChatFailureMessage and
//  HeartbeatHoldLine are their own types.
//
//  Signed: Kev + claude-opus-5, 2026-08-09, Confidence 0.9, Prior: Unknown
//  Context: macos/docs/NEXT_SESSION.md work-order item 3 ("instrument the
//  escalation lane before designing on it").
//

import Foundation

/// What became of one `delegate_deep` call, rendered for the unified log.
public enum DeepDelegationOutcome: Equatable, Sendable {
    /// The dive started on the named brain.
    case started(brain: String)
    /// The call was refused, and why.
    case declined(reason: DeclineReason)

    /// Every way a delegation can be turned away. Raw values are stable
    /// machine-readable slugs — they are log grammar, not prose, so they can be
    /// counted across a corpus of logs without matching on sentences.
    public enum DeclineReason: String, Equatable, Sendable, CaseIterable {
        /// The model called the tool with a blank task (caught in the tool
        /// itself, before the manager is ever reached).
        case emptyTask = "empty-task"
        /// A dive was already in flight — one at a time, by design.
        case alreadyRunning = "already-running"
        /// Mini is the selected brain: no weight-backed resident to hand to.
        case noDeepBrain = "no-deep-brain"
        /// The MLX brain exists but isn't warm (downloading / preparing / failed).
        case deepBrainNotReady = "deep-brain-not-ready"
        /// No AFM to front the conversation while the slot digs.
        case noFrontBrain = "no-front-brain"
    }

    /// The single line to emit. `.notice` at the call site: `.info`/`.debug` do
    /// not persist in OSLogStore, and a breadcrumb that evaporates cannot
    /// settle the question this instrument exists to settle.
    public var logLine: String {
        switch self {
        case let .started(brain):
            "delegate_deep started on \(brain)"
        case let .declined(reason):
            "delegate_deep declined: \(reason.rawValue)"
        }
    }
}

public extension DeepDelegationPolicy.Eligibility {
    /// The log slug for an ineligible verdict — `nil` when eligible, mirroring
    /// `refusalObservation` exactly. The two must stay in lockstep: the
    /// observation is what the model hears, this is what we see, and a refusal
    /// carrying only one of them is either mute or invisible.
    var declineReason: DeepDelegationOutcome.DeclineReason? {
        switch self {
        case .eligible: nil
        case .noDeepBrain: .noDeepBrain
        case .deepBrainNotReady: .deepBrainNotReady
        case .noFrontBrain: .noFrontBrain
        }
    }
}
