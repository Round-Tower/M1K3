import M1K3Voice
import Testing

/// Pins the decision `AppleSpeechTranscriber` makes when the audio engine posts
/// `.AVAudioEngineConfigurationChange` under a live mic tap. The handler used
/// to tear the tap down and reinstall it unconditionally — right for a real
/// route change (a Bluetooth headset's HFP switch takes the mic to 16 kHz and
/// the old tap goes deaf), wasteful for the notification the iPhone posts
/// ~0.5 s after the FIRST arm of every voice session at an IDENTICAL format
/// (48 kHz mono → 48 kHz mono): two `stt mic input format` lines in the log and
/// an engine bounce for nothing (2026-09-03, iPhone 17 Pro).
struct MicTapReinstallPolicyTests {
    private let builtIn = MicTapFormat(sampleRate: 48000, channelCount: 1)
    private let hfp = MicTapFormat(sampleRate: 16000, channelCount: 1)

    @Test("same format, engine still running → keep the tap, touch nothing")
    func sameFormatRunningKeeps() {
        #expect(
            MicTapReinstallPolicy.action(installed: builtIn, current: builtIn, engineRunning: true) == .keep
        )
    }

    @Test("same format, engine stopped by the system → restart, no tap churn")
    func sameFormatStoppedRestarts() {
        // Apple's contract: the engine may stop and uninitialise itself BEFORE
        // posting the notification. Start it again; the tap is still bound to
        // the live format, so leave it alone.
        #expect(
            MicTapReinstallPolicy.action(installed: builtIn, current: builtIn, engineRunning: false) == .restart
        )
    }

    @Test("sample rate changed (Bluetooth HFP engaging) → reinstall, running or not")
    func rateChangeReinstalls() {
        #expect(
            MicTapReinstallPolicy.action(installed: builtIn, current: hfp, engineRunning: false) == .reinstall
        )
        #expect(
            MicTapReinstallPolicy.action(installed: builtIn, current: hfp, engineRunning: true) == .reinstall
        )
    }

    @Test("channel count changed → reinstall")
    func channelChangeReinstalls() {
        let stereo = MicTapFormat(sampleRate: 48000, channelCount: 2)
        #expect(
            MicTapReinstallPolicy.action(installed: builtIn, current: stereo, engineRunning: true) == .reinstall
        )
    }

    @Test("no tap on record → reinstall (never trust a missing baseline)")
    func noInstalledFormatReinstalls() {
        #expect(
            MicTapReinstallPolicy.action(installed: nil, current: builtIn, engineRunning: true) == .reinstall
        )
    }
}
