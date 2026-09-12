//
//  AvatarPresence.swift
//  M1K3Avatar
//
//  Whether an avatar surface should be mounted, mounted-but-still, or alive —
//  the pure rule behind the 2026-09-12 thermal audit's headline fix.
//
//  The fact this encodes: a RealityView keeps the process-global RealityKit
//  engine (DisplayLinkClock → ARView.commonRenderCallback → Metal commit)
//  ticking at display rate for as long as it is MOUNTED, whether or not its
//  window is on screen. Measured on Kev's M1 Max: one hidden 72 px Fox in the
//  ordered-out notch HUD held an otherwise idle M1K3 at ~33% CPU (fan on);
//  a second hidden Fox left behind by a closed menu-bar popover took it to
//  ~45-49%. Pausing an animation does not stop that loop — only unmounting
//  does. So the first input wins outright: a window nobody can see gets no
//  surface at all. The other two inputs only decide still-vs-alive for a
//  surface that IS on screen (the ChatBackdropTreatment `animatesMotion`
//  contract, plus Low Power Mode as an independent freeze).
//
//  Signed: Kev + claude-fable-5.1, 2026-09-12, Confidence 0.9 (the rule is
//  pinned in AvatarPresenceTests; the measurement it rests on is in the PR).
//  Prior: Unknown.
//

/// The three states an avatar surface can be in, from cheapest to liveliest.
public enum AvatarPresence: Equatable, Sendable {
    /// No RealityView exists. The only state that stops the render loop.
    case unmounted
    /// Mounted and drawn once, clocks stopped, animations parked in place.
    case paused
    /// Mounted with its idle motion running.
    case animating

    /// Resolve from the three live inputs. `windowVisible` is the hosting
    /// window's occlusion-derived visibility; `animatesMotion` is the
    /// treatment's verdict (recede/still/Reduce Motion already folded in);
    /// `lowPower` is Low Power Mode, read at render like the treatment does.
    public static func resolve(windowVisible: Bool, animatesMotion: Bool, lowPower: Bool) -> AvatarPresence {
        guard windowVisible else { return .unmounted }
        if lowPower || !animatesMotion { return .paused }
        return .animating
    }

    /// Whether a RealityView should exist at all.
    public var isMounted: Bool {
        self != .unmounted
    }

    /// What to hand a `TimelineView(paused:)` / an animation playback: true for
    /// everything but `.animating`, so an unmounted surface that still owns a
    /// clock (a paused-timeline caller mid-transition) never runs it for nothing.
    public var isPaused: Bool {
        self != .animating
    }
}
