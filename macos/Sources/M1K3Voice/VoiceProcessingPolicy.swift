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
//  Review: Kev + claude-opus-4-8, 2026-09-12 — fail SAFE. A fresh-launch drive
//  on the reconnected headset STILL turned VPIO on and starved the recogniser:
//  `defaultInputIsBluetooth()` came back not-true inside the sandbox (the HAL
//  transport read is unreliable there / on a just-reconnected route), and the
//  old `!(inputIsBluetooth ?? false)` treated unknown as "enable". Now the Mac
//  enables VP only on POSITIVE not-Bluetooth (`== false`); unknown → off. A
//  wrongly-off built-in only loses echo cancellation; a wrongly-on headset
//  parks voice mode. Confidence 0.85 (verify-by-launch on the rebuild).
//

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

    /// Turn voice processing on for this listen? On the Mac a Bluetooth input
    /// (HFP) starves the tap under VPIO and needs no echo cancellation — the
    /// speaker sits on the user's head. So the Mac enables VP ONLY when it can
    /// POSITIVELY confirm the input is not Bluetooth (`inputIsBluetooth ==
    /// false`, the common built-in mic). An UNKNOWN transport (`nil` — the
    /// sandbox refused the CoreAudio read, or a just-reconnected headset hasn't
    /// settled) fails SAFE to VP off: a wrongly-off built-in mic merely loses
    /// echo cancellation, but a wrongly-ON headset starves the recogniser and
    /// parks voice mode mutely (the launch snag). Positive knowledge, not
    /// optimism.
    public static func shouldEnable(platform: Platform, inputIsBluetooth: Bool?) -> Bool {
        switch platform {
        case .mobile: true
        case .mac: inputIsBluetooth == false
        }
    }

    /// After voice processing is enabled, the mic format the engine hands back
    /// is the ground truth the transport read could not give us. On the Mac,
    /// VPIO over a Bluetooth headset — or over ANY route that resolves through
    /// a system aggregate device (`~:AMS2_Aggregate`, which a prior VPIO
    /// session leaves behind) — renders a >2-channel format the recogniser is
    /// then STARVED on (zero buffers, `audioDuration 0`, the instant-endpoint
    /// storm). A clean built-in mic under VPIO renders 1 channel. So a
    /// post-enable format with more than two channels is the reliable, in-app
    /// signal to back voice processing OUT and relisten on the raw device —
    /// self-healing where `defaultInputIsBluetooth()` (which reads the
    /// aggregate's non-Bluetooth transport in-sandbox) silently lies. Mobile
    /// keeps VPIO regardless (its path is device-verified). 2026-09-12.
    public static func shouldBackOutVoiceProcessing(platform: Platform, channelCount: UInt32) -> Bool {
        platform == .mac && channelCount > 2
    }

    /// Feed the VPIO output bus a silent source (mobile: ~330 render errors a
    /// second without one). On the Mac the implicit mixer → output connection
    /// engages the OUTPUT device for a mic-only engine: -10875 on a Bluetooth
    /// headset, and the headset held in its call profile after the listen.
    public static func feedsSilentOutputSource(platform: Platform) -> Bool {
        platform == .mobile
    }
}
