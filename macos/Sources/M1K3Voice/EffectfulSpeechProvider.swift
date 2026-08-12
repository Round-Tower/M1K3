//
//  EffectfulSpeechProvider.swift
//  M1K3Voice
//
//  Gives M1K3 its own voice TODAY by running Apple's synthesized speech through the
//  pure VoiceEffectChain before playback: AVSpeechSynthesizer.write → [Float] PCM →
//  effect chain → AVAudioEngine. So "M1K3 Voice" sounds distinct from the plain
//  Built-in tier even before the Kokoro neural model lands — and when it does, its
//  PCM flows through the exact same chain + playback path (this provider becomes
//  Kokoro's downstream renderer).
//
//  The DSP is unit-tested in VoiceEffectTests; THIS file is the thin AVFoundation
//  adapter — verify-by-launch. Any failure in the effect path falls back to plain
//  Apple speech, so M1K3 is never left silent.
//
//  Signed: Kev + claude-sonnet-4-6, 2026-06-08, Confidence 0.55, Prior: Unknown
//  Review: claude-opus-4-8, 2026-06-09 (PR #10) — stop() fires onSpeakingEnded once
//  (was double-firing on interrupted playback); speak() now interrupts an in-flight
//  utterance so a concurrent call can't leak play()'s continuation. Confidence 0.75.
//  Review: Kev + claude-fable-5, 2026-06-11 — Apple path gains word timing via
//  delegate↔buffer correlation in SynthBox (markers deliver nothing — probed);
//  speak(_:) routes through the streaming session; finishPlayback() now stops
//  the node (a drained player reads isPlaying forever — integration-test catch).
//  Confidence 0.75.
//  Review: Kev + claude-fable-5, 2026-07-16, Confidence 0.85 (concurrency deep
//  pass, finding 9) — SynthBox resumed its offline-render continuation ONLY on
//  write's zero-frame sentinel, so a stop/barge-in (stopSpeaking(at:.immediate))
//  mid-render never delivered it and the continuation LEAKED — every caller
//  awaiting speak() hung forever (the MCP speak HTTP call, the voice loop). Added
//  didFinish (idempotent success backstop when no sentinel arrives) and didCancel
//  (resume exactly once with CancellationError, sharing finish's done flag), plus
//  a `catch is CancellationError` in speak(_:) so a barge-in ends silently rather
//  than re-speaking the stopped utterance via plainSpeak. This is the Apple
//  offline-render path (the M1K3 Voice + Built-in tiers, and Kokoro's Apple
//  FALLBACK — Kokoro's neural path plays its own PCM and doesn't hit
//  synthesizeToFloats). The exactly-once contract is unit-tested
//  (SynthBoxCancellationTests, headless); the real cancelled-render WIRING (a
//  live AVSpeechSynthesizer delivering didCancel) stays verify-by-launch.
//  Review fold (same PR, bot catch): SynthBox now carries the AVSpeechUtterance
//  it OWNS and guards every delegate callback on `utterance === owner`. The
//  synthesizer.delegate is a single shared property reassigned per render, so
//  without this a barge-in's stale didCancel for utterance A could land on B's
//  box and silence B (the catch-CancellationError makes it never speak) — the
//  opposite of the fix. ingest also short-circuits once `done`.
//  Review: Kev + Claude, 2026-07-19 — closed the #52 review residual: two speak()
//  calls that BOTH observed an idle provider could start two overlapping renders,
//  leaking the loser's SynthBox continuation (it never became the synthesizer's
//  delegate, so its terminal callback hit the winner's box and was ignored).
//  ALL THREE public speak entries — speak(), speak(rawPCM:) and the streaming
//  speak(stream:) (the Kokoro/"M1K3 Voice" path, in +Streaming.swift) — now enter
//  through a serial actor gate (SpeechEntryGate) carrying a generation token + a
//  renderInFlight flag: renders run one-at-a-time, a newer call barge-in-interrupts
//  the running one, and a superseded queued call bails — latest-wins, identity
//  guard intact. Because the loser's synthesizeToFloats is now deferred until the
//  predecessor unwinds, the predecessor's box is STILL the delegate when its
//  didCancel arrives, so the continuation resolves instead of leaking. (speak(stream:)
//  was added to the gate after review caught that the Kokoro path — the
//  highest-traffic entry point — still bypassed it; renderText calls the internal
//  un-gated renderStream to avoid self-deadlocking inside the gate.) The gate's
//  serialisation is unit-tested (SpeechEntryGateTests, headless); the live barge-in
//  WIRING stays verify-by-launch.

import AVFoundation
import Foundation

/// One claimed render's place in the two orderings that can invalidate it: which
/// speak entry it is (newer ones win) and which stop era it was claimed in (a
/// stop after that invalidates it, however long its synthesis takes).
struct RenderEntry {
    let generation: Int
    let stopEpoch: Int
}

public final class EffectfulSpeechProvider: NSObject, SpeechProviderWithWordTiming, @unchecked Sendable {
    public let name = "m1k3-effect-voice"

    // `chain`/`player`/`configureEngineIfNeeded`/`streamingSession` are internal
    // (not private) for EffectfulSpeechProvider+Streaming.swift — the chunked
    // playback path lives there to keep this file inside the length budget.
    /// Lock-guarded so the voice character can be switched while the app runs (the
    /// Settings picker) without rebuilding the provider and its audio engine.
    /// Read once per rendered chunk — a lock at ~100ms of audio is free — and the
    /// class is already `@unchecked Sendable` under exactly this discipline. A
    /// switch mid-utterance simply lands on the next chunk, which is the honest
    /// behaviour: audio already handed to the player has been heard.
    private let chainLock = NSLock()
    private var _chain: VoiceEffectChain
    var chain: VoiceEffectChain {
        chainLock.withLock { _chain }
    }

    private let synthesizer = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    /// Used only when the effect/render path fails — M1K3 still speaks, just dry.
    private let plainFallback: AVSpeechProvider

    public var onSpeakingStarted: (@Sendable () -> Void)?
    public var onSpeakingEnded: (@Sendable () -> Void)?
    /// Word-timing seam (SpeechProviderWithWordTiming): the utterance timeline as
    /// soon as it is known (growing per chunk), and the word currently being heard.
    public var onTimelineReady: (@Sendable (SpokenWordTimeline) -> Void)?
    public var onWordSpoken: (@Sendable (Range<Int>) -> Void)?

    @MainActor private var engineConfigured = false
    @MainActor private var configuredSampleRate: Double = 0
    /// Cached speaking flag — flipped by the fireSpeaking* helpers at the exact
    /// seams that fire onSpeakingStarted/Ended, so isSpeaking() never has to poll
    /// the audio engine (a cross-QoS lock-hold + a Thread-Performance-Checker hang
    /// risk when read ~30 fps). See SpeakingState.swift.
    @MainActor private var speakingState = SpeakingState()
    /// The in-flight playback wait, so `stop()` can resume it (the .dataPlayedBack
    /// completion is NOT delivered after player.stop(), which would otherwise hang).
    @MainActor private var playbackContinuation: CheckedContinuation<Void, Never>?
    /// The in-flight chunked playback (speak(stream:)), so `stop()` can cancel it.
    @MainActor var streamingSession: StreamingPlaybackSession?
    /// Serialises EVERY public speak entry — `speak(_:)`, `speak(rawPCM:)` and the
    /// streaming `speak(stream:)` (the Kokoro/"M1K3 Voice" path) — so two racing
    /// callers can never drive the single AVSpeechSynthesizer / shared player
    /// concurrently (the #52 review residual). Internal, not private: the streaming
    /// entry point lives in EffectfulSpeechProvider+Streaming.swift and routes
    /// through this same gate. See the "Entry serialisation" MARK below.
    let entryGate = SpeechEntryGate()
    /// True from the moment a render claims the gate until it unwinds. Covers the
    /// offline-synthesis window that `isSpeaking()` (playback-only) can't see, so a
    /// barge-in during synthesis still interrupts the predecessor.
    @MainActor private var renderInFlight = false
    /// Monotonic per-entry token. A queued render bails if a newer `speak()`
    /// superseded it before it owned the gate — latest-wins, no leaked awaiters.
    @MainActor private var speakGeneration = 0
    /// Monotonic stop token. Bumped by every `stop()`; a render samples it before
    /// synthesis and re-checks after, so a stop that arrives DURING the silent
    /// offline-render window cannot be outlived by the playback that window was
    /// producing. Deliberately separate from `speakGeneration`: `claimEntry` calls
    /// `stop()` on the barge-in path, so a stop that bumped the speak generation
    /// would invalidate the very entry that just claimed it and drop both
    /// utterances.
    @MainActor private var stopEpoch = 0
    /// Observes `.AVAudioEngineConfigurationChange` so an output-route flip (BLE
    /// headphones arriving, AirPods leaving) rebinds playback to the NEW default
    /// device instead of leaving the voice pinned to the old one. Same pattern as
    /// AppleSpeechTranscriber's input-side observer.
    private var configObserver: NSObjectProtocol?

    public init(chain: VoiceEffectChain = .m1k3Character, fallback: AVSpeechProvider = AVSpeechProvider()) {
        _chain = chain
        plainFallback = fallback
        super.init()
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleEngineConfigurationChange() }
        }
    }

    /// Switch the voice character live (Settings). Takes effect on the next
    /// rendered chunk — see `chain`.
    public func setChain(_ newChain: VoiceEffectChain) {
        chainLock.withLock { _chain = newChain }
    }

    deinit {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
    }

    /// The output route changed (live 2026-07-02: BLE headphones connected
    /// mid-session got system sounds but no M1K3 voice until relaunch). The
    /// engine STOPS itself when this fires, so an in-flight utterance's
    /// .dataPlayedBack completion will never arrive — unwind it exactly like
    /// stop() does (finishPlayback resumes play()'s wait, which fires its single
    /// onSpeakingEnded as it unwinds), and drop the configured flag so the next
    /// utterance reconnects + restarts the engine against the new default device.
    @MainActor
    private func handleEngineConfigurationChange() {
        engineConfigured = false
        streamingSession?.cancel()
        streamingSession = nil
        finishPlayback()
        speakingState.end()
    }

    public var isAvailable: Bool {
        true
    }

    public func speak(_ utterance: SpeechUtterance) async {
        // A new utterance interrupts any in-flight one, and the entry gate below
        // guarantees the interrupt happens BEFORE the successor touches the shared
        // synthesizer — so two concurrent speak()s can no longer start overlapping
        // renders (the #52 review residual; see the "Entry serialisation" MARK).
        let entry = await claimEntry()
        await entryGate.run { [self] in
            await runRender(entry) { await self.renderText(utterance, since: entry.stopEpoch) }
        }
    }

    /// The offline-render → timeline → streamed-playback pipeline for the Apple
    /// (and Kokoro-fallback) voice. Runs INSIDE the entry gate, so it never
    /// overlaps another render on the single AVSpeechSynthesizer.
    private func renderText(_ utterance: SpeechUtterance, since epoch: Int) async {
        do {
            let (samples, sampleRate, wordOnsets) = try await synthesizeToFloats(utterance)
            // A stop that landed while we were rendering SILENTLY means this audio
            // must never be heard. Until 2026-08-12 the only thing standing between
            // a mid-synthesis stop and the full utterance playing was
            // `stopSpeaking(at: .immediate)` cancelling the offline render — and
            // under load it doesn't: measured, a stop 900ms in took 6.1s to unwind
            // because the render finished and then played. Kev heard it before any
            // assertion did ("it goes right to the end"). The bookkeeping was all
            // correct — one ended event, isSpeaking false — while the room was
            // still being talked at.
            guard await stillCurrent(epoch) else { return }
            guard !samples.isEmpty, sampleRate > 0 else {
                await plainSpeak(utterance)
                return
            }
            // Word onsets recorded during the offline render (the delegate fires
            // interleaved with buffer delivery — probe-verified; the marker-callback
            // API delivers nothing on system voices) give the Apple path an exact
            // timeline through the same streaming/clock machinery Kokoro uses.
            let timeline = AppleWordTiming.timeline(
                text: utterance.text,
                onsets: wordOnsets,
                totalSamples: samples.count,
                sampleRate: sampleRate
            )
            let chunk = TimedPCMChunk(samples: samples, timeline: timeline)
            // renderStream, NOT the gated speak(stream:): we're already inside the
            // gate (via runRender), so the public gated entry would self-deadlock
            // waiting on our own predecessor task.
            let spoke = await renderStream(stream: .single(chunk), sampleRate: sampleRate)
            if !spoke { await plainSpeak(utterance) }
        } catch is CancellationError {
            // A barge-in/stop cancelled the offline render mid-flight (SynthBox's
            // didCancel). Cancellation is NOT a failure — end silently rather than
            // re-speaking the just-stopped utterance in the plain voice (the
            // fallback-never-silent doctrine is about genuine failures).
            return
        } catch {
            await plainSpeak(utterance)
        }
    }

    // MARK: - Entry serialisation

    // A single AVSpeechSynthesizer with ONE shared delegate backs every render, and
    // AppEnvironment.speak() does not serialise its callers. Two speak() calls that
    // BOTH observed an idle provider used to start two overlapping renders — the
    // loser's SynthBox was never the synthesizer's delegate, so its terminal
    // delegate callback landed on the winner's box (ignored by the owner guard) and
    // its continuation LEAKED, hanging every awaiter (the MCP speak HTTP call, the
    // voice loop). `entryGate` fixes it: renders run strictly one-at-a-time, a newer
    // speak() interrupts the running one (barge-in), and a speak() superseded while
    // queued bails on the generation check — latest-wins, identity guard intact.
    // Because the loser's synthesizeToFloats is now DEFERRED until the predecessor
    // unwinds, the predecessor's box is still the delegate when its didCancel
    // arrives, so the continuation resolves instead of leaking.

    /// Bump the generation token and interrupt any render already in flight — its
    /// audible playback OR its still-silent synthesis window (which `isSpeaking()`
    /// can't see) — so it unwinds and frees the gate. Returns this entry's token.
    /// Internal so the streaming entry point (in +Streaming.swift) shares it.
    ///
    /// The bump and the "is a render already active?" sample happen in ONE MainActor
    /// hop. Done as two hops, an older caller could bump, suspend, let a NEWER caller
    /// start rendering, then resume, observe "busy", and stop() that newer render —
    /// breaking "latest wins" and dropping BOTH utterances (two genuinely concurrent
    /// callers exist: the MCP speak endpoint and the voice loop). Sampled atomically
    /// with the bump, `wasBusy` is true only for a render already in flight when we
    /// claimed our generation — i.e. strictly older than us, so superseding it is
    /// correct. (Busy = audible playback OR a render mid-pipeline, covering the
    /// offline-synth window before `fireSpeakingStarted` that `isSpeaking()` alone
    /// can't see.)
    ///
    /// Residual, verify-by-launch: `stop()` still runs after a suspension, so a tight
    /// 3-way interleaving — an older render finishing and a newer one starting between
    /// our sample and our `stop()` — could still clip a newer render. Far narrower
    /// than the 2-way race above; a fully airtight fix needs a generation-guarded
    /// stop, deferred to keep this change small.
    func claimEntry() async -> RenderEntry {
        let (generation, wasBusy) = await MainActor.run { () -> (Int, Bool) in
            speakGeneration += 1
            let busy = speakingState.isSpeaking(streamingActive: streamingSession != nil) || renderInFlight
            return (speakGeneration, busy)
        }
        if wasBusy { await stop() }
        // Epoch sampled AFTER the barge-in stop above, so this entry doesn't read
        // its own interrupt of its predecessor as a reason to cancel itself — but
        // BEFORE the gate wait, which is exactly the window a user's stop can land
        // in while this render is still queued behind another.
        let epoch = await MainActor.run { stopEpoch }
        return RenderEntry(generation: generation, stopEpoch: epoch)
    }

    /// Run one render under the gate. Bails if a newer speak() superseded this entry
    /// while it waited (latest-wins). Marks `renderInFlight` for the whole pipeline
    /// so a concurrent barge-in can see — and interrupt — the synthesis window too,
    /// not just audible playback. Internal so the streaming entry point reuses it.
    func runRender(_ entry: RenderEntry, _ render: () async -> Void) async {
        let proceed = await MainActor.run { () -> Bool in
            // Two ways to be stale by the time the gate is ours: a NEWER speak
            // superseded us (latest-wins), or a stop() landed while we queued.
            // The second used to fall through — stop() only ever interrupted the
            // render that was already running, so a queued utterance sailed past
            // it and spoke.
            guard entry.generation == speakGeneration, stillCurrent(entry.stopEpoch) else { return false }
            renderInFlight = true
            return true
        }
        guard proceed else { return }
        await render()
        await MainActor.run { renderInFlight = false }
    }

    /// Play externally-synthesized mono PCM (e.g. Kokoro's neural audio) through the
    /// same effect chain + engine + lifecycle callbacks as `speak(_:)`. Lets a neural
    /// provider reuse this hardened playback path instead of re-implementing AVAudioEngine.
    ///
    /// `play()` owns ALL lifecycle signalling — it fires `onSpeakingStarted` before
    /// scheduling and `onSpeakingEnded` as it unwinds, and `isSpeaking()` is computed
    /// from `player.isPlaying` — so the neural path drives the avatar mouth + speaking
    /// state identically to `speak(_:)`. No callback is bypassed.
    public func speak(rawPCM samples: [Float], sampleRate: Double) async {
        let entry = await claimEntry()
        await entryGate.run { [self] in
            await runRender(entry) { await self.renderPCM(samples, sampleRate: sampleRate) }
        }
    }

    /// Play pre-synthesised mono PCM through the effect chain + engine. Runs INSIDE
    /// the entry gate (same as `renderText`), so neural playback and an Apple render
    /// can't drive the engine concurrently.
    private func renderPCM(_ samples: [Float], sampleRate: Double) async {
        guard !samples.isEmpty, sampleRate > 0 else { return }
        do {
            let processed = chain.process(samples, sampleRate: sampleRate)
            try await play(processed, sampleRate: sampleRate)
        } catch {
            // Playback (engine/buffer) failed — there's no text to re-speak here, so
            // this one utterance is dropped. The caller chooses neural-vs-Apple upstream.
        }
    }

    /// Whether no `stop()` has landed since `epoch` was sampled — i.e. whether the
    /// audio a render just produced is still wanted. Cheap MainActor read.
    @MainActor
    private func stillCurrent(_ epoch: Int) -> Bool {
        stopEpoch == epoch
    }

    public func stop() async {
        let wasActive = await isSpeaking()
        let hadPlayback = await MainActor.run { () -> Bool in
            // Bump FIRST: a render suspended inside synthesis resumes into
            // `stillCurrent` and must see this stop however late it lands.
            stopEpoch += 1
            player.stop()
            _ = synthesizer.stopSpeaking(at: .immediate)
            // Resume any playback wait — .dataPlayedBack won't fire after stop().
            let had = playbackContinuation != nil || streamingSession != nil
            streamingSession?.cancel()
            streamingSession = nil
            finishPlayback()
            // Clear the cached flag NOW so isSpeaking() reads false the instant
            // stop() returns — the interrupted task's fireSpeakingEnded (which also
            // clears it, idempotently) may not unwind until a later actor hop.
            speakingState.end()
            return had
        }
        await plainFallback.stop()
        // When we cancelled active effectful playback, finishPlayback() (or the
        // session cancel) resumes the wait inside play()/speak(stream:), which fires
        // onSpeakingEnded as it unwinds — so fire here only when there was no
        // playback to resume (cancelled mid-synthesis), otherwise the avatar gets a
        // spurious second "ended" event.
        if wasActive, !hadPlayback { await MainActor.run { fireSpeakingEnded() } }
    }

    public func isSpeaking() async -> Bool {
        // Reads the cached flag, NOT the engine: player.isPlaying / synthesizer
        // .isSpeaking take an internal AVAudioEngine lock the render thread holds,
        // so polling them from a high-QoS caller inverts priority (the TPC hang
        // risk). A live streaming session still counts even before its first buffer
        // is scheduled (chunk 1 still synthesizing) — that term is a cheap nil check.
        await MainActor.run { speakingState.isSpeaking(streamingActive: streamingSession != nil) }
    }

    // Internal (not private) so EffectfulSpeechProvider+Streaming.swift can fire
    // them too — same reason `player`/`streamingSession` are internal.

    /// Flip the cached flag ON and fire onSpeakingStarted as one step, so the flag
    /// can never drift from the callback. Called at every playback-start seam.
    @MainActor
    func fireSpeakingStarted() {
        speakingState.begin()
        onSpeakingStarted?()
    }

    /// Flip the cached flag OFF and fire onSpeakingEnded as one step. Called at
    /// every playback-end seam (and, defensively, from stop()).
    @MainActor
    func fireSpeakingEnded() {
        speakingState.end()
        onSpeakingEnded?()
    }

    // MARK: - Synthesis → PCM

    // @MainActor: AVSpeechSynthesizer.write must be invoked on the main thread
    // (same contract as .speak), and building `spoken` here keeps it main-isolated.
    /// Mono PCM samples + their sample rate + word onsets (text range, sample offset)
    /// recorded from the willSpeakRange delegate during the offline render.
    private typealias PCM = ([Float], Double, [WordOnset])

    @MainActor
    private func synthesizeToFloats(_ utterance: SpeechUtterance) async throws -> PCM {
        let spoken = AVSpeechUtterance(string: utterance.text)
        spoken.rate = utterance.rate
        spoken.pitchMultiplier = utterance.pitch
        if let id = utterance.voiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: id)
        {
            spoken.voice = voice
        }

        let box = SynthBox(owner: spoken)
        synthesizer.delegate = box // weak; the write callbacks keep `box` alive
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PCM, Error>) in
            box.onDone = { continuation.resume(with: $0) }
            synthesizer.write(spoken) { buffer in
                box.ingest(buffer)
            }
        }
    }

    // MARK: - Playback

    @MainActor
    private func play(_ samples: [Float], sampleRate: Double) async throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else {
            throw EffectfulSpeechError.bufferAllocationFailed
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData {
            samples.withUnsafeBufferPointer { source in
                if let base = source.baseAddress {
                    channel[0].update(from: base, count: samples.count)
                }
            }
        }

        try configureEngineIfNeeded(format: format)

        fireSpeakingStarted()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            playbackContinuation = continuation
            player.scheduleBuffer(
                buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack
            ) { [weak self] _ in
                Task { @MainActor in self?.finishPlayback() }
            }
            player.play()
        }
        fireSpeakingEnded()
    }

    /// Resume the playback wait exactly once — from either the .dataPlayedBack
    /// completion (normal end) or stop() (cancelled). Halts the node either way:
    /// a drained AVAudioPlayerNode keeps "playing" forever otherwise, leaving
    /// isSpeaking() stuck true after the utterance.
    @MainActor
    private func finishPlayback() {
        player.stop()
        playbackContinuation?.resume()
        playbackContinuation = nil
    }

    @MainActor
    func configureEngineIfNeeded(format: AVAudioFormat) throws {
        // Reconnect when the sample rate changes (e.g. a different system voice) —
        // scheduling a buffer whose format mismatches the connection asserts.
        // Also require the engine to actually be RUNNING: it stops itself on an
        // output-route change (see handleEngineConfigurationChange) or a render
        // error, and scheduling onto a stopped engine plays silence forever.
        if engineConfigured, configuredSampleRate == format.sampleRate, engine.isRunning { return }
        if engineConfigured {
            player.stop()
            engine.disconnectNodeOutput(player)
        } else {
            engine.attach(player)
        }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        if !engine.isRunning { try engine.start() }
        engineConfigured = true
        configuredSampleRate = format.sampleRate
    }

    // MARK: - Fallback

    private func plainSpeak(_ utterance: SpeechUtterance) async {
        await MainActor.run { fireSpeakingStarted() }
        await plainFallback.speak(utterance)
        await MainActor.run { fireSpeakingEnded() }
    }
}

enum EffectfulSpeechError: Error {
    case bufferAllocationFailed
}

/// A word onset captured during the offline render: where the word sits in the
/// utterance text (UTF-16, from the delegate's NSRange) and how many samples had
/// been rendered when the synthesizer announced it — i.e. the word's start offset.
struct WordOnset: Equatable {
    let textRange: Range<Int>
    let sampleOffset: Int
}

/// Accumulates the synthesizer's PCM chunks (float / int16 / int32) into one mono
/// Float buffer and resumes exactly once when the final (empty) buffer arrives.
/// Also records `willSpeakRangeOfSpeechString` onsets against the samples rendered
/// so far — the delegate interleaves with buffer delivery during `write`
/// (probe-verified), which is how the Apple path gets word timing (the
/// marker-callback API delivers nothing on system voices).
///
/// `@unchecked Sendable` safety: `onDone` is written once on the main actor (inside
/// `synthesizeToFloats`) *before* `synthesizer.write` can deliver any callback, so
/// that write happens-before every read in `finish()`. `samples`/`sampleRate`/`done`/
/// `wordOnsets` are all `lock`-guarded, and the `done` flag guarantees `finish()`
/// resumes the continuation at most once even though `write` callbacks arrive on a
/// background thread.
/// `internal` (not `private`) so M1K3VoiceTests can pin the exactly-once
/// resume contract directly — the delegate cancel/finish backstops below are
/// verify-by-launch to WIRE (a real cancelled AVSpeechSynthesizer render), but
/// the exactly-once guarantee they rely on is pure and unit-tested.
final class SynthBox: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var sampleRate: Double = 0
    private var done = false
    private var wordOnsets: [WordOnset] = []
    var onDone: ((Result<([Float], Double, [WordOnset]), Error>) -> Void)?

    /// The utterance THIS box is rendering. `AVSpeechSynthesizer.delegate` is a
    /// single shared property, and each `synthesizeToFloats` call reassigns it to
    /// a fresh box — so on a barge-in (stop utterance A, start utterance B) a
    /// straggling didFinish/didCancel for A can be delivered AFTER the delegate
    /// already points at B's box. Every delegate callback carries the utterance
    /// it's about, so we guard `utterance === owner` and ignore foreign events —
    /// otherwise A's stale cancel would resume B's continuation with a spurious
    /// CancellationError and silence B entirely. (`ingest` needs no such guard:
    /// it's driven by `write`'s per-call completion closure, which captures its
    /// own box directly rather than routing through the shared delegate.)
    private let owner: AVSpeechUtterance

    init(owner: AVSpeechUtterance) {
        self.owner = owner
        super.init()
    }

    func speechSynthesizer(
        _: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        guard utterance === owner else { return }
        lock.withLock {
            let range = characterRange.location ..< characterRange.location + characterRange.length
            wordOnsets.append(WordOnset(textRange: range, sampleOffset: samples.count))
        }
    }

    /// Success backstop. `write`'s zero-frame sentinel (`ingest`) normally
    /// resumes first; if it never arrives (some voices don't emit it), this
    /// delegate callback still completes the continuation. Idempotent via the
    /// `done` flag, so the common case where the sentinel won already ran is a
    /// harmless no-op. Guarded on `owner` so a stale finish for a superseded
    /// utterance can't complete THIS box's render.
    func speechSynthesizer(_: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard utterance === owner else { return }
        finish()
    }

    /// Cancel path — the fix for the leaked continuation. `stop()` calls
    /// `synthesizer.stopSpeaking(at:.immediate)` mid-render; the zero-frame
    /// sentinel then never arrives, so without this the continuation (and every
    /// caller awaiting `speak`) would suspend forever. Resume exactly once with
    /// `CancellationError` — NOT the partial samples (would play audio the user
    /// just stopped) and NOT a generic error (would trigger the plain-voice
    /// re-speak fallback). `speak(_:)` swallows the CancellationError silently.
    /// Guarded on `owner` so a barge-in's cancel for the PREVIOUS utterance can't
    /// silence the successor (see the `owner` doc).
    func speechSynthesizer(_: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard utterance === owner else { return }
        cancel()
    }

    func ingest(_ buffer: AVAudioBuffer) {
        // Already resumed (a didFinish/didCancel raced ahead of the real terminal
        // buffer): drop trailing audio rather than grow a payload nobody reads.
        if lock.withLock({ done }) { return }
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        let frames = Int(pcm.frameLength)
        if frames == 0 {
            finish()
            return
        }
        var chunk = [Float](repeating: 0, count: frames)
        if let floatData = pcm.floatChannelData {
            for index in 0 ..< frames {
                chunk[index] = floatData[0][index]
            }
        } else if let int16Data = pcm.int16ChannelData {
            for index in 0 ..< frames {
                chunk[index] = Float(int16Data[0][index]) / 32768
            }
        } else if let int32Data = pcm.int32ChannelData {
            for index in 0 ..< frames {
                chunk[index] = Float(int32Data[0][index]) / Float(Int32.max)
            }
        }
        lock.withLock {
            sampleRate = pcm.format.sampleRate
            samples.append(contentsOf: chunk)
        }
    }

    private func finish() {
        let payload: ([Float], Double, [WordOnset])? = lock.withLock {
            guard !done else { return nil }
            done = true
            return (samples, sampleRate, wordOnsets)
        }
        guard let payload else { return }
        onDone?(.success(payload))
    }

    /// Resume exactly once with a cancellation, sharing `finish`'s `done` guard
    /// so cancel-then-late-sentinel (or a double cancel) is a no-op.
    private func cancel() {
        let shouldResume = lock.withLock {
            guard !done else { return false }
            done = true
            return true
        }
        guard shouldResume else { return }
        onDone?(.failure(CancellationError()))
    }
}

/// Serial FIFO gate: `run` executes each body strictly one-at-a-time, in call
/// order, so EffectfulSpeechProvider's renders never overlap on the single shared
/// AVSpeechSynthesizer (whose delegate is one reassignable property). Deadlock-free
/// by construction — a body's only cross-entry dependency is `stop()`, which never
/// routes through the gate, so a running body can always be interrupted and release
/// the gate for the next entrant. The tail chain is dropped once no run is in
/// flight, so finished tasks aren't retained across an idle provider.
///
/// `internal` (not `private`) so SpeechEntryGateTests can pin the no-overlap
/// contract headlessly — the property the whole fix rests on, testable without
/// any audio device.
actor SpeechEntryGate {
    private var tail: Task<Void, Never>?
    private var active = 0

    func run(_ body: @Sendable @escaping () async -> Void) async {
        active += 1
        let previous = tail
        let task = Task {
            await previous?.value
            await body()
        }
        tail = task
        await task.value
        active -= 1
        if active == 0 { tail = nil }
    }
}
