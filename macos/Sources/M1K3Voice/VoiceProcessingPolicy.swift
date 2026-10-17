//
//  VoiceProcessingPolicy.swift
//  M1K3Voice
//
//  Whether a listen turns on Apple's voice-processing I/O (AEC + ducking) and
//  whether the VPIO output bus gets a silent render source. Pure, so the
//  decision is test-pinned; `AppleSpeechTranscriber` reads it.
//
//  Why it exists (2026-09-12, macOS 27.0, launch snag "voice mode fails
//  instantly"): with a Bluetooth headset as the default input, VPIO produced
//  NO audio at all (three 4 s probes, 0 buffers vs ~10/s plain), and the Mac's
//  copy of the phone's #205 fix — touching `mainMixerNode` so the VPIO output
//  bus has a source — connected the engine's OUTPUT to the headset too, which
//  made `AVAudioEngine.start()` throw -10875. The transcriber swallowed that
//  throw silently, the loop counted twelve empty listens in 400 ms and parked:
//  Kev's "instant failure to start audio recording". The same output-side
//  engagement held the headset in its 16 kHz phone-call profile after voice
//  mode ended ("reduced speaker & microphone output even after M1K3's
//  engagement") — releasing the engine on teardown is the other half.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-12, Confidence 0.85 (every branch
//  measured on this Mac with a standalone AVAudioEngine probe; the phone side
//  is unchanged by construction). Prior: Unknown.
//
//  Review: Kev + claude-opus-4-8, 2026-09-12 (later) — VOICE PROCESSING OFF ON
//  THE MAC. CoreAudio's own log named it: enabling VPIO builds an
//  `AUVPAggregate` (input+output) the engine binds to and the recogniser
//  starves on (ch=9), on the built-in mic AND a headset — not a Bluetooth-only
//  bug. The transport read and the format back-out both chased a symptom; the
//  cause is VPIO itself on 27.0. The only config that held all night was off.
//  Mute-while-speaking covers echo. Confidence 0.85 (verify-by-launch).
//
//  Review: Kev + claude-opus-4-8, 2026-09-12 — fail SAFE. A fresh-launch drive
//  on the reconnected headset STILL turned VPIO on and starved the recogniser:
//  `defaultInputIsBluetooth()` came back not-true inside the sandbox (the HAL
//  transport read is unreliable there / on a just-reconnected route), and the
//  old `!(inputIsBluetooth ?? false)` treated unknown as "enable". Now the Mac
//  enables VP only on POSITIVE not-Bluetooth (`== false`); unknown → off. A
//  wrongly-off built-in only loses echo cancellation; a wrongly-on headset
//  parks voice mode. Confidence 0.85 (verify-by-launch on the rebuild).
//  Review: Kev + claude-opus-5, 2026-09-13 — shouldBackOutVoiceProcessing documented as DORMANT
//  (unreachable while shouldEnable is false on the Mac), kept as the re-enable safety net. Confidence 0.85.
//  Review: Kev + claude-opus-5-5, 2026-10-17 — the September cause was HALF ours. Standalone probes on
//  macOS 27.0 (MacBook Pro mic): VPIO works (9 identical channels, ~10 buffers/s, three relistens clean)
//  until `pinInputToDefaultDevice` re-points the unit, which reports the SPEAKERS as its device under
//  VPIO, back at the mic: -10875 and zero buffers by the third listen. The other half is the system's:
//  later the same clean probe got 7 channels and zero buffers once the device set shifted (a Continuity
//  iPhone mic and an empty aggregate appeared). So: `pinsInputDevice` skips the pin under VPIO, the Mac
//  opts in behind argv (`-macVoiceProcessing YES`, positive non-Bluetooth only), and
//  `VoiceProcessingWatchdog` replaces the channel-count back-out — 9 channels is VPIO's healthy shape,
//  so that guard would have backed out every good listen. Echo payoff, measured: the recogniser read
//  21/21 of M1K3's spoken words off the mic with VPIO off, 0/21 with it on. Confidence 0.7: probes,
//  not yet a launch.
//

import Foundation

public enum VoiceProcessingPolicy {
    public enum Platform: Sendable, Equatable {
        case mac
        case mobile
    }

    /// The platform this build runs on.
    public static var current: Platform {
        #if os(macOS)
            .mac
        #else
            .mobile
        #endif
    }

    /// Turn voice processing on for this listen? Mobile always. The Mac only when
    /// opted in (`macOptIn`, argv `-macVoiceProcessing YES`) AND the input is
    /// POSITIVELY not Bluetooth: a headset under VPIO delivered zero buffers
    /// (2026-09-12) and needs no echo cancellation anyway, and an unknown transport
    /// fails safe, since a wrongly-off built-in only loses echo cancellation while a
    /// wrongly-on headset goes deaf. Even opted in, VPIO on macOS 27.0 can starve
    /// when the system's device set shifts (2026-10-17), so the transcriber runs
    /// `VoiceProcessingWatchdog` and backs a starved listen out.
    public static func shouldEnable(platform: Platform, inputIsBluetooth: Bool?, macOptIn: Bool = false) -> Bool {
        switch platform {
        case .mobile: true
        case .mac: macOptIn && inputIsBluetooth == false
        }
    }

    /// The Mac opt-in, read from argv (`M1K3 -macVoiceProcessing YES`; on macOS 27
    /// `defaults write` never reaches the sandboxed app). Absent means off.
    public static func macOptIn(
        arguments: [String: Any] = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    ) -> Bool {
        guard let raw = arguments["macVoiceProcessing"] as? String else { return false }
        return ["yes", "1", "true", "on"].contains(raw.lowercased())
    }

    /// Pin the engine's input unit to the user's selected mic for this listen?
    /// Only WITHOUT voice processing. Under VPIO the unit's current device reads as
    /// the OUTPUT device (it drives an input + output aggregate), so the pin saw a
    /// "wrong" device and re-pointed it at the mic, and the third listen failed to
    /// start (-10875, zero buffers; measured 2026-10-17). VPIO picks its own route.
    public static func pinsInputDevice(voiceProcessing: Bool) -> Bool {
        !voiceProcessing
    }

    /// Take channel 0 instead of the mixdown sum? Mac VPIO copies its one processed
    /// signal to all nine channels (measured 2026-10-17), so the sum would clip it
    /// ninefold. iOS keeps the mixdown it had: its VPIO shape is unmeasured here.
    public static func takesFirstChannel(platform: Platform, voiceProcessing: Bool) -> Bool {
        platform == .mac && voiceProcessing
    }

    /// Feed the VPIO output bus a silent source (mobile: ~330 render errors a
    /// second without one). On the Mac the implicit mixer → output connection
    /// engages the OUTPUT device for a mic-only engine: -10875 on a Bluetooth
    /// headset, and the headset held in its call profile after the listen.
    public static func feedsSilentOutputSource(platform: Platform) -> Bool {
        platform == .mobile
    }
}

/// Did voice processing come up? On macOS 27.0 a starved VPIO tap never delivers a
/// single buffer (7-channel format, zero buffers over 3 s), while a healthy one
/// delivers ~10 a second from the start (2026-10-17). So the transcriber looks
/// `deadline` after the engine starts, and again a deadline later if it heard
/// nothing: still nothing means back voice processing out and relisten plain, for
/// the rest of the engagement. A route-change reinstall restarts the tap's count
/// (VPIO's own start can post one), so a reinstall since the last look earns
/// another, up to `maxChecks`: a healthy start must never be written off.
public enum VoiceProcessingWatchdog {
    public enum Decision: Sendable, Equatable {
        case live
        case recheck
        case starved
    }

    /// The most looks a listen gets (about 2.4 s), however many reinstalls.
    public static let maxChecks = 4

    /// Several buffers of slack for a healthy tap, short enough that a starved
    /// listen recovers before the user has finished their first words.
    public static let deadline: Duration = .milliseconds(600)

    /// The Mac only: iOS keeps VPIO on every route (`shouldEnable`), so a back-out
    /// there would just turn it back on.
    public static func applies(platform: VoiceProcessingPolicy.Platform) -> Bool {
        platform == .mac
    }

    /// `check` counts from 1. `buffersSeen` is since the tap's latest install.
    public static func decision(buffersSeen: Int, check: Int, reinstalledSinceLastCheck: Bool) -> Decision {
        if buffersSeen > 0 { return .live }
        if check < 2 || (reinstalledSinceLastCheck && check < maxChecks) { return .recheck }
        return .starved
    }
}
