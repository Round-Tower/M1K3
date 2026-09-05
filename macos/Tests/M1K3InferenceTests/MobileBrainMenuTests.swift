//
//  MobileBrainMenuTests.swift
//  M1K3InferenceTests
//
//  The mobile onboarding/Settings brain list, pinned per device shape: an old
//  iPad with no Apple Intelligence and 3 GB must not be shown Mini or Lil, and
//  Brain at Home must be listed as the way in (QA pass, 2026-09-05, items 1+2).
//
//  Signed: Kev + claude-fable-5.1, 2026-09-05, Confidence 0.9. Prior: none (new file).
//

@testable import M1K3Inference
import Testing

struct MobileBrainMenuTests {
    @Test("a 3 GB iPad without Apple Intelligence lists only Brain at Home, and recommends it")
    func oldIPadIsHomeOnly() {
        let menu = MobileBrainMenu.resolve(afm: .blocked(userFixable: false), physicalMemoryGB: 2.9)
        #expect(menu.options == [.brainAtHome])
        #expect(menu.recommended == .brainAtHome)
        #expect(menu.localFallback == nil)
        #expect(menu.note != nil)
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

    @Test("Apple Intelligence switched OFF still lists Mini — the user can fix it")
    func userFixableKeepsMini() {
        let menu = MobileBrainMenu.resolve(afm: .blocked(userFixable: true), physicalMemoryGB: 11.7)
        #expect(menu.options.contains(.tier(.mini)))
    }

    @Test("ineligible hardware with 12 GB hides Mini, recommends Lil, and Lil is the local fallback")
    func ineligibleButRoomy() {
        let menu = MobileBrainMenu.resolve(afm: .blocked(userFixable: false), physicalMemoryGB: 11.7)
        #expect(menu.options == [.tier(.lil), .brainAtHome])
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
        #expect(!MobileBrainMenu.resolve(afm: .blocked(userFixable: false), physicalMemoryGB: 2.9).hasLocalBrain)
        #expect(MobileBrainMenu.resolve(afm: .blocked(userFixable: false), physicalMemoryGB: 11.7).hasLocalBrain)
        #expect(MobileBrainMenu.resolve(afm: .blocked(userFixable: true), physicalMemoryGB: 2.9).hasLocalBrain)
        #expect(MobileBrainMenu.resolve(afm: .available, physicalMemoryGB: 2.9).hasLocalBrain)
    }

    @Test("Brain at Home is always the last option")
    func homeIsLast() {
        for gb in [2.9, 11.7, 16] {
            #expect(MobileBrainMenu.resolve(afm: .available, physicalMemoryGB: gb).options.last == .brainAtHome)
        }
    }
}
