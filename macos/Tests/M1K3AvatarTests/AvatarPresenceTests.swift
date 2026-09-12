//
//  AvatarPresenceTests.swift
//  M1K3AvatarTests
//
//  Pins the one rule the 2026-09-12 thermal audit was about: a RealityKit
//  surface that nobody can see must not EXIST. A mounted RealityView keeps
//  the process-global RealityKit engine (DisplayLinkClock → ARView render
//  callback) ticking at display rate even inside an ordered-out, alpha-0
//  window — the hidden notch-HUD Fox alone held an idle M1K3 at ~33% CPU
//  with the fan on. Pausing an animation does not stop that loop; only
//  unmounting does. So: hidden window → unmounted, whatever else is true.
//

@testable import M1K3Avatar
import Testing

struct AvatarPresenceTests {
    @Test("a hidden window unmounts the surface, whatever the motion inputs say")
    func hiddenWindowUnmounts() {
        for animates in [true, false] {
            for lowPower in [true, false] {
                let presence = AvatarPresence.resolve(
                    windowVisible: false, animatesMotion: animates, lowPower: lowPower
                )
                #expect(presence == .unmounted)
            }
        }
    }

    @Test("visible + motion allowed + mains → animating")
    func visibleAnimates() {
        #expect(AvatarPresence.resolve(windowVisible: true, animatesMotion: true, lowPower: false) == .animating)
    }

    @Test("visible but the treatment says still (recede/still/Reduce Motion) → paused, still mounted")
    func visibleStillPauses() {
        let presence = AvatarPresence.resolve(windowVisible: true, animatesMotion: false, lowPower: false)
        #expect(presence == .paused)
        #expect(presence.isMounted)
    }

    @Test("Low Power Mode pauses a visible surface even when the treatment would animate")
    func lowPowerPauses() {
        #expect(AvatarPresence.resolve(windowVisible: true, animatesMotion: true, lowPower: true) == .paused)
    }

    @Test("isMounted / isPaused read as the view code uses them")
    func flags() {
        #expect(!AvatarPresence.unmounted.isMounted)
        #expect(AvatarPresence.paused.isMounted)
        #expect(AvatarPresence.animating.isMounted)
        #expect(AvatarPresence.paused.isPaused)
        #expect(!AvatarPresence.animating.isPaused)
        // An unmounted surface reports paused too: the callers that thread
        // `paused:` into a TimelineView must never run a clock for nothing.
        #expect(AvatarPresence.unmounted.isPaused)
    }
}
