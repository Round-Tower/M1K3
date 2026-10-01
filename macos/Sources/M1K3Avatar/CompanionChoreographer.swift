//
//  CompanionChoreographer.swift
//  M1K3Avatar
//
//  The pure brain behind a 3D companion's body language. AvatarState changes,
//  elapsed time and surface presence go in; `.loop` / `.oneShot` clip commands
//  come out. The view (CompanionAvatarView.sync) only executes them.
//
//  Why it exists: the old state→clip map was a single "which loop" lookup, so a
//  streaming reply (derived emotion .excited) looped Jump/Run for the whole
//  answer and the move clip, Sit, Clicked and Fear were effectively dead —
//  Kev: "only really see 2/3". The fixes live here:
//   1. Loops follow the ACTIVITY (generating/speaking → the dialect's move
//      clip); the react clip is a one-shot BEAT when the answer starts landing.
//   2. Idle life: a fidget one-shot every 12–25 s, then Sit after two quiet
//      minutes, until the next activity.
//   3. Explicit emotions get clips: sad/angry → distress loop, sleepy → Sit
//      loop, surprised / sparkle → react one-shot, love → Clicked one-shot.
//
//  Time is passed IN (`at now`, seconds on any monotonic clock) and randomness
//  is injected (`nextUnit`, 0…1), so every rule is a plain test. Idle timers
//  run only while the surface is `.animating` and resting — `nextWake` is nil
//  otherwise, so the view arms ONE sleeping task (never a per-frame clock) and
//  a hidden/paused companion costs nothing (the 2026-09-12 thermal audit).
//
//  Signed: Kev + claude-opus-5-5, 2026-10-01, Confidence 0.75 (rules pinned in
//  CompanionChoreographerTests; how it FEELS — beat length, fidget cadence — is
//  verify-by-launch), Prior: none (new file)

public struct CompanionChoreographer {
    public enum Command: Equatable, Sendable {
        /// Crossfade to `clip` and repeat it.
        case loop(clip: String, crossfade: Double)
        /// Play `clip` once, then crossfade to `thenLoop` (the view calls
        /// `oneShotFinished` when it completes and executes what comes back).
        case oneShot(clip: String, thenLoop: String, crossfade: Double)
    }

    /// Quiet seconds at rest before the companion settles into Sit.
    public static let sleepAfter: Double = 120
    /// Fidget cadence, seconds: `nextUnit` 0 → min, 1 → max.
    public static let fidgetInterval: ClosedRange<Double> = 12 ... 25

    private let dialect: CompanionDialect
    private let nextUnit: () -> Double

    private var state: AvatarState = .idle
    private var presence: AvatarPresence = .animating
    /// The loop that is (or, after a one-shot ends, will be) playing.
    private var targetLoop: String
    private var oneShotActive = false
    /// Settled into Sit after a long quiet spell.
    private var sleeping = false
    private var wasResting = true
    private var restingSince: Double = 0
    private var nextFidgetAt: Double = 0
    private var started = false

    public init(dialect: CompanionDialect, nextUnit: @escaping () -> Double) {
        self.dialect = dialect
        self.nextUnit = nextUnit
        targetLoop = dialect.clipName(for: .rest) // the view starts every creature on its rest clip
    }

    // MARK: - Inputs

    /// The avatar state changed (or the view is syncing to the current one —
    /// an unchanged state is a no-op, so calling every update is fine).
    public mutating func stateChanged(_ new: AvatarState, at now: Double) -> Command? {
        guard new != state || !started else { return nil }
        let old = state
        let firstSync = !started
        started = true
        state = new

        let resting = Self.isResting(new)
        if resting, !wasResting || firstSync { armRest(at: now) }
        if !resting { sleeping = false }
        wasResting = resting

        let desired = desiredLoop()
        if let beat = beatClip(from: old, to: new) {
            oneShotActive = true
            targetLoop = desired
            return .oneShot(clip: beat.clip, thenLoop: desired, crossfade: beat.fade)
        }
        guard desired != targetLoop else { return nil }
        // A different loop wins over a beat in flight (error, back to idle…).
        oneShotActive = false
        targetLoop = desired
        return .loop(clip: desired, crossfade: ClipMapper.crossfadeDuration(to: currentLoopGait()))
    }

    /// The scheduled wake (`nextWake`) arrived. Returns the fidget, or the
    /// settle into Sit; nil when nothing is due or the surface isn't live.
    public mutating func tick(at now: Double) -> Command? {
        guard presence == .animating, !oneShotActive, !sleeping, Self.isResting(state) else { return nil }
        let rest = dialect.clipName(for: .rest)
        let sit = dialect.clipName(for: .sleepy)
        if now - restingSince >= Self.sleepAfter, sit != rest {
            sleeping = true
            targetLoop = sit
            return .loop(clip: sit, crossfade: ClipMapper.crossfadeDuration(to: .sleepy))
        }
        guard now >= nextFidgetAt, let fidget = fidgetClip else { return nil }
        oneShotActive = true
        nextFidgetAt = now + interval()
        return .oneShot(clip: fidget, thenLoop: targetLoop, crossfade: ClipMapper.crossfadeDuration(to: .fidget))
    }

    /// The running one-shot completed (the view guards against stale completions
    /// from interrupted clips). Returns the loop to settle back onto.
    public mutating func oneShotFinished(at now: Double) -> Command? {
        guard oneShotActive else { return nil }
        oneShotActive = false
        if Self.isResting(state), !sleeping { nextFidgetAt = now + interval() }
        return .loop(clip: targetLoop, crossfade: ClipMapper.crossfadeDuration(to: currentLoopGait()))
    }

    /// The surface went live / paused / unmounted. Only `.animating` runs idle
    /// timers; coming back re-arms from `now` so hidden time never counts as
    /// quiet time (and a long-hidden companion doesn't fidget the instant it shows).
    public mutating func presenceChanged(_ new: AvatarPresence, at now: Double) {
        guard new != presence else { return }
        presence = new
        if new == .animating, Self.isResting(state), !sleeping { armRest(at: now) }
    }

    // MARK: - Output

    /// When the view should next call `tick`, or nil for "no timer": paused,
    /// unmounted, busy, mid one-shot, asleep, or a dialect with nothing to do.
    public var nextWake: Double? {
        guard presence == .animating, !oneShotActive, !sleeping, Self.isResting(state) else { return nil }
        var wakes: [Double] = []
        if fidgetClip != nil { wakes.append(nextFidgetAt) }
        if dialect.clipName(for: .sleepy) != dialect.clipName(for: .rest) {
            wakes.append(restingSince + Self.sleepAfter)
        }
        return wakes.min()
    }

    // MARK: - Rules

    private static func isResting(_ state: AvatarState) -> Bool {
        ClipMapper.gait(for: state) == .rest
    }

    private var fidgetClip: String? {
        let clip = dialect.clipName(for: .fidget)
        return clip == dialect.clipName(for: .rest) ? nil : clip
    }

    private func interval() -> Double {
        let unit = min(max(nextUnit(), 0), 1)
        return Self.fidgetInterval.lowerBound + unit * (Self.fidgetInterval.upperBound - Self.fidgetInterval.lowerBound)
    }

    private mutating func armRest(at now: Double) {
        restingSince = now
        nextFidgetAt = now + interval()
    }

    private func currentLoopGait() -> CompanionGait {
        sleeping ? .sleepy : ClipMapper.gait(for: state)
    }

    private func desiredLoop() -> String {
        dialect.clipName(for: currentLoopGait())
    }

    /// The one-shot (if any) this transition earns. Derived emotions never
    /// qualify — `.excited` under generating/speaking is `fromActivity`'s doing;
    /// the answer-landing beat comes from the ACTIVITY change instead.
    private func beatClip(from old: AvatarState, to new: AvatarState) -> (clip: String, fade: Double)? {
        let gait = ClipMapper.gait(for: new)
        guard gait != .distress else { return nil } // Fear is a loop; no beat on top of it
        let react = (dialect.clipName(for: .react), ClipMapper.crossfadeDuration(to: .react))

        if new.emotion != old.emotion {
            switch new.emotion {
            case .surprised:
                return react
            case .love:
                return (dialect.clipName(for: .affection), ClipMapper.crossfadeDuration(to: .affection))
            case .excited where new.activity != .generating && new.activity != .speaking:
                return react // a sparkle: HelloView, the companion picker, wake setup
            default: break
            }
        }
        let landing = new.activity == .generating && old.activity != .generating && old.activity != .speaking
        return landing ? react : nil
    }
}
