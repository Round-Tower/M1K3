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
        // the persona (Kev, 2026-09-08). The pure arm takes any brain — the runner's
        // M1K3_SCREENGRAB_BRAIN picks `mini` for a simulator, which has no MLX.
        #expect(recipe.arguments.contains(["-selectedBrain", "lil"]))
        #expect(ScreengrabPlate.chat.launchRecipe(brain: "mini").arguments.contains(["-selectedBrain", "mini"]))
        #expect(!ScreengrabPlate.chat.launchRecipe(brain: "mini").arguments.contains(["-selectedBrain", "lil"]))
        // The PhosphorFox tile shows its BAKED white lattice (Kev, 2026-09-12 / 09-15) — shader off.
        #expect(recipe.arguments.contains(["-companion.shadingStyle", "off"]))
        // The other creatures show their own baked colour too (Kev, 2026-09-15: "more colour
        // in the screenshots") — no phosphor skin on any tile.
        for plate in [ScreengrabPlate.companionGecko, .companionInkfish, .companionColobus] {
            #expect(plate.launchRecipe.arguments.contains(["-companion.shadingStyle", "off"]))
        }
        // The voice plates ride the house face → the lattice look too.
        #expect(ScreengrabPlate.voiceSpeaking.launchRecipe.arguments.contains(["-companion.shadingStyle", "off"]))
        // The constellation plate is the memories recipe under another name.
        #expect(ScreengrabPlate.constellation.companionID == nil)
        #expect(ScreengrabPlate.constellation.launchRecipe.environment["M1K3_SCREENGRAB_PLATE"] == "constellation")
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
        // CAPTURE-PLAN.md §1 / §2 — the twelve plate files per target, plus the
        // Mac lane's constellation (2026-09-15).
        let plan = [
            "onboarding", "chat", "voice-listening", "voice-speaking", "documents", "memories",
            "brain-at-home", "companion-fox", "companion-gecko", "companion-inkfish",
            "companion-colobus", "privacy-label", "constellation",
        ]
        #expect(ScreengrabPlate.allCases.map(\.rawValue) == plan)
    }
}

/// A capture run starts from a fresh sibling root (2026-09-23): a shell can no
/// longer clear the app's container, so the stale seed marker from an old run
/// kept the #383 backstory out and the constellation plate showed five motes.
/// The app clears its OWN root, once per run token.
struct ScreengrabFreshRootTests {
    private func sandbox() throws -> (live: URL, sibling: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("screengrab-fresh-\(UUID().uuidString)", isDirectory: true)
        let live = base.appendingPathComponent("M1K3", isDirectory: true)
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: live.appendingPathComponent("knowledge.sqlite"))
        let sibling = base.appendingPathComponent(ScreengrabHarness.dataRootName, isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: sibling.appendingPathComponent("seed.marker"))
        return (live, sibling)
    }

    private func harness(run: String?) -> ScreengrabHarness {
        var environment = [ScreengrabHarness.activeKey: "1", ScreengrabHarness.plateKey: "chat"]
        environment[ScreengrabHarness.runKey] = run
        return ScreengrabHarness(environment: environment)
    }

    @Test("a new run token clears the sibling root and stamps it")
    func newRunClears() throws {
        let (live, sibling) = try sandbox()
        let cleared = try harness(run: "run-1").prepareRoot(live: live)
        #expect(cleared)
        #expect(!FileManager.default.fileExists(atPath: sibling.appendingPathComponent("seed.marker").path))
        let stamp = try String(contentsOf: sibling.appendingPathComponent(ScreengrabHarness.runStampName), encoding: .utf8)
        #expect(stamp == "run-1")
    }

    @Test("the same run token keeps the root: later plates reuse the seed")
    func sameRunKeeps() throws {
        let (live, sibling) = try sandbox()
        _ = try harness(run: "run-1").prepareRoot(live: live)
        try Data("seeded".utf8).write(to: sibling.appendingPathComponent("seed.marker"))
        let cleared = try harness(run: "run-1").prepareRoot(live: live)
        #expect(!cleared)
        #expect(FileManager.default.fileExists(atPath: sibling.appendingPathComponent("seed.marker").path))
    }

    @Test("no run token, or an inactive harness, touches nothing — and the live root never")
    func noTokenNoop() throws {
        let (live, sibling) = try sandbox()
        #expect(try harness(run: nil).prepareRoot(live: live) == false)
        #expect(try harness(run: "").prepareRoot(live: live) == false)
        let inactive = ScreengrabHarness(environment: [ScreengrabHarness.runKey: "run-9"])
        #expect(try inactive.prepareRoot(live: live) == false)
        #expect(FileManager.default.fileExists(atPath: sibling.appendingPathComponent("seed.marker").path))
        #expect(FileManager.default.fileExists(atPath: live.appendingPathComponent("knowledge.sqlite").path))
    }
}
