//
//  CompanionChoreographerTests.swift
//  M1K3AvatarTests
//
//  Signed: Kev + claude-opus-5-5, 2026-10-01, Confidence 0.8, Prior: none (new file)
//

import M1K3Avatar
import Testing

/// The pure choreography layer: AvatarState + time + presence in, clip commands
/// out. RealityKit playback is verify-by-launch; every decision is pinned here.
struct CompanionChoreographerTests {
    /// A fixed-value RNG so fidget intervals are exact: 0 → 12 s, 1 → 25 s.
    private func make(
        _ dialect: CompanionDialect = .quaternius, random: Double = 0
    ) -> CompanionChoreographer {
        CompanionChoreographer(dialect: dialect, nextUnit: { random })
    }

    private func state(_ activity: AvatarActivity, _ emotion: AvatarEmotion = .neutral) -> AvatarState {
        AvatarState(emotion: emotion, activity: activity)
    }

    private func fade(_ gait: CompanionGait) -> Double {
        ClipMapper.crossfadeDuration(to: gait)
    }

    // MARK: - Reply streaming plays the move clip (the bug)

    @Test("generating plays the MOVE loop, not the react loop, with a one-shot beat first")
    func generatingBeatThenMove() {
        var c = make()
        _ = c.stateChanged(state(.thinking, .thinking), at: 0)
        let cmd = c.stateChanged(state(.generating, .excited), at: 1)
        #expect(cmd == .oneShot(clip: "Jump", thenLoop: "Walk", crossfade: fade(.react)))
    }

    @Test("after the beat finishes, the loop continues on the move clip")
    func beatFinishesIntoMove() {
        var c = make()
        _ = c.stateChanged(state(.thinking, .thinking), at: 0)
        _ = c.stateChanged(state(.generating, .excited), at: 1)
        #expect(c.oneShotFinished(at: 2) == .loop(clip: "Walk", crossfade: fade(.move)))
    }

    @Test("generating → speaking keeps walking: no restart, no second beat")
    func generatingToSpeakingIsQuiet() {
        var c = make()
        _ = c.stateChanged(state(.generating, .excited), at: 0)
        _ = c.oneShotFinished(at: 1)
        #expect(c.stateChanged(state(.speaking, .happy), at: 2) == nil)
    }

    @Test("a state change that keeps the same loop while a beat plays does not interrupt it")
    func beatSurvivesSameLoopChange() {
        var c = make()
        _ = c.stateChanged(state(.generating, .excited), at: 0) // beat
        #expect(c.stateChanged(state(.speaking, .happy), at: 0.3) == nil)
    }

    @Test("a state change to a different loop interrupts the beat")
    func beatInterruptedByDifferentLoop() {
        var c = make()
        _ = c.stateChanged(state(.generating, .excited), at: 0)
        #expect(c.stateChanged(.idle, at: 0.3) == .loop(clip: "Idle_A", crossfade: fade(.rest)))
    }

    @Test("react beat then move loop, per dialect")
    func beatAndMovePerDialect() {
        let expected: [(CompanionDialect, String, String)] = [
            (.quaternius, "Jump", "Walk"), (.fox, "Run", "Walk"),
            (.aquatic, "Fly", "Swim"), (.avian, "Jump", "Fly"),
        ]
        for (dialect, beat, move) in expected {
            var c = make(dialect)
            #expect(
                c.stateChanged(state(.generating, .excited), at: 0)
                    == .oneShot(clip: beat, thenLoop: move, crossfade: fade(.react)),
                "\(dialect)"
            )
        }
    }

    // MARK: - Explicit emotions → clips

    @Test("sad and angry loop the distress clip; fox falls back to Run")
    func distressEmotions() {
        for emotion in [AvatarEmotion.sad, .angry] {
            var c = make()
            #expect(c.stateChanged(state(.idle, emotion), at: 0) == .loop(clip: "Fear", crossfade: fade(.distress)))
            var fox = make(.fox)
            #expect(fox.stateChanged(state(.idle, emotion), at: 0) == .loop(clip: "Run", crossfade: fade(.distress)))
        }
    }

    @Test("error activity shows distress")
    func errorIsDistress() {
        var c = make()
        #expect(c.stateChanged(.error, at: 0) == .loop(clip: "Fear", crossfade: fade(.distress)))
    }

    @Test("sleepy at idle loops Sit; the fox has no Sit and stays on Survey")
    func sleepyEmotion() {
        var c = make()
        #expect(c.stateChanged(state(.idle, .sleepy), at: 0) == .loop(clip: "Sit", crossfade: fade(.sleepy)))
        var fox = make(.fox)
        #expect(fox.stateChanged(state(.idle, .sleepy), at: 0) == nil) // already on Survey
    }

    @Test("surprised is a react one-shot back to the rest loop")
    func surprisedOneShot() {
        var c = make()
        #expect(
            c.stateChanged(state(.idle, .surprised), at: 0)
                == .oneShot(clip: "Jump", thenLoop: "Idle_A", crossfade: fade(.react))
        )
    }

    @Test("love is a Clicked one-shot; the fox falls back to its react clip")
    func loveOneShot() {
        var c = make()
        #expect(
            c.stateChanged(state(.idle, .love), at: 0)
                == .oneShot(clip: "Clicked", thenLoop: "Idle_A", crossfade: fade(.affection))
        )
        var fox = make(.fox)
        #expect(
            fox.stateChanged(state(.idle, .love), at: 0)
                == .oneShot(clip: "Run", thenLoop: "Survey", crossfade: fade(.affection))
        )
    }

    @Test("a sparkle (excited at idle) is a react one-shot, once")
    func excitedSparkle() {
        var c = make()
        #expect(
            c.stateChanged(state(.idle, .excited), at: 0)
                == .oneShot(clip: "Jump", thenLoop: "Idle_A", crossfade: fade(.react))
        )
        #expect(c.stateChanged(state(.idle, .excited), at: 1) == nil) // unchanged state, no replay
    }

    @Test("happy, neutral and thinking keep the activity-driven loop")
    func calmEmotionsFollowActivity() {
        for emotion in [AvatarEmotion.happy, .neutral, .thinking] {
            var c = make()
            #expect(c.stateChanged(state(.speaking, emotion), at: 0) == .loop(clip: "Walk", crossfade: fade(.move)))
        }
    }

    @Test("an explicit distress emotion suppresses the answer-landing beat")
    func distressSuppressesBeat() {
        var c = make()
        _ = c.stateChanged(state(.thinking, .sad), at: 0)
        #expect(c.stateChanged(state(.generating, .sad), at: 1) == nil) // still Fear
    }

    // MARK: - Idle life

    @Test("at rest, a fidget one-shot fires after the randomised interval, then returns to rest")
    func fidgetFires() {
        var c = make(random: 0) // 12 s
        _ = c.stateChanged(.idle, at: 0)
        #expect(c.nextWake == 12)
        #expect(c.tick(at: 11.9) == nil)
        #expect(c.tick(at: 12) == .oneShot(clip: "Idle_B", thenLoop: "Idle_A", crossfade: fade(.fidget)))
        #expect(c.nextWake == nil) // nothing scheduled while the one-shot plays
        #expect(c.oneShotFinished(at: 14) == .loop(clip: "Idle_A", crossfade: fade(.rest)))
        #expect(c.nextWake == 26)
    }

    @Test("the RNG sets the interval between 12 and 25 seconds")
    func fidgetIntervalRange() {
        var low = make(random: 0)
        _ = low.stateChanged(.idle, at: 100)
        #expect(low.nextWake == 112)
        var high = make(random: 1)
        _ = high.stateChanged(.idle, at: 100)
        #expect(high.nextWake == 125)
    }

    @Test("two quiet minutes settle into Sit, and stay there")
    func settlesToSit() {
        var c = make(random: 1) // fidget every 25 s
        _ = c.stateChanged(.idle, at: 0)
        var now = 0.0
        var sat: Double?
        while let wake = c.nextWake, now < 400 {
            now = wake
            switch c.tick(at: now) {
            case let .loop(clip, _)?:
                #expect(clip == "Sit")
                sat = now
            case .oneShot?:
                _ = c.oneShotFinished(at: now + 1)
            case nil: break
            }
            if sat != nil { break }
        }
        #expect(sat == CompanionChoreographer.sleepAfter)
        #expect(c.nextWake == nil) // asleep: nothing more to schedule
    }

    @Test("activity wakes the sleeper into the right loop; going idle again re-arms")
    func wakesOnActivity() {
        var c = make(random: 0)
        _ = c.stateChanged(.idle, at: 0)
        _ = c.tick(at: 130) // past sleepAfter → Sit
        #expect(c.stateChanged(state(.listening, .thinking), at: 200) == .loop(clip: "Idle_B", crossfade: fade(.alert)))
        #expect(c.stateChanged(.idle, at: 210) == .loop(clip: "Idle_A", crossfade: fade(.rest)))
        #expect(c.nextWake == 222)
    }

    @Test("paused or unmounted: no fidget schedule, no commands; resuming re-arms from now")
    func presenceGatesTimers() {
        var c = make(random: 0)
        _ = c.stateChanged(.idle, at: 0)
        c.presenceChanged(.paused, at: 5)
        #expect(c.nextWake == nil)
        #expect(c.tick(at: 500) == nil)
        c.presenceChanged(.unmounted, at: 6)
        #expect(c.nextWake == nil)
        c.presenceChanged(.animating, at: 1000)
        #expect(c.nextWake == 1012) // paused time counts toward neither fidget nor sleep
    }

    @Test("no fidgets while active, listening, or distressed")
    func noFidgetWhenBusy() {
        for s in [state(.thinking, .thinking), state(.generating, .happy), .error, state(.idle, .sad)] {
            var c = make()
            _ = c.stateChanged(s, at: 0)
            _ = c.oneShotFinished(at: 1)
            #expect(c.nextWake == nil, "\(s)")
        }
    }

    @Test("fox keeps Survey at rest: no fidget, no Sit, nothing to schedule")
    func foxHasNoFidget() {
        var c = make(.fox, random: 0)
        _ = c.stateChanged(.idle, at: 0)
        #expect(c.nextWake == nil)
        #expect(c.tick(at: 500) == nil)
    }

    @Test("a stale finish with nothing playing is ignored")
    func staleFinishIgnored() {
        var c = make()
        #expect(c.oneShotFinished(at: 1) == nil)
    }

    // MARK: - Invariant: only bundled clips are ever emitted

    @Test("every command names a clip its companion ships")
    func commandsAreBundled() {
        let states: [AvatarState] = AvatarActivity.allCases.flatMap { a in
            AvatarEmotion.allCases.map { AvatarState(emotion: $0, activity: a) }
        }
        for spec in CompanionSpec.all {
            var c = CompanionChoreographer(dialect: spec.dialect, nextUnit: { 0.5 })
            func check(_ cmd: CompanionChoreographer.Command?) {
                switch cmd {
                case let .loop(clip, _)?:
                    #expect(spec.clips.contains(clip), "\(spec.id) \(clip)")
                case let .oneShot(clip, then, _)?:
                    #expect(spec.clips.contains(clip), "\(spec.id) \(clip)")
                    #expect(spec.clips.contains(then), "\(spec.id) \(then)")
                case nil: break
                }
            }
            var now = 0.0
            for s in states {
                now += 300
                check(c.stateChanged(s, at: now))
                check(c.oneShotFinished(at: now + 0.5))
                check(c.tick(at: now + 200))
            }
        }
    }
}
