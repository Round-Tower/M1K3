import M1K3Voice
import Testing

/// Pins whether `AppleSpeechTranscriber` turns Apple's voice-processing I/O
/// (echo cancellation + ducking) on for a listen. Measured on the Mac
/// 2026-09-12 (macOS 27.0, Sony WH-1000XM4 as the default input): with VPIO
/// on, the Bluetooth mic's tap delivered ZERO buffers in 4 s across three
/// runs, while the plain tap delivered ~10/s — and touching the main mixer on
/// top of it made `AVAudioEngine.start()` throw -10875 outright. The built-in
/// mic under VPIO delivered normally. A Bluetooth headset needs no echo
/// cancellation anyway: the speaker is on the user's head, not in the room.
///
/// 2026-10-17 (macOS 27.0, MacBook Pro mic, standalone probes): VPIO itself
/// works — 9 identical channels at ~10 buffers/s — until the per-listen device
/// pin points the unit (which reports the SPEAKERS as its device) back at the
/// mic: -10875 by the third listen. It also starves on its own when the
/// system's device set shifts (7 channels, zero buffers), so the Mac opts in
/// behind argv and a watchdog backs a starved listen out (see
/// VoiceProcessingWatchdogTests).
struct VoiceProcessingPolicyTests {
    @Test("Mac, built-in mic → voice processing OFF (VPIO builds the AUVP aggregate the recogniser starves on)")
    func macBuiltInDisables() {
        #expect(!VoiceProcessingPolicy.shouldEnable(platform: .mac, inputIsBluetooth: false))
    }

    @Test("Mac, Bluetooth input → voice processing OFF (VPIO starves the tap)")
    func macBluetoothDisables() {
        #expect(!VoiceProcessingPolicy.shouldEnable(platform: .mac, inputIsBluetooth: true))
    }

    @Test("iOS keeps voice processing on regardless of route (the phone's VPIO path is device-verified)")
    func mobileAlwaysEnables() {
        #expect(VoiceProcessingPolicy.shouldEnable(platform: .mobile, inputIsBluetooth: false))
        #expect(VoiceProcessingPolicy.shouldEnable(platform: .mobile, inputIsBluetooth: true))
    }

    @Test("Mac voice processing is off regardless of transport (VPIO's aggregate starves the recogniser on 27.0)")
    func macOffRegardlessOfTransport() {
        #expect(!VoiceProcessingPolicy.shouldEnable(platform: .mac, inputIsBluetooth: nil))
        #expect(!VoiceProcessingPolicy.shouldEnable(platform: .mac, inputIsBluetooth: true))
        #expect(!VoiceProcessingPolicy.shouldEnable(platform: .mac, inputIsBluetooth: false))
    }

    @Test("Mac voice processing turns echo cancellation on for a positively non-Bluetooth input")
    func macEnabledOnBuiltIn() {
        #expect(VoiceProcessingPolicy.shouldEnable(platform: .mac, inputIsBluetooth: false, macEnabled: true))
    }

    @Test("Mac voice processing never enables on Bluetooth or an unknown transport (a headset under VPIO delivered zero buffers)")
    func macNeverOnBluetoothOrUnknown() {
        #expect(!VoiceProcessingPolicy.shouldEnable(platform: .mac, inputIsBluetooth: true, macEnabled: true))
        #expect(!VoiceProcessingPolicy.shouldEnable(platform: .mac, inputIsBluetooth: nil, macEnabled: true))
    }

    @Test("Mac voice processing is ON by default (Kev 2026-10-25: barge-in all the time); -macVoiceProcessing NO turns it off")
    func macEnabledByDefault() {
        #expect(VoiceProcessingPolicy.macEnabled(arguments: [:]))
        #expect(VoiceProcessingPolicy.macEnabled(arguments: ["macVoiceProcessing": "YES"]))
        #expect(VoiceProcessingPolicy.macEnabled(arguments: ["macVoiceProcessing": "anything else"]))
        #expect(!VoiceProcessingPolicy.macEnabled(arguments: ["macVoiceProcessing": "NO"]))
        #expect(!VoiceProcessingPolicy.macEnabled(arguments: ["macVoiceProcessing": "0"]))
        #expect(!VoiceProcessingPolicy.macEnabled(arguments: ["macVoiceProcessing": "false"]))
        #expect(!VoiceProcessingPolicy.macEnabled(arguments: ["macVoiceProcessing": "Off"]))
    }

    @Test("the input is pinned to the selected mic only WITHOUT voice processing (2026-10-17: the pin broke VPIO by the third listen)")
    func pinOnlyWithoutVoiceProcessing() {
        #expect(VoiceProcessingPolicy.pinsInputDevice(voiceProcessing: false))
        #expect(!VoiceProcessingPolicy.pinsInputDevice(voiceProcessing: true))
    }

    @Test("the VPIO output bus is fed a silent source on mobile only — on the Mac it engages the output device")
    func silentOutputSourceIsMobileOnly() {
        #expect(VoiceProcessingPolicy.feedsSilentOutputSource(platform: .mobile))
        #expect(!VoiceProcessingPolicy.feedsSilentOutputSource(platform: .mac))
    }

    @Test("the tap takes channel 0 only for Mac VPIO (measured: nine identical channels); iOS keeps the mixdown it had")
    func firstChannelOnlyForMacVoiceProcessing() {
        #expect(VoiceProcessingPolicy.takesFirstChannel(platform: .mac, voiceProcessing: true))
        #expect(!VoiceProcessingPolicy.takesFirstChannel(platform: .mac, voiceProcessing: false))
        #expect(!VoiceProcessingPolicy.takesFirstChannel(platform: .mobile, voiceProcessing: true))
    }
}
