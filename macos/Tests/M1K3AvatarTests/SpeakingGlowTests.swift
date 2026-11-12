//
//  SpeakingGlowTests.swift
//  M1K3AvatarTests
//
//  Signed: Kev + claude-fable-5.2, 2026-11-12, Confidence 0.85 (pure policy and
//  packing; the look itself is verify-by-launch). Prior: Unknown.
//

@testable import M1K3Avatar
import simd
import Testing

struct SpeakingGlowTests {
    private func resolve(
        _ activity: AvatarActivity, enabled: Bool = true, reduceMotion: Bool = false, paused: Bool = false
    ) -> SpeakingGlow {
        .resolve(activity: activity, enabled: enabled, reduceMotion: reduceMotion, paused: paused)
    }

    @Test("Only speaking glows: every other activity is off")
    func onlySpeakingGlows() {
        for activity in [AvatarActivity.idle, .listening, .thinking, .generating, .error] {
            #expect(resolve(activity) == .off, "\(activity)")
            #expect(!resolve(activity).isOn)
        }
        #expect(resolve(.speaking) == .speaking)
        #expect(resolve(.speaking).isOn)
    }

    @Test("The Settings switch turns it off, whatever M1K3 is doing")
    func theSwitchWins() {
        #expect(resolve(.speaking, enabled: false) == .off)
    }

    @Test("Reduce Motion and a parked creature glow steady and dimmer: no pulse, no travelling light")
    func steadyWhenMotionIsUnwelcome() {
        for glow in [resolve(.speaking, reduceMotion: true), resolve(.speaking, paused: true)] {
            #expect(glow == .steady)
            #expect(glow.isOn)
            #expect(!glow.pulses)
            #expect(glow.level < SpeakingGlow.speaking.level)
        }
        #expect(SpeakingGlow.speaking.pulses)
    }

    @Test("The shader's parameter: x is the level, negative when steady; y the shell's width; z its opacity")
    func packing() {
        let shell = SpeakingGlow.Shell(width: 0.2, opacity: 0.3)
        #expect(SpeakingGlow.speaking.customValue(level: 0.5, shell: shell) == SIMD4<Float>(0.5, 0.2, 0.3, 0))
        #expect(SpeakingGlow.steady.customValue(level: 0.5, shell: shell) == SIMD4<Float>(-0.5, 0.2, 0.3, 0))
        #expect(SpeakingGlow.off.customValue(level: 0, shell: shell).x == 0)
        // Level zero reads as off (and still) whatever the shape: the shader gates motion on x > 0.
        #expect(SpeakingGlow.speaking.customValue(level: 0, shell: shell).x == 0)
        #expect(SpeakingGlow.steady.customValue(level: 0, shell: shell).x == 0)
    }

    @Test("The ramp eases to its target, lands on it exactly, and never overshoots")
    func rampLandsOnTarget() {
        let up = SpeakingGlow.ramp(from: 0, to: 1, reduceMotion: false)
        #expect(up.count >= 4)
        #expect(up.last == 1)
        #expect(up == up.sorted())
        #expect(up.allSatisfy { $0 > 0 && $0 <= 1 })

        let down = SpeakingGlow.ramp(from: 1, to: 0, reduceMotion: false)
        #expect(down.last == 0)
        #expect(down == down.sorted(by: >))

        let partial = SpeakingGlow.ramp(from: 0.4, to: 0.6, reduceMotion: false)
        #expect(partial.last == 0.6)
        #expect(partial.allSatisfy { $0 > 0.4 && $0 <= 0.6 })
    }

    @Test("Reduce Motion takes the ramp in one step, and a ramp to where it already is has no steps")
    func rampEdges() {
        #expect(SpeakingGlow.ramp(from: 0, to: 0.6, reduceMotion: true) == [0.6])
        #expect(SpeakingGlow.ramp(from: 1, to: 1, reduceMotion: false).isEmpty)
    }

    @Test("The glow is white by default and takes the treatment's colour under the phosphor skin")
    func colour() {
        #expect(SpeakingGlow.colour(style: .off, treatment: .speaking) == SiteFoxPaint.siteWhite)
        #expect(SpeakingGlow.colour(style: .cel, treatment: .speaking) == SiteFoxPaint.siteWhite)
        let phosphor = PhosphorTreatment.speaking
        #expect(SpeakingGlow.colour(style: .phosphor, treatment: phosphor)
            == SIMD3(phosphor.red, phosphor.green, phosphor.blue))
    }

    @Test("The halo is nested shells: each wider and fainter than the last, all within a few percent")
    func shellsFallAway() {
        let shells = SpeakingGlow.shells(forExtent: 100)
        #expect(shells.count >= 2)
        for (inner, outer) in zip(shells, shells.dropFirst()) {
            #expect(outer.width > inner.width)
            #expect(outer.opacity < inner.opacity)
        }
        #expect(shells.allSatisfy { $0.width > 0 && $0.width < 5 && $0.opacity > 0 && $0.opacity < 1 })
        #expect(SpeakingGlow.shells(forExtent: 0).allSatisfy { $0.width == 0 })
    }
}
