//
//  ConstellationPollCadence.swift
//  M1K3MemoryViz
//
//  How often a constellation canvas asks the memory store "did you grow?".
//  Three cadences, precedence hidden > throttled > active: a canvas in an
//  occluded window (or a closed menu-bar popover) has no one to grow FOR, so
//  it backs off furthest; a hot / Low-Power Mac backs off the speculative
//  O(n²) relayout (Cool Head knob 1); otherwise a new `remember` shows up
//  within a couple of seconds. Pure so the precedence is pinned once for
//  both shells (the Mac canvas + the iPad canvas).
//
//  Signed: Kev + claude-fable-5.1, 2026-09-12, Confidence 0.9 (pinned in
//  ConstellationPollCadenceTests; the historical 2 s / 10 s defaults are the
//  Mac canvas' own constants, unchanged). Prior: Unknown.
//

public struct ConstellationPollCadence: Equatable, Sendable {
    public let active: Duration
    public let throttled: Duration
    public let hidden: Duration

    public init(active: Duration = .seconds(2), throttled: Duration = .seconds(10), hidden: Duration = .seconds(30)) {
        self.active = active
        self.throttled = throttled
        self.hidden = hidden
    }

    /// The sleep before the next store poll.
    public func interval(hidden isHidden: Bool, throttled isThrottled: Bool) -> Duration {
        if isHidden { return hidden }
        if isThrottled { return throttled }
        return active
    }
}
