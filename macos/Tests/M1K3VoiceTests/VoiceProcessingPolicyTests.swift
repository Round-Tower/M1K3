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

    @Test("Mac: a >2-channel VPIO format backs voice processing out (the aggregate/BT route starves the recogniser)")
    func macBacksOutOnMultichannelVPIO() {
        #expect(VoiceProcessingPolicy.shouldBackOutVoiceProcessing(platform: .mac, channelCount: 3))
        #expect(VoiceProcessingPolicy.shouldBackOutVoiceProcessing(platform: .mac, channelCount: 9))
    }

    @Test("Mac: a clean 1- or 2-channel VPIO format keeps voice processing (echo cancellation earns its keep)")
    func macKeepsVPIOOnCleanFormat() {
        #expect(!VoiceProcessingPolicy.shouldBackOutVoiceProcessing(platform: .mac, channelCount: 1))
        #expect(!VoiceProcessingPolicy.shouldBackOutVoiceProcessing(platform: .mac, channelCount: 2))
    }

    @Test("iOS never backs VPIO out on channel count — its path is device-verified")
    func mobileNeverBacksOut() {
        #expect(!VoiceProcessingPolicy.shouldBackOutVoiceProcessing(platform: .mobile, channelCount: 9))
    }

    @Test("the VPIO output bus is fed a silent source on mobile only — on the Mac it engages the output device")
    func silentOutputSourceIsMobileOnly() {
        #expect(VoiceProcessingPolicy.feedsSilentOutputSource(platform: .mobile))
        #expect(!VoiceProcessingPolicy.feedsSilentOutputSource(platform: .mac))
    }
}
