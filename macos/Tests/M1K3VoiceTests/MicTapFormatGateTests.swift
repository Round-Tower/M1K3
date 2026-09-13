import M1K3Voice
import Testing

/// Pins the degenerate-format gate that keeps `AppleSpeechTranscriber` from
/// installing a dead audio tap. The live STT mic reads
/// `inputNode.outputFormat(forBus:0)` and, when the audio route hasn't settled
/// (a Bluetooth/HFP mic engaging, or TCC not yet granted), that call returns a
/// degenerate 0-Hz / 0-channel format. Handing THAT to `installTap` invalidates
/// the HAL AudioUnit (kAudioUnitErr_InvalidElement, -10877) and the recogniser
/// captures NOTHING — the "mic won't capture over BLE" bug. The gate is the same
/// `sampleRate > 0` guard StereoCallRecorder already carries, made pure + shared
/// so both capture paths refuse a dead format instead of silently going deaf.
struct MicTapFormatGateTests {
    @Test("a normal built-in mic format is usable")
    func builtInIsUsable() {
        #expect(MicTapFormatGate.isUsable(sampleRate: 48000, channelCount: 1))
    }

    @Test("a Bluetooth HFP format (16kHz mono) is usable")
    func bluetoothHFPIsUsable() {
        // The exact format a BLE headset negotiates once HFP engages — it must
        // pass, or dictation over Bluetooth never installs a tap at all.
        #expect(MicTapFormatGate.isUsable(sampleRate: 16000, channelCount: 1))
    }

    @Test("a degenerate 0-Hz format is rejected — the -10877 trigger")
    func zeroHzRejected() {
        #expect(!MicTapFormatGate.isUsable(sampleRate: 0, channelCount: 1))
    }

    @Test("a 0-channel format is rejected")
    func zeroChannelRejected() {
        #expect(!MicTapFormatGate.isUsable(sampleRate: 48000, channelCount: 0))
    }

    @Test("a fully degenerate format (route not ready) is rejected")
    func fullyDegenerateRejected() {
        #expect(!MicTapFormatGate.isUsable(sampleRate: 0, channelCount: 0))
    }

    /// 2026-09-13 11:45, the Mac in voice mode: the node reported 44.1 kHz (the
    /// rate a just-finished 44.1 kHz TTS queue left behind) while the mic's
    /// hardware ran at 48 kHz. AVAudioEngine raised an uncaught NSException —
    /// "Failed to create tap due to format mismatch" — and the app aborted. The
    /// tap must carry the HARDWARE rate; the node's read-back only fills in
    /// when the hardware reports nothing.
    @Test("the tap takes the hardware rate when the node's read-back is stale")
    func staleNodeRateYieldsToHardware() {
        #expect(MicTapFormatGate.tapSampleRate(nodeRate: 44100, hardwareRate: 48000) == 48000)
    }

    @Test("matching rates pass through unchanged")
    func matchingRates() {
        #expect(MicTapFormatGate.tapSampleRate(nodeRate: 48000, hardwareRate: 48000) == 48000)
    }

    @Test("a silent hardware read falls back to the node's rate")
    func hardwareUnreported() {
        #expect(MicTapFormatGate.tapSampleRate(nodeRate: 16000, hardwareRate: 0) == 16000)
    }

    @Test("no usable rate on either side means no tap")
    func bothDegenerate() {
        #expect(MicTapFormatGate.tapSampleRate(nodeRate: 0, hardwareRate: 0) == nil)
    }
}
