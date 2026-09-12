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
    /// speaker sits on the user's head. `nil` transport (couldn't read it) keeps
    /// the common built-in case echo-cancelled.
    public static func shouldEnable(platform: Platform, inputIsBluetooth: Bool?) -> Bool {
        switch platform {
        case .mobile: true
        case .mac: !(inputIsBluetooth ?? false)
        }
    }

    /// Feed the VPIO output bus a silent source (mobile: ~330 render errors a
    /// second without one). On the Mac the implicit mixer → output connection
    /// engages the OUTPUT device for a mic-only engine: -10875 on a Bluetooth
    /// headset, and the headset held in its call profile after the listen.
    public static func feedsSilentOutputSource(platform: Platform) -> Bool {
        platform == .mobile
    }
}
