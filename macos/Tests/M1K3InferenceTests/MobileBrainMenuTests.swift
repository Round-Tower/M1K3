//
//  MobileBrainMenuTests.swift
//  M1K3InferenceTests
//
//  The mobile onboarding/Settings brain list, pinned per device shape: an old
//  iPad with no Apple Intelligence and 3 GB must not be shown Mini or Lil, and
//  Brain at Home must be listed as the way in (QA pass, 2026-09-05, items 1+2).
//
//  Signed: Kev + claude-fable-5.1, 2026-09-05, Confidence 0.9. Prior: none (new file).
//  Review: Kev + claude-fable-5.1, 2026-09-06 — pocket rows: a 4 GB blocked device gets pocket + Home (pocket
//  recommended, localFallback pocket); the 3 GB A12 stays Home-only; a roomy blocked device recommends Lil over
//  pocket; userFixable shows pocket, never the AFM Mini. Confidence 0.9.
//

@testable import M1K3Inference
import Testing

struct MobileBrainMenuTests {
    @Test("a 4 GB device without Apple Intelligence gets pocket (shown as Mini) + Home — pocket recommended")
    func oldIPadGetsPocket() {
        // A 4 GB A13-class device without Apple Intelligence: pocket is its Mini.
        let menu = MobileBrainMenu.resolve(afm: .blocked(userFixable: false), physicalMemoryGB: 3.8)
        #expect(menu.options == [.tier(.pocket), .brainAtHome])
        #expect(menu.recommended == .tier(.pocket))
        #expect(menu.localFallback == .pocket)
        #expect(menu.note == nil)
        #expect(menu.hasLocalBrain)
    }

    @Test("the 3 GB A12 iPad stays Home-only — pocket's floor is the measured Metal-compiler failure")
    func a12IPadStaysHomeOnly() {
        let menu = MobileBrainMenu.resolve(afm: .blocked(userFixable: false), physicalMemoryGB: 2.9)
        #expect(menu.options == [.brainAtHome])
        #expect(menu.recommended == .brainAtHome)
        #expect(menu.localFallback == nil)
        #expect(!menu.hasLocalBrain)
    }

    @Test("an iPhone 17 Pro (12 GB, AFM available) lists Mini, Lil, Home — Mini recommended")
    func modernPhone() {
        let menu = MobileBrainMenu.resolve(afm: .available, physicalMemoryGB: 11.7)
        #expect(menu.options == [.tier(.mini), .tier(.lil), .brainAtHome])
        #expect(menu.recommended == .tier(.mini))
        #expect(menu.note == nil)
    }

    @Test("a 16 GB iPad Pro recommends Lil (the mobile ladder)")
    func bigIPad() {
        let menu = MobileBrainMenu.resolve(afm: .available, physicalMemoryGB: 16)
        #expect(menu.recommended == .tier(.lil))
    }

    @Test("Apple Intelligence switched OFF lists pocket in Mini's place — the brain that works today; Settings copy still points at the fix")
    func userFixableShowsPocket() {
        let menu = MobileBrainMenu.resolve(afm: .blocked(userFixable: true), physicalMemoryGB: 11.7)
        #expect(menu.options.contains(.tier(.pocket)))
        #expect(!menu.options.contains(.tier(.mini)))
    }

    @Test("ineligible hardware with 12 GB lists pocket + Lil, recommends Lil, and Lil is the local fallback")
    func ineligibleButRoomy() {
        let menu = MobileBrainMenu.resolve(afm: .blocked(userFixable: false), physicalMemoryGB: 11.7)
        #expect(menu.options == [.tier(.pocket), .tier(.lil), .brainAtHome])
        #expect(menu.recommended == .tier(.lil))
        #expect(menu.localFallback == .lil)
    }

    @Test("Mini warming (notReady) is transient — Mini stays listed and recommended")
    func notReadyKeepsMini() {
        let menu = MobileBrainMenu.resolve(afm: .notReady, physicalMemoryGB: 11.7)
        #expect(menu.recommended == .tier(.mini))
    }

    @Test("Big is never listed on mobile")
    func neverBig() {
        let menu = MobileBrainMenu.resolve(afm: .available, physicalMemoryGB: 64)
        #expect(!menu.options.contains(.tier(.big)))
    }

    @Test("hasLocalBrain is false only when Home is the sole row — the auto-activate trigger")
    func hasLocalBrain() {
        // Home-only = blocked AFM below pocket's 4 GB floor (the A12 class).
        #expect(!MobileBrainMenu.resolve(afm: .blocked(userFixable: false), physicalMemoryGB: 2.9).hasLocalBrain)
        #expect(MobileBrainMenu.resolve(afm: .blocked(userFixable: false), physicalMemoryGB: 3.8).hasLocalBrain)
        #expect(MobileBrainMenu.resolve(afm: .blocked(userFixable: false), physicalMemoryGB: 11.7).hasLocalBrain)
        #expect(!MobileBrainMenu.resolve(afm: .blocked(userFixable: true), physicalMemoryGB: 2.9).hasLocalBrain)
        #expect(MobileBrainMenu.resolve(afm: .available, physicalMemoryGB: 2.9).hasLocalBrain)
    }

    @Test("Brain at Home is always the last option")
    func homeIsLast() {
        for gb in [2.9, 11.7, 16] {
            #expect(MobileBrainMenu.resolve(afm: .available, physicalMemoryGB: gb).options.last == .brainAtHome)
        }
    }

    @Test("an active pocket stays listed while Apple Intelligence syncs (notReady) — Settings never loses the answering brain")
    func activePocketSurvivesNotReady() {
        let menu = MobileBrainMenu.resolve(afm: .notReady, physicalMemoryGB: 3.8, active: .pocket)
        #expect(menu.options == [.tier(.mini), .tier(.pocket), .brainAtHome])
        // Without the active hint the plain offered set applies.
        #expect(MobileBrainMenu.resolve(afm: .notReady, physicalMemoryGB: 3.8).options == [.tier(.mini), .brainAtHome])
    }
}
