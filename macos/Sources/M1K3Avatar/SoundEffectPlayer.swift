//
//  SoundEffectPlayer.swift
//  M1K3Avatar
//
//  Plays the UI earcons, behind two gates: the user's on/off preference and
//  "is M1K3 talking right now" (an earcon must never step on the voice). The
//  POLICY is a pure, fully-tested decision; the actual playback is an injected
//  sink — AVAudioPlayer in production (verify-by-launch), a recorder in tests.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-12, Confidence 0.85 (gate + dispatch
//  test-pinned; AVAudioPlayer pool is verify-at-⌘R). Prior: Unknown.
//  Review: Kev + claude-fable-5, 2026-07-02 — removed the unused
//  SoundEffectPlaying protocol (nothing in the repo typed against it; sink
//  injection is the test seam, and the app holds the concrete player).
//  Review: Kev + claude-fable-5, 2026-08-30, Confidence 0.85 — the courtesy
//  window ("the gag lands, then leaves the room"): startLoop can now carry a
//  self-stop timer, every stop path (explicit, master mute) cancels it, and
//  the AVAudioPlayer pool fades loop stops over 0.4s instead of hard-cutting.
//  Timer semantics test-pinned; the fade itself is verify-by-ear.
//

import AVFoundation
import Foundation
import os

/// The pure play decision: earcons sound only when enabled AND M1K3 isn't
/// mid-speech. One place, exhaustively tested, so the player stays trivial.
public enum SoundGate {
    public static func allows(enabled: Bool, isSpeaking: Bool) -> Bool {
        enabled && !isSpeaking
    }
}

@MainActor
public final class SoundEffectPlayer {
    /// The user's Settings preference, read live so a toggle applies at once.
    /// Muting also silences any in-flight loop immediately — a user who turns
    /// sound off mid-download shouldn't have to wait out the modem screech.
    public var isEnabled: Bool {
        didSet {
            guard !isEnabled, !looping.isEmpty else { return }
            for effect in looping {
                // Kill any pending courtesy timer too (review catch) — the
                // master mute is just another stop, and a stale window must
                // never silence a loop the user later restarts.
                courtesyTasks.removeValue(forKey: effect)?.cancel()
                loopSink(effect, false)
            }
            looping.removeAll()
        }
    }

    private let isSpeaking: @MainActor () -> Bool
    private let sink: @MainActor (SoundEffect) -> Void
    /// Start (`true`) / stop (`false`) a sustained looping sound.
    private let loopSink: @MainActor (SoundEffect, Bool) -> Void
    /// Effects currently looping — so a mute can stop them, and a stop is idempotent.
    private var looping: Set<SoundEffect> = []
    /// Pending courtesy-window timers, keyed by effect; any stop cancels them.
    private var courtesyTasks: [SoundEffect: Task<Void, Never>] = [:]

    /// Designated init — `sink` performs one-shot playback, `loopSink` starts/
    /// stops a sustained loop. Both injectable so the policy is testable without
    /// touching CoreAudio.
    public init(
        isEnabled: Bool,
        isSpeaking: @escaping @MainActor () -> Bool,
        sink: @escaping @MainActor (SoundEffect) -> Void,
        loopSink: @escaping @MainActor (SoundEffect, Bool) -> Void = { _, _ in }
    ) {
        self.isEnabled = isEnabled
        self.isSpeaking = isSpeaking
        self.sink = sink
        self.loopSink = loopSink
    }

    public func play(_ effect: SoundEffect) {
        guard SoundGate.allows(enabled: isEnabled, isSpeaking: isSpeaking()) else { return }
        sink(effect)
    }

    /// Begin a sustained looping sound (the dial-up "connecting…" hum). Gated
    /// like `play`: only when enabled and M1K3 isn't speaking. Idempotent — a
    /// second start while already looping is a no-op.
    ///
    /// `courtesyWindow` is the "gag lands, then leaves the room" rule (Kev,
    /// 2026-08-30 — a 15-second joke over a minutes-long download): after the
    /// window the loop stops ITSELF. A start without a window (the mute
    /// button's explicit unmute) plays to the end — asking for it back means
    /// wanting the whole thing.
    public func startLoop(_ effect: SoundEffect, courtesyWindow: Duration? = nil) {
        guard SoundGate.allows(enabled: isEnabled, isSpeaking: isSpeaking()) else { return }
        guard looping.insert(effect).inserted else { return }
        loopSink(effect, true)
        guard let courtesyWindow else { return }
        courtesyTasks[effect] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: courtesyWindow)
            guard !Task.isCancelled else { return }
            self?.stopLoop(effect)
        }
    }

    /// Stop a sustained sound. NOT gated — a stop must always land (e.g. the
    /// load finished) even if the effect was never started; then it's a no-op.
    /// Always kills a pending courtesy timer, so a stale window can never
    /// silence a loop the user explicitly restarted.
    public func stopLoop(_ effect: SoundEffect) {
        courtesyTasks.removeValue(forKey: effect)?.cancel()
        guard looping.remove(effect) != nil else { return }
        loopSink(effect, false)
    }
}

public extension SoundEffectPlayer {
    /// Production player: preloads the bundled WAVs into a pool of prepared
    /// AVAudioPlayers and plays via CoreAudio. Independent of the voice
    /// AVAudioEngine — the system mixer composes them.
    static func bundled(
        isEnabled: Bool,
        volume: Float = 0.6,
        isSpeaking: @escaping @MainActor () -> Bool
    ) -> SoundEffectPlayer {
        let pool = AVAudioEarconPool(volume: volume)
        return SoundEffectPlayer(
            isEnabled: isEnabled,
            isSpeaking: isSpeaking,
            sink: { effect in pool.play(effect) },
            loopSink: { effect, start in pool.loop(effect, start: start) }
        )
    }
}

/// Thin AVAudioPlayer pool — one prepared player per effect, restarted on each
/// play (overlap isn't needed for these brief, infrequent earcons). All on the
/// main actor; verify-at-⌘R.
@MainActor
private final class AVAudioEarconPool {
    private static let log = Logger(subsystem: "app.m1k3", category: "sfx")
    private var players: [SoundEffect: AVAudioPlayer] = [:]
    private let volume: Float
    /// In-flight fade-out completions, so a restart during the fade cancels
    /// the pending hard stop instead of being killed by it.
    private var fadeStops: [SoundEffect: DispatchWorkItem] = [:]
    /// Loop stops fade rather than cut — 0.4s reads as instant on a mute tap
    /// but spares the ear the hard chop mid-screech.
    private let loopFadeSeconds = 0.4

    init(volume: Float) {
        self.volume = volume
        for effect in SoundEffect.allCases {
            guard let url = SoundEffectAssets.url(for: effect) else {
                Self.log.error("earcon WAV missing for \(effect.rawValue, privacy: .public)")
                continue
            }
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.volume = volume
                player.prepareToPlay()
                players[effect] = player
            } catch {
                Self.log.error("earcon load failed for \(effect.rawValue, privacy: .public): \(error, privacy: .public)")
            }
        }
    }

    func play(_ effect: SoundEffect) {
        guard let player = players[effect] else { return }
        player.numberOfLoops = 0
        player.currentTime = 0
        player.play()
    }

    /// Start (`start: true`) or stop a sustained looped playback. Resets
    /// `numberOfLoops` to 0 on stop so a later one-shot `play` isn't infinite.
    func loop(_ effect: SoundEffect, start: Bool) {
        guard let player = players[effect] else { return }
        if start {
            // A restart mid-fade cancels the pending hard stop and restores
            // full volume — otherwise the stale completion would kill it.
            fadeStops.removeValue(forKey: effect)?.cancel()
            player.volume = volume
            player.numberOfLoops = -1
            player.currentTime = 0
            player.play()
        } else {
            player.setVolume(0, fadeDuration: loopFadeSeconds)
            let restoreVolume = volume // by value — no self capture in the stored item
            let stop = DispatchWorkItem { [weak player] in
                player?.stop()
                player?.numberOfLoops = 0
                player?.currentTime = 0
                player?.volume = restoreVolume
            }
            fadeStops[effect] = stop
            DispatchQueue.main.asyncAfter(deadline: .now() + loopFadeSeconds, execute: stop)
        }
    }
}
