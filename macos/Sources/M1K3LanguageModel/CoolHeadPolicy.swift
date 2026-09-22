//
//  CoolHeadPolicy.swift
//  M1K3LanguageModel
//
//  "Cool Head" — M1K3 respects the machine it runs on. Under thermal or power
//  pressure it caps EFFORT (agent-loop iterations, background work) and, at the
//  extreme, defers heavy generation with an honest message. It deliberately does
//  NOT swap the user's chosen brain: the brain is an identity choice ("Lil M1K3"),
//  a swap is a full model reload that dumps the KV + persona-prefix caches, and
//  auto-demoting the proud MLX brain to the weaker AFM both costs more and breaks
//  trust. Capping effort is the cheap, coherent, mid-conversation-safe lever
//  (LocalAgent.maxIterations is already just an Int).
//
//  Pure + off-device testable (mirrors EscalationLadder / GlyphTreatment). The
//  ProcessInfo.thermalState / isLowPowerModeEnabled reads and the maxIterations
//  wiring are verify-by-launch — thermal state can't be faked in a unit test.
//
//  Two design constraints, both from a challenger pass:
//   1. HYSTERESIS is mandatory. Degrade immediately (safety) but recover only
//      after a sustained relief streak — a bouncing thermalState would otherwise
//      flip effort every turn, and recovery-then-degrade is the worst case under
//      load. `next` enforces this; the caller threads the state per turn.
//   2. No Signal-B (throughput) yet. tok/s is MLX-only, log-only, and a warm/cold
//      baseline swamp; it targets dev-process contention, not real users. Thermal
//      + low-power cover the genuine "laptop on the knees" case. Fast-follow if
//      on-device logs prove thermal alone misses real-user contention.
//
//  Signed: claude-opus-4-8, 2026-06-20, Confidence 0.85 (pure policy TDD'd;
//  challenger-scoped to effort-capping not brain-swapping; wiring + on-device
//  thermal behaviour are the named verify-owed). Prior: Unknown.

import Foundation

/// The effort level M1K3 runs a turn at — NOT a brain. Ordered by severity.
public enum CoolHeadLevel: Sendable, Equatable, Comparable, CaseIterable {
    case full // no constraint
    case eased // trim the agent loop, pause background work
    case minimal // defer heavy generation, honest message

    private var severity: Int {
        switch self {
        case .full: 0
        case .eased: 1
        case .minimal: 2
        }
    }

    public static func < (lhs: CoolHeadLevel, rhs: CoolHeadLevel) -> Bool {
        lhs.severity < rhs.severity
    }
}

/// The committed level plus the relief streak (consecutive turns whose pressure
/// has justified a LOWER level). Threaded by the caller across turns so `next`
/// can apply recovery hysteresis.
public struct CoolHeadState: Sendable, Equatable {
    public let level: CoolHeadLevel
    public let recoverStreak: Int

    public init(level: CoolHeadLevel = .full, recoverStreak: Int = 0) {
        self.level = level
        self.recoverStreak = recoverStreak
    }
}

public enum CoolHeadPolicy {
    /// Raw pressure → the level it justifies (no hysteresis). Critical thermal
    /// dominates; low-power eases; otherwise full.
    public static func target(thermal: ProcessInfo.ThermalState, lowPower: Bool) -> CoolHeadLevel {
        switch thermal {
        case .critical: return .minimal
        case .serious: return .eased
        case .fair, .nominal: return lowPower ? .eased : .full
        @unknown default: return .eased // an unknown (likely-worse) state errs safe
        }
    }

    /// Fold this turn's `target` into the running state. Degrade immediately;
    /// recover only after `minRecoveryTurns` of SUSTAINED relief (a single turn
    /// whose pressure still matches the current level resets the streak — anti-flap).
    public static func next(
        _ current: CoolHeadState, target: CoolHeadLevel, minRecoveryTurns: Int
    ) -> CoolHeadState {
        if target > current.level {
            return CoolHeadState(level: target, recoverStreak: 0) // rising pressure: now
        }
        if target == current.level {
            return CoolHeadState(level: current.level, recoverStreak: 0) // justified here: reset relief
        }
        // target < current.level → relief wanted; gate it on a sustained streak.
        let streak = current.recoverStreak + 1
        if streak >= max(1, minRecoveryTurns) {
            return CoolHeadState(level: target, recoverStreak: 0)
        }
        return CoolHeadState(level: current.level, recoverStreak: streak)
    }

    // MARK: - Effort knobs

    /// The agent-loop cap for a level, never RAISING the caller's `base` budget.
    /// Eased allows one tool call (3 iterations: call → observe → conclude);
    /// minimal gets one shot (no tools).
    public static func maxIterations(for level: CoolHeadLevel, base: Int) -> Int {
        switch level {
        case .full: base
        case .eased: min(base, 3)
        case .minimal: min(base, 1)
        }
    }

    /// Speculative/background work (constellation polling, re-embed) runs only at full effort.
    public static func allowsBackgroundWork(_ level: CoolHeadLevel) -> Bool {
        level == .full
    }

    /// At minimal, a heavy on-device decode is deferred with an honest message
    /// rather than piling onto an already-throttling machine.
    public static func defersHeavyGeneration(_ level: CoolHeadLevel) -> Bool {
        level == .minimal
    }
}
