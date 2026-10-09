//
//  GenerationActivity.swift
//  M1K3Inference
//
//  Tells macOS that M1K3 is doing user-requested work while a turn generates, so the
//  process isn't throttled when the display sleeps. Measured 2026-10-07 (the overnight
//  Lil bake-off): with the display off, a headless generation's decode fell 35 → 0–3
//  tok/s and prefill 3.4 s → 24–55 s, on CPU and GPU alike — and recovered ten seconds
//  after the display woke. The same happens to the app: an agent's overnight `ask_m1k3`,
//  a long Big answer after the user walks away.
//
//  `.userInitiatedAllowingIdleSystemSleep` opts the process out of App Nap for the
//  duration and nothing more: the display AND the system still sleep on the user's
//  schedule. (Plain `.userInitiated` would also block idle system sleep — and
//  `caffeinate -is` held that assertion all night without stopping the stall, so the
//  App Nap opt-out is the only part that can help.) Reference-counted, so overlapping
//  turns (a chat turn plus an MCP ask) share one assertion and the last one out ends
//  it. A generation that never returns holds it until it does — there is no timeout.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-07, Confidence 0.8, Prior: none (new file).
//  Open: UNVERIFIED that App Nap is the mechanism (display-off GPU/WindowServer throttling
//  fits the evidence too). The test that decides it: the app with the display forced off,
//  with and without the hold, read tok/s from the unified log + `pmset -g assertions`.
//  Review: same day (pre-push review) — options narrowed from `.userInitiated` (which
//  blocked idle system sleep, contrary to this header) to the App-Nap-only set.
//  Review: Kev + claude-opus-5-5, 2026-10-07 — #498 review follow-ups: `during` runs on the
//  caller's isolation (LocalAgent holds across a whole turn); call sites carry distinct reasons.
//  Review: Kev + claude-fable-5.1, 2026-10-09 — `-generationActivity NO` at launch turns the hold
//  off (arm B of tools/perf/display_off_ab.sh, the A/B that decides the Open above). A test
//  switch only: no UI, no default change; read through one reader like `-afm.prefixPrewarm`.

import Foundation
import Synchronization

/// An opaque process-activity handle (`ProcessInfo.beginActivity` returns an
/// `NSObjectProtocol`, which isn't Sendable; it is only ever handed back to `end`).
public struct ActivityToken: @unchecked Sendable {
    let object: any NSObjectProtocol

    public init(_ object: any NSObjectProtocol) {
        self.object = object
    }
}

/// The seam over `ProcessInfo` so the bookkeeping is testable.
public protocol ActivityAsserting: Sendable {
    func begin(reason: String) -> ActivityToken
    func end(_ token: ActivityToken)
}

public struct ProcessActivityAsserter: ActivityAsserting {
    static let options: ProcessInfo.ActivityOptions = .userInitiatedAllowingIdleSystemSleep

    public init() {}

    public func begin(reason: String) -> ActivityToken {
        ActivityToken(ProcessInfo.processInfo.beginActivity(options: Self.options, reason: reason))
    }

    public func end(_ token: ActivityToken) {
        ProcessInfo.processInfo.endActivity(token.object)
    }
}

public final class GenerationActivity: Sendable {
    /// Launch-argument key: `M1K3 -generationActivity NO` runs without the hold (the A/B's arm B).
    public static let defaultsKey = "generationActivity"

    public static let shared = GenerationActivity(
        asserter: ProcessActivityAsserter(),
        enabled: isEnabled(in: .standard)
    )

    /// Absent means on; a launch-argument string reads the way its words say ("NO", "false",
    /// "0" off) — `object(forKey:) as? Bool` would read "NO" as nil (the #324 consent bug).
    public static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: defaultsKey) == nil || defaults.bool(forKey: defaultsKey)
    }

    private let asserter: any ActivityAsserting
    private let enabled: Bool
    private let state = Mutex<(holders: Int, token: ActivityToken?)>((0, nil))

    public init(asserter: any ActivityAsserting, enabled: Bool = true) {
        self.asserter = asserter
        self.enabled = enabled
    }

    /// Turns in flight right now.
    var holders: Int {
        state.withLock { $0.holders }
    }

    /// Run `work` with the activity held; it ends when the last overlapping hold returns
    /// or throws. `reason` names the first holder (macOS shows it in `pmset -g assertions`).
    /// `work` runs on the caller's isolation, so an actor can hold across its own body.
    public func during<T>(
        _ reason: String,
        isolation _: isolated (any Actor)? = #isolation,
        _ work: () async throws -> T
    ) async rethrows -> T {
        enter(reason)
        defer { leave() }
        return try await work()
    }

    private func enter(_ reason: String) {
        state.withLock { state in
            state.holders += 1
            if state.holders == 1, enabled { state.token = asserter.begin(reason: reason) }
        }
    }

    private func leave() {
        state.withLock { state in
            state.holders -= 1
            if state.holders == 0, let token = state.token {
                state.token = nil
                asserter.end(token)
            }
        }
    }
}
