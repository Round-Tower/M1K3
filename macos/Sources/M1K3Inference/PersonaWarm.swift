//
//  PersonaWarm.swift
//  M1K3Inference
//
//  The bookkeeping behind the persona-prefix warm that follows a brain load. Before 2026-10-20 the warm was a
//  fire-and-forget detached task: three launch paths each started one per load, nothing ever cancelled them, and
//  a brain swap left the OUTGOING provider's warm running. Kev's 1.1.1 session: after Big → Lil, Big prefilled two
//  more 12B palettes over ~80 s (its weights pinned for two minutes), while Lil loaded in 45 s instead of seconds
//  and the first turn waited 49 s for the tokenizer behind the warms.
//
//  `PersonaWarmLedger` holds which provider is warming (one at a time; the same one joins, a new one replaces),
//  and `PersonaWarmRun` walks the palettes, checking between each whether to go on. The app owns the task and
//  cancels it on a swap. Pure, so the contract is pinned under `swift test`; the wiring is verify-by-launch.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-20, Confidence 0.85. Prior: none (new file).
//  Review: Kev + claude-fable-5.2, 2026-11-11 (#621) — the warm waits for quiet before each palette
//  (`PersonaWarmYield`, `beforeEach`). Measured on master that day with Big: a call 8 s after launch got its first
//  word at 19 s, behind the build in flight, and then decoded at 5 tok/s beside the next one (25 alone); Lil 12
//  against 70. A build in flight still finishes: only the palettes after it wait. Confidence 0.8 (the wait is
//  pinned; the gain is verify-by-launch).
//  Open: voice mode's listening is not "being answered", so a voice turn can still meet a build in flight.

import Foundation

/// Which provider's persona warm is running. Generic over the identity (the app uses `ObjectIdentifier`).
public struct PersonaWarmLedger<ID: Hashable & Sendable>: Sendable {
    public enum Decision: Sendable, Equatable {
        /// Nothing is warming: start one.
        case start
        /// This provider is already warming: do nothing (its builds are what a second warm would ask for).
        case alreadyWarming
        /// Another provider is warming: cancel that task and start this one.
        case replace
    }

    private var warming: ID?

    public init() {}

    /// Record a request to warm `provider` and say what to do.
    public mutating func request(for provider: ID) -> Decision {
        defer { warming = provider }
        guard let warming else { return .start }
        return warming == provider ? .alreadyWarming : .replace
    }

    /// A warm ended. Clears the slot only if it is still that provider's — a replaced warm finishing late must not
    /// free its successor's slot.
    public mutating func finished(_ provider: ID) {
        if warming == provider { warming = nil }
    }

    /// The running warm was cancelled (a swap, a dive).
    public mutating func cancel() {
        warming = nil
    }
}

/// Walks the palettes in order, asking `shouldContinue` before each one, so a cancelled warm stops at the next
/// boundary instead of prefilling every palette of a brain nobody is using. `beforeEach` runs ahead of that
/// question: the app waits there for quiet (`PersonaWarmYield`).
public enum PersonaWarmRun {
    /// Returns how many palettes were warmed.
    @discardableResult
    public static func run<Palette: Sendable>(
        _ palettes: [Palette],
        beforeEach: () async -> Void = {},
        shouldContinue: () async -> Bool,
        warm: (Palette) async -> Void
    ) async -> Int {
        var warmed = 0
        for palette in palettes {
            // The wait first, the question after: a swap that lands during the wait must skip this palette.
            await beforeEach()
            guard await shouldContinue() else { break }
            await warm(palette)
            warmed += 1
        }
        return warmed
    }
}

/// The warm's manners: before a palette it waits while someone is being answered, so a build never starts
/// beside a live answer. It checks every `step` and gives up at `limit`, so a caller that never stops cannot
/// keep the person's palettes cold for good.
public enum PersonaWarmYield {
    public enum Outcome: Sendable, Equatable {
        case quiet, limitReached, cancelled
    }

    public static let defaultLimit: Duration = .seconds(120)
    public static let defaultStep: Duration = .milliseconds(500)

    @discardableResult
    public static func untilQuiet(
        busy: () async -> Bool,
        limit: Duration = defaultLimit,
        step: Duration = defaultStep,
        pause: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async -> Outcome {
        var waited: Duration = .zero
        while await busy() {
            guard waited < limit else { return .limitReached }
            do { try await pause(step) } catch { return .cancelled }
            waited += step
        }
        return .quiet
    }
}
