//
//  ScreengrabHarnessTests.swift
//  M1K3ScreengrabTests
//
//  Pins the harness contract the UI test suites and both shells depend on:
//  the env keys, the isolated data root (Kev's live memories must never be in
//  a frame), and the per-plate launch recipe (which launch ARGUMENTS override
//  which defaults — NSArgumentDomain, read-only, nothing persisted).
//
//  Signed: Kev + claude-fable-5.1, 2026-09-07, Confidence 0.9 (pure), Prior: Unknown
//  Review: claude-fable-5.1, 2026-09-08 — pins moved to Lil + PhosphorFox with the recipe. Confidence now 0.9.
//  Review: Kev + claude-fable-5.1, 2026-09-09 — `hidesViewfinder` pinned for the pairing plate. Confidence now 0.9.
//

import Foundation
@testable import M1K3Screengrab
import Testing

struct ScreengrabHarnessTests {
    @Test func inactiveWithoutTheFlag() {
        let h = ScreengrabHarness(environment: [:])
        #expect(!h.isActive)
        #expect(h.plate == nil)
        let live = URL(fileURLWithPath: "/c/Library/Application Support/M1K3", isDirectory: true)
        #expect(h.dataRoot(live: live) == live)
    }

    @Test func activeRootIsASiblingOfTheLiveRoot() {
        let h = ScreengrabHarness(environment: ["M1K3_SCREENGRAB": "1"])
        #expect(h.isActive)
        let live = URL(fileURLWithPath: "/c/Library/Application Support/M1K3", isDirectory: true)
        let root = h.dataRoot(live: live)
        #expect(root.lastPathComponent == "M1K3-screengrab")
        #expect(root.deletingLastPathComponent().path == live.deletingLastPathComponent().path)
        #expect(root.path != live.path)
    }

    @Test func plateParsesFromTheEnvironment() {
        let h = ScreengrabHarness(environment: ["M1K3_SCREENGRAB": "1", "M1K3_SCREENGRAB_PLATE": "voice-speaking"])
        #expect(h.plate == .voiceSpeaking)
        let unknown = ScreengrabHarness(environment: ["M1K3_SCREENGRAB": "1", "M1K3_SCREENGRAB_PLATE": "nope"])
        #expect(unknown.plate == nil)
        #expect(unknown.isActive)
    }

    @Test func plateFlagsFollowTheCapturePlan() {
        func h(_ p: ScreengrabPlate) -> ScreengrabHarness {
            ScreengrabHarness(environment: ["M1K3_SCREENGRAB": "1", "M1K3_SCREENGRAB_PLATE": p.rawValue])
        }
        #expect(h(.voiceListening).entersVoiceMode)
        #expect(h(.voiceSpeaking).entersVoiceMode)
        #expect(!h(.chat).entersVoiceMode)
        #expect(h(.companionGecko).entersVoiceMode, "tiles are shot on the voice-mode avatar surface")
        #expect(h(.voiceSpeaking).submitsHeroQuestion)
        #expect(!h(.voiceListening).submitsHeroQuestion)
        #expect(h(.brainAtHome).showsPairing)
        #expect(!h(.memories).showsPairing)
        #expect(h(.brainAtHome).hidesViewfinder, "the pairing plate never asks the phone's camera")
        #expect(!h(.memories).hidesViewfinder)
        #expect(h(.onboarding).showsOnboarding)
        #expect(h(.documents).showsDocuments && !h(.documents).showsMemories)
        #expect(h(.memories).showsMemories)
        #expect(h(.brainAtHome).opensSettings && h(.brainAtHome).showsPrivacyPane, "pairing lives in Settings ▸ Privacy")
        #expect(h(.privacyLabel).opensSettings && h(.privacyLabel).showsPrivacyPane)
        #expect(!h(.chat).opensSettings)
        #expect(!h(.chat).showsOnboarding)
        #expect(h(.voiceListening).livePartial == DemoPersona.listeningDictation)
        #expect(!DemoPersona.listeningDictation.lowercased().contains("please"), "a polite endpoint submits the turn")
        #expect(h(.voiceSpeaking).livePartial == DemoPersona.heroConversation[0].text)
        #expect(h(.companionFox).livePartial == nil)
    }

    @Test func launchRecipeOverridesDefaultsThroughTheArgumentDomain() {
        // The recipe the UI tests pass verbatim: env for the harness, `-key value`
        // pairs for NSArgumentDomain (shadows persisted defaults, never writes).
        let recipe = ScreengrabPlate.companionFox.launchRecipe
        #expect(recipe.environment["M1K3_SCREENGRAB"] == "1")
        #expect(recipe.environment["M1K3_SCREENGRAB_PLATE"] == "companion-fox")
        #expect(recipe.arguments.contains(["-voiceMode.companion", "PhosphorFox"]))
        // Lil fronts every plate: the speaking plate is a real turn and Lil carries
        // the persona (Kev, 2026-09-08).
        #expect(recipe.arguments.contains(["-selectedBrain", "lil"]))
        // Every tile, the PhosphorFox included, wears the phosphor shader (`.off` = grey wireframe, captured).
        #expect(recipe.arguments.contains(["-companion.shadingStyle", "phosphor"]))
        #expect(recipe.arguments.contains(["-hasChosenBrain", "YES"]))
        #expect(recipe.arguments.contains(["-brainServe.enabled", "NO"]))
        #expect(recipe.arguments.contains(["-notchHUD.enabled", "NO"]))
        #expect(recipe.arguments.contains(["-mcpServer.enabled", "NO"]))
        #expect(recipe.arguments.contains(["-memoryAutoCapture", "NO"]))
        #expect(recipe.arguments.contains(["-ApplePersistenceIgnoreState", "YES"]))

        let onboarding = ScreengrabPlate.onboarding.launchRecipe
        #expect(onboarding.arguments.contains(["-hasChosenBrain", "NO"]))

        // Every plate pins the SAME face unless it is a companion tile, so the
        // chat/voice plates match each other across a capture run.
        let chat = ScreengrabPlate.chat.launchRecipe
        #expect(chat.arguments.contains(["-voiceMode.companion", ScreengrabPlate.houseFace]))
    }

    @Test func companionTilesNameTheVendoredCreatures() {
        #expect(ScreengrabPlate.companionFox.companionID == "PhosphorFox")
        #expect(ScreengrabPlate.companionGecko.companionID == "Gecko")
        #expect(ScreengrabPlate.companionInkfish.companionID == "Inkfish")
        #expect(ScreengrabPlate.companionColobus.companionID == "Colobus")
        #expect(ScreengrabPlate.chat.companionID == nil)
    }

    @Test func everyPlateInTheCapturePlanHasARawValueMatchingItsFilename() {
        // CAPTURE-PLAN.md §1 / §2 — the twelve plate files per target.
        let plan = [
            "onboarding", "chat", "voice-listening", "voice-speaking", "documents", "memories",
            "brain-at-home", "companion-fox", "companion-gecko", "companion-inkfish",
            "companion-colobus", "privacy-label",
        ]
        #expect(ScreengrabPlate.allCases.map(\.rawValue) == plan)
    }
}
