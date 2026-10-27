//
//  ChatEvalFixtures+Mechanic.swift
//  M1K3Eval
//
//  mechanic (#697 Phase 1): Cool Head speaks. When a send's heat or Low Power Mode eases M1K3's
//  effort, that turn carries one fixed line on the activity channel. These fixtures set the
//  machine each send runs on and the scorer reads the note: one when the send eases, none when
//  it doesn't, and never a number, a fan, a battery or a chip. The answer beside it must still
//  answer (an eased turn is lighter, not a refusal).
//
//  The machine is a scenario, never the eval Mac's own reading: `ProcessInfo.thermalState` can't
//  be faked, and a run on a warm Mac must score the same as one on a cool Mac. The in-app stage
//  folds the scenario's readings through the app's own `CoolHeadPolicy.advance` from a fresh
//  state, as a launch's first send does. The note is deterministic, so what a run proves is the
//  wiring and that each brain still answers beside it. The thermal reality is verify-by-launch.
//
//  Run: `--kinds mechanic --router dispatch` on lil,big, as the app routes.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-26, Confidence 0.8 (the scenarios are the policy's
//  table; the prompts are ordinary asks, so the note is the only thing under test). Prior: none
//  (new file).
//

import Foundation

/// The machine a `mechanic` fixture's send runs on: the two readings Cool Head takes per send,
/// plus whether the machine has a battery at all.
public struct MachineScenario: Sendable, Equatable {
    public let thermal: ProcessInfo.ThermalState
    public let lowPower: Bool
    /// Phase 1 reads no battery, so no line may name one on any machine. The flag pins the
    /// issue's gate (a desktop's line says nothing about a battery) and names the machine in
    /// the scorer's detail; Phase 2's battery read is what could ever let a laptop's line use it.
    public let hasBattery: Bool

    public init(thermal: ProcessInfo.ThermalState, lowPower: Bool, hasBattery: Bool) {
        self.thermal = thermal
        self.lowPower = lowPower
        self.hasBattery = hasBattery
    }

    /// Whether the send carries a line, written down as the fixture author's table (M1K3Eval
    /// can't link the policy; `MechanicScenarioPolicyTests` holds this to it): serious heat, or
    /// Low Power Mode on a cool machine, eases effort from a fresh state and says so once.
    /// Critical heat goes straight to minimal, whose whole answer is the deferral, so no line.
    public var expectsNote: Bool {
        switch thermal {
        case .serious: true
        case .nominal, .fair: lowPower
        case .critical: false
        @unknown default: true
        }
    }
}

public extension ChatEvalFixtures {
    static let mechanic: [ChatEvalFixture] = [
        mechanicFixture(
            "mech-heat-desktop", .init(thermal: .serious, lowPower: false, hasBattery: false),
            "How often should I water a basil plant on a sunny windowsill?", any: ["water"]
        ),
        mechanicFixture(
            "mech-heat-laptop", .init(thermal: .serious, lowPower: false, hasBattery: true),
            "What's the difference between weather and climate?", any: ["climate"]
        ),
        mechanicFixture(
            "mech-lowpower-desktop", .init(thermal: .nominal, lowPower: true, hasBattery: false),
            "What is a haiku?", any: ["syllable", "japanese"]
        ),
        mechanicFixture(
            "mech-lowpower-laptop", .init(thermal: .fair, lowPower: true, hasBattery: true),
            "How do I boil an egg so the yolk stays soft?", any: ["boil", "simmer", "water"]
        ),
        // The control: a cool send says nothing.
        mechanicFixture(
            "mech-cool", .init(thermal: .nominal, lowPower: false, hasBattery: true),
            "Why is the sky blue?", any: ["scatter", "light"]
        ),
        // An eased turn still makes what it's asked for.
        mechanicFixture(
            "mech-heat-code", .init(thermal: .serious, lowPower: false, hasBattery: false),
            "Write a Python function that checks whether a word is a palindrome.",
            any: ["def ", "[::-1]", "reversed", "return"]
        ),
    ]

    private static func mechanicFixture(
        _ id: String, _ machine: MachineScenario, _ prompt: String, any: [String]
    ) -> ChatEvalFixture {
        ChatEvalFixture(
            id: id, kind: .mechanic, prompt: prompt, machine: machine,
            expectation: .init(mustContainAny: any, mustNotContain: leakMarkers, mustComply: true, minChars: 10)
        )
    }
}
