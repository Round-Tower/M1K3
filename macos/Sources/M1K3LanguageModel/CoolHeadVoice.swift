//
//  CoolHeadVoice.swift
//  M1K3LanguageModel
//
//  Cool Head speaks (#697 Phase 1). `CoolHeadPolicy` eases M1K3's effort under heat or Low
//  Power Mode, silently. Now the turn whose send eased it carries ONE line in M1K3's voice,
//  picked from a fixed set (never generated), so the person knows why that answer took fewer
//  steps. The line goes on the activity channel to a caption over the answer: never into a
//  prompt, the replay, distillation or speech.
//
//  Honesty is the rule the copy is built on, pinned in CoolHeadVoiceTests over every line: it
//  says only what `ProcessInfo` reported (running warm or hot, Low Power Mode, the system asking
//  to go easy). No number, because nothing here reads one. No fan: fanless Airs have none and
//  nothing reads one. No battery, charger or "plugged in": Low Power Mode exists on desktops and
//  nothing here reads a battery (that is Phase 2's tool, from a real read). The issue's own
//  example, "Fans are up", breaks the rule and is not in the set. The lines promise EFFORT, not
//  length ("less legwork", "easing off the extra steps"): `.eased` caps the agent loop at one
//  tool call and pauses background work; it does not shorten the answer.
//
//  Once per degrade episode: `announcement` speaks only on the rise INTO `.eased`, and
//  `CoolHeadPolicy.next`'s hysteresis already decides when an episode ends. `.minimal` says
//  nothing here, because that turn's whole answer is the honest deferral
//  (`AgentRAGResponder.coolHeadDeferralMessage`).
//
//  Signed: Kev + claude-opus-5.5, 2026-10-26, Confidence 0.8 (pure and pinned; the copy is a
//  first set for Kev to hear, and the real heat is verify-by-launch on a warm M1 Max).
//  Prior: none (new file).
//

import Foundation

/// What a reading says about why effort eased, in the only terms a line may use.
public enum CoolHeadCause: Sendable, Equatable, CaseIterable {
    /// `ProcessInfo.thermalState` read serious or critical.
    case heat
    /// Low Power Mode is on, and the machine is otherwise cool.
    case lowPower
    /// A thermal state this build doesn't know: the system is asking for less, cause unnamed.
    case unknownPressure
}

/// One send's fold: the state to carry to the next send, and the cause to announce on this one
/// (nil: say nothing).
public struct CoolHeadStep: Sendable, Equatable {
    public let state: CoolHeadState
    public let announcement: CoolHeadCause?

    public init(state: CoolHeadState, announcement: CoolHeadCause?) {
        self.state = state
        self.announcement = announcement
    }
}

public extension CoolHeadPolicy {
    /// The reading behind `target`'s easing, or nil when it doesn't ease. Heat dominates Low
    /// Power, as it does in `target`; an unknown state errs safe there and stays unnamed here.
    static func cause(thermal: ProcessInfo.ThermalState, lowPower: Bool) -> CoolHeadCause? {
        switch thermal {
        case .critical, .serious: .heat
        case .fair, .nominal: lowPower ? .lowPower : nil
        @unknown default: .unknownPressure
        }
    }

    /// The cause to announce for a send that moved `from` → `to`: only the rise into `.eased`.
    /// Holding, deepening to `.minimal` (the deferral speaks), recovering: nil.
    static func announcement(
        from: CoolHeadState, to: CoolHeadState, cause: CoolHeadCause?
    ) -> CoolHeadCause? {
        guard to.level == .eased, from.level < .eased else { return nil }
        return cause
    }

    /// `next` plus the announcement, from a send's readings: what the app runs per send and the
    /// `mechanic` eval runs per fixture, so the two can't drift.
    static func advance(
        _ current: CoolHeadState, thermal: ProcessInfo.ThermalState, lowPower: Bool, minRecoveryTurns: Int
    ) -> CoolHeadStep {
        advance(
            current,
            target: target(thermal: thermal, lowPower: lowPower),
            cause: cause(thermal: thermal, lowPower: lowPower),
            minRecoveryTurns: minRecoveryTurns
        )
    }

    /// The same fold from a target and a cause already decided (a Debug-only forced reading).
    static func advance(
        _ current: CoolHeadState, target: CoolHeadLevel, cause: CoolHeadCause?, minRecoveryTurns: Int
    ) -> CoolHeadStep {
        let state = next(current, target: target, minRecoveryTurns: minRecoveryTurns)
        return CoolHeadStep(state: state, announcement: announcement(from: current, to: state, cause: cause))
    }
}

/// M1K3's lines for an eased turn: a fixed set per cause, never generated.
public enum CoolHeadVoice {
    /// The set for a cause. `deviceNoun` is `HostPlatform.noun` ("machine" on a Mac), passed in
    /// because this module can't import M1K3Inference.
    public static func exemplars(for cause: CoolHeadCause, deviceNoun noun: String) -> [String] {
        switch cause {
        case .heat:
            [
                "This \(noun)'s running warm, so I'm going easy on the heavy lifting.",
                "Running hot in here, so I'll do less legwork on this one.",
                "The \(noun)'s warm, so I'm easing off the extra steps for now.",
            ]
        case .lowPower:
            [
                "Low Power Mode's on, so I'm going easy on the heavy lifting.",
                "Low Power Mode is on, so I'll do less legwork on this one.",
                "With Low Power Mode on, I'm easing off the extra steps for now.",
            ]
        case .unknownPressure:
            [
                "The system's asking me to go easy, so I'll do less legwork on this one.",
                "This \(noun)'s asking for a breather, so I'm easing off the extra steps.",
            ]
        }
    }

    /// One line, chosen by `pick` modulo the set: the app passes a running count, so successive
    /// episodes rotate, and the same pick always gives the same line.
    public static func line(for cause: CoolHeadCause, pick: Int, deviceNoun: String) -> String {
        let set = exemplars(for: cause, deviceNoun: deviceNoun)
        let count = set.count
        return set[((pick % count) + count) % count]
    }
}

/// One send's line waiting for that send's turn. The app posts on every send (so a send that
/// eased nothing clears a line an earlier turn never read) and the chat responder takes it once.
public struct CoolHeadNoteSlot: Sendable, Equatable {
    public private(set) var pending: String?
    /// Lines posted so far: the next announcement's pick, so episodes rotate through the set.
    public private(set) var posted = 0

    public init() {}

    public mutating func post(_ cause: CoolHeadCause?, deviceNoun: String) {
        guard let cause else {
            pending = nil
            return
        }
        pending = CoolHeadVoice.line(for: cause, pick: posted, deviceNoun: deviceNoun)
        posted += 1
    }

    public mutating func take() -> String? {
        defer { pending = nil }
        return pending
    }
}
