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
/// boundary instead of prefilling every palette of a brain nobody is using.
public enum PersonaWarmRun {
    /// Returns how many palettes were warmed.
    @discardableResult
    public static func run<Palette: Sendable>(
        _ palettes: [Palette],
        shouldContinue: () async -> Bool,
        warm: (Palette) async -> Void
    ) async -> Int {
        var warmed = 0
        for palette in palettes {
            guard await shouldContinue() else { break }
            await warm(palette)
            warmed += 1
        }
        return warmed
    }
}
