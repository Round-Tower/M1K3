//
//  ScreengrabPlate.swift
//  M1K3Screengrab
//
//  The twelve App Store plates (marketing/app-store/CAPTURE-PLAN.md §1/§2), one
//  case per plate FILE. Each knows its launch recipe: the harness env plus the
//  `-key value` launch arguments that shadow persisted defaults through
//  NSArgumentDomain — read-only, so a capture run never rewrites the face,
//  brain or first-run state of the person whose Mac/phone it runs on.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-07, Confidence 0.85 (recipe pinned by
//  test; the argument-domain shadowing is Foundation's documented search order,
//  verified by launch on the Mac suite), Prior: Unknown
//  Review: claude-fable-5.1, 2026-09-08 — `-selectedBrain lil` on every recipe (Lil fronts the plates;
//  Mini answered flat) and the Fox tile shows the registered PhosphorFox creature, not Fox + phosphor skin (Kev). Confidence now 0.85.
//

import Foundation

public enum ScreengrabPlate: String, CaseIterable, Sendable {
    case onboarding
    case chat
    case voiceListening = "voice-listening"
    case voiceSpeaking = "voice-speaking"
    case documents
    case memories
    case brainAtHome = "brain-at-home"
    case companionFox = "companion-fox"
    case companionGecko = "companion-gecko"
    case companionInkfish = "companion-inkfish"
    case companionColobus = "companion-colobus"
    case privacyLabel = "privacy-label"

    /// The face every non-tile plate wears, so chat/voice/memories match each
    /// other across a run. The Phosphor Fox is the house default on iOS and a
    /// registered choice on the Mac.
    public static let houseFace = "PhosphorFox"

    /// The vendored creature a companion tile shows; nil for every other plate.
    public var companionID: String? {
        switch self {
        case .companionFox: "PhosphorFox"
        case .companionGecko: "Gecko"
        case .companionInkfish: "Inkfish"
        case .companionColobus: "Colobus"
        default: nil
        }
    }

    /// What the test runner passes to `XCUIApplication` for this plate.
    public struct LaunchRecipe: Sendable, Equatable {
        public var environment: [String: String]
        /// Flattened `-key value` pairs; `arguments.contains([k, v])` reads
        /// naturally in tests and the runner just concatenates.
        public var arguments: [[String]]

        public var flatArguments: [String] {
            arguments.flatMap { $0 }
        }
    }

    public var launchRecipe: LaunchRecipe {
        var arguments: [[String]] = [
            ["-hasChosenBrain", self == .onboarding ? "NO" : "YES"],
            // Lil fronts every plate (Kev, 2026-09-08): the speaking plate is a REAL
            // turn and Lil carries the persona; Mini answered flat. Weights come from
            // the live model store (the harness reroutes data, not brains).
            ["-selectedBrain", "lil"],
            ["-voiceMode.companion", companionID ?? Self.houseFace],
            // Creature tiles read best with the phosphor skin (the site's look).
            // That includes the PhosphorFox tile: captured with `.off` on
            // 2026-09-09 it rendered as a plain grey wireframe — the glow is the
            // shader, not the asset, whatever CompanionSpec's comment says.
            ["-companion.shadingStyle", "phosphor"],
            // Brain at Home serving reads the paired-device keys from the Keychain;
            // off for every plate (the pairing plate shows the QR from Settings).
            ["-brainServe.enabled", "NO"],
            // The notch HUD is a floating panel over the window: it captioned the
            // spoken line into two voice plates.
            ["-notchHUD.enabled", "NO"],
            // Off: beside a live app it fails on :4242 and the Privacy pane prints the error.
            ["-mcpServer.enabled", "NO"],
            // No auto-distillation of the seeded conversation: the Memories plate
            // shows the persona's dated facts, not "I noticed" rows stamped today.
            ["-memoryAutoCapture", "NO"],
            // AppKit: never restore the saved window state — a killed run can leave
            // one with no visible window, and every later launch inherits it.
            ["-ApplePersistenceIgnoreState", "YES"],
        ]
        if self == .onboarding {
            // A fresh Mac lands on HelloView, never the brain-only repick.
            arguments.append(["-onboarding.startAtBrain", "NO"])
        }
        return LaunchRecipe(
            environment: [
                ScreengrabHarness.activeKey: "1",
                ScreengrabHarness.plateKey: rawValue,
            ],
            arguments: arguments
        )
    }
}
