//
//  SoundEffectPlayerTests.swift
//  M1K3AvatarTests
//
//  The play POLICY — fully unit-tested via an injected sink (the AVAudioPlayer
//  pool is the production sink, verify-by-launch). Earcons must never play when
//  the user turned them off, and never step on M1K3's own voice.
//

@testable import M1K3Avatar
import Testing

@MainActor
private final class Recorder {
    var played: [SoundEffect] = []
    /// Loop transitions as (effect, started): true = start, false = stop.
    var loops: [(SoundEffect, Bool)] = []
    func sink(_ effect: SoundEffect) {
        played.append(effect)
    }

    func loopSink(_ effect: SoundEffect, _ start: Bool) {
        loops.append((effect, start))
    }
}

struct SoundGateTests {
    @Test("plays only when enabled AND not mid-speech")
    func truthTable() {
        #expect(SoundGate.allows(enabled: true, isSpeaking: false))
        #expect(!SoundGate.allows(enabled: false, isSpeaking: false))
        #expect(!SoundGate.allows(enabled: true, isSpeaking: true))
        #expect(!SoundGate.allows(enabled: false, isSpeaking: true))
    }
}

@MainActor
struct SoundEffectPlayerTests {
    @Test("plays through the sink when enabled and silent")
    func playsWhenEnabled() {
        let rec = Recorder()
        let player = SoundEffectPlayer(isEnabled: true, isSpeaking: { false }, sink: rec.sink)
        player.play(.save)
        #expect(rec.played == [.save])
    }

    @Test("disabled is a no-op")
    func disabledNoOp() {
        let rec = Recorder()
        let player = SoundEffectPlayer(isEnabled: false, isSpeaking: { false }, sink: rec.sink)
        player.play(.error)
        #expect(rec.played.isEmpty)
    }

    @Test("never plays over M1K3's voice")
    func mutedDuringSpeech() {
        let rec = Recorder()
        let player = SoundEffectPlayer(isEnabled: true, isSpeaking: { true }, sink: rec.sink)
        player.play(.voiceEnter)
        #expect(rec.played.isEmpty)
    }

    @Test("toggling isEnabled at runtime takes effect on the next play")
    func runtimeToggle() {
        let rec = Recorder()
        let player = SoundEffectPlayer(isEnabled: false, isSpeaking: { false }, sink: rec.sink)
        player.play(.save)
        player.isEnabled = true
        player.play(.save)
        #expect(rec.played == [.save])
    }

    @Test("startLoop begins a loop when enabled; stopLoop ends it")
    func loopStartStop() {
        let rec = Recorder()
        let player = SoundEffectPlayer(
            isEnabled: true, isSpeaking: { false }, sink: rec.sink, loopSink: rec.loopSink
        )
        player.startLoop(.dialup)
        player.stopLoop(.dialup)
        #expect(rec.loops.map(\.0) == [.dialup, .dialup])
        #expect(rec.loops.map(\.1) == [true, false])
    }

    @Test("startLoop is a no-op when disabled or mid-speech")
    func loopGated() {
        let rec = Recorder()
        let disabled = SoundEffectPlayer(
            isEnabled: false, isSpeaking: { false }, sink: rec.sink, loopSink: rec.loopSink
        )
        disabled.startLoop(.dialup)
        let speaking = SoundEffectPlayer(
            isEnabled: true, isSpeaking: { true }, sink: rec.sink, loopSink: rec.loopSink
        )
        speaking.startLoop(.dialup)
        #expect(rec.loops.isEmpty)
    }

    @Test("startLoop is idempotent — a second start does not re-fire")
    func loopIdempotentStart() {
        let rec = Recorder()
        let player = SoundEffectPlayer(
            isEnabled: true, isSpeaking: { false }, sink: rec.sink, loopSink: rec.loopSink
        )
        player.startLoop(.dialup)
        player.startLoop(.dialup)
        #expect(rec.loops.count == 1)
    }

    @Test("stopLoop on a sound that never started is a no-op")
    func stopWithoutStart() {
        let rec = Recorder()
        let player = SoundEffectPlayer(
            isEnabled: true, isSpeaking: { false }, sink: rec.sink, loopSink: rec.loopSink
        )
        player.stopLoop(.dialup)
        #expect(rec.loops.isEmpty)
    }

    @Test("muting mid-loop stops the in-flight loop immediately")
    func muteStopsLoop() {
        let rec = Recorder()
        let player = SoundEffectPlayer(
            isEnabled: true, isSpeaking: { false }, sink: rec.sink, loopSink: rec.loopSink
        )
        player.startLoop(.dialup)
        player.isEnabled = false
        #expect(rec.loops.map(\.1) == [true, false])
    }

    // MARK: - The courtesy window (the gag lands, then leaves the room)

    @Test("a courtesy-windowed loop stops itself once the window elapses")
    func courtesyWindowAutoStops() async throws {
        let rec = Recorder()
        let player = SoundEffectPlayer(
            isEnabled: true, isSpeaking: { false }, sink: rec.sink, loopSink: rec.loopSink
        )
        player.startLoop(.dialup, courtesyWindow: .milliseconds(20))
        #expect(rec.loops.map(\.1) == [true])
        try await Task.sleep(for: .milliseconds(200))
        #expect(rec.loops.map(\.1) == [true, false])
    }

    @Test("a restart WITHOUT a window never auto-stops — explicit unmute means play to the end")
    func explicitRestartOutlivesCourtesy() async throws {
        let rec = Recorder()
        let player = SoundEffectPlayer(
            isEnabled: true, isSpeaking: { false }, sink: rec.sink, loopSink: rec.loopSink
        )
        player.startLoop(.dialup, courtesyWindow: .milliseconds(20))
        try await Task.sleep(for: .milliseconds(200))
        player.startLoop(.dialup)
        try await Task.sleep(for: .milliseconds(200))
        // start · courtesy-stop · restart — and nothing after.
        #expect(rec.loops.map(\.1) == [true, false, true])
    }

    @Test("an explicit stop cancels the pending courtesy — a stale timer must never kill a later restart")
    func explicitStopCancelsCourtesy() async throws {
        let rec = Recorder()
        let player = SoundEffectPlayer(
            isEnabled: true, isSpeaking: { false }, sink: rec.sink, loopSink: rec.loopSink
        )
        player.startLoop(.dialup, courtesyWindow: .milliseconds(50))
        player.stopLoop(.dialup)
        player.startLoop(.dialup)
        try await Task.sleep(for: .milliseconds(250))
        // start · stop · restart — the 50ms timer died with the stop.
        #expect(rec.loops.map(\.1) == [true, false, true])
    }
}
