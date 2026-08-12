//
//  EffectfulSpeechProvider+Streaming.swift
//  M1K3Voice
//
//  Chunked playback with word timing: PCM chunks (Kokoro sentences, or the
//  Apple render as one chunk) are scheduled progressively onto the ONE player
//  session, so speech starts after the first sentence instead of the whole
//  answer. Each chunk's timeline anchors into a global utterance timeline at
//  schedule time (UtteranceTimelineAccumulator — estimation drift resets at
//  every chunk join), and a ~33 ms clock polls the player's sample position,
//  firing onWordSpoken only on word CHANGE (~3 events/s reach the UI).
//
//  The timeline maths is pure + unit-tested; this file is the thin
//  AVFoundation glue around it — verify-by-launch, per the main file's rule.
//
//  Signed: Kev + claude-fable-5, 2026-06-11, Confidence 0.7 (probe-verified
//  playerTime semantics; scheduling/cancel paths verify-at-⌘R). Prior:
//  Kev + claude-sonnet-4-6 (EffectfulSpeechProvider.swift).
//

import AVFoundation
import Foundation

/// One piece of an utterance's audio plus (optionally) its word timing.
/// `timeline` times are relative to the CHUNK's start; ranges index the full
/// utterance text.
public struct TimedPCMChunk: Sendable {
    public let samples: [Float]
    public let timeline: SpokenWordTimeline?

    public init(samples: [Float], timeline: SpokenWordTimeline?) {
        self.samples = samples
        self.timeline = timeline
    }
}

public extension AsyncThrowingStream where Element == TimedPCMChunk, Failure == Error {
    /// A finished one-chunk stream — the degenerate case for pre-rendered audio.
    static func single(_ chunk: TimedPCMChunk) -> Self {
        AsyncThrowingStream { continuation in
            continuation.yield(chunk)
            continuation.finish()
        }
    }
}

/// Builds the Apple path's exact timeline from offline-render word onsets:
/// each word runs from its onset to the next word's onset (the last to the end
/// of the audio).
enum AppleWordTiming {
    static func timeline(
        text: String,
        onsets: [WordOnset],
        totalSamples: Int,
        sampleRate: Double
    ) -> SpokenWordTimeline {
        let totalDuration = Double(totalSamples) / sampleRate
        let words = onsets.enumerated().map { index, onset -> SpokenWord in
            let start = Double(onset.sampleOffset) / sampleRate
            let end = index + 1 < onsets.count
                ? Double(onsets[index + 1].sampleOffset) / sampleRate
                : totalDuration
            return SpokenWord(textRange: onset.textRange, start: start, duration: max(end - start, 0))
        }
        return SpokenWordTimeline(text: text, words: words, totalDuration: totalDuration)
    }
}

public extension EffectfulSpeechProvider {
    /// Play a stream of PCM chunks as ONE utterance through the effect chain:
    /// buffers schedule as chunks arrive, lifecycle fires once at each end, word
    /// timing flows out through `onTimelineReady`/`onWordSpoken`. Returns `false`
    /// when no audio was ever scheduled (the caller should fall back).
    ///
    /// This is the public, GATED entry point — the Kokoro / "M1K3 Voice" tier calls
    /// it directly (`KokoroSpeechProvider.synthesize`), so it MUST honour the same
    /// one-render-at-a-time invariant as `speak(_:)`/`speak(rawPCM:)`. It claims an
    /// entry generation and runs `renderStream` through `entryGate`, so a stream can
    /// never overlap another render on the shared `player`/`streamingSession`, and a
    /// stream superseded while queued bails via the generation guard. (Before this,
    /// the highest-traffic voice path bypassed the #52 gate entirely.)
    @discardableResult
    func speak(stream: AsyncThrowingStream<TimedPCMChunk, Error>, sampleRate: Double) async -> Bool {
        let entry = await claimEntry()
        // Default TRUE = "handled, don't fall back". `runRender` bails WITHOUT running
        // the closure when this entry was superseded (a newer speak() bumped the
        // generation, or a stop() landed, while we queued behind the gate) — leaving `spoke` at its
        // default. The caller (KokoroSpeechProvider.synthesize) reads a `false` return
        // as "nothing synthesised → speak it in the Apple voice"; falling back for an
        // utterance we DELIBERATELY abandoned would re-speak stale text and stop() the
        // newer render — the #52 barge-in bug, via the gate's own early-return. Only a
        // render that actually ran and scheduled nothing sets this false.
        let outcome = StreamOutcome(spoke: true)
        await entryGate.run { [self] in
            await runRender(entry) {
                outcome.spoke = await self.renderStream(stream: stream, sampleRate: sampleRate)
            }
        }
        return outcome.spoke
    }
}

extension EffectfulSpeechProvider {
    /// The un-gated streaming worker: schedule PCM chunks onto the one player
    /// session with word timing. A mid-stream synthesis error ends gracefully —
    /// whatever is scheduled finishes playing; returns `false` when nothing was
    /// scheduled (lifecycle stays silent then).
    ///
    /// Internal, not the gated `speak(stream:)`: `renderText` (the Apple path) is
    /// ALREADY running inside the gate via `runRender`, so it calls this directly —
    /// routing it back through the gated entry would self-deadlock on its own
    /// predecessor task. External callers must use `speak(stream:)`.
    @MainActor
    @discardableResult
    func renderStream(stream: AsyncThrowingStream<TimedPCMChunk, Error>, sampleRate: Double) async -> Bool {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        ) else { return false }

        let session = StreamingPlaybackSession(
            player: player,
            sampleRate: sampleRate,
            onTimeline: { [weak self] in self?.onTimelineReady?($0) },
            onWord: { [weak self] in self?.onWordSpoken?($0) }
        )
        streamingSession = session

        var started = false
        do {
            for try await chunk in stream {
                guard !session.isCancelled else { break }
                guard !chunk.samples.isEmpty else { continue }
                let processed = chain.process(chunk.samples, sampleRate: sampleRate)
                do { try configureEngineIfNeeded(format: format) } catch { break }
                if !started {
                    started = true
                    fireSpeakingStarted()
                }
                session.schedule(samples: processed, timeline: chunk.timeline, format: format)
                player.play() // no-op while already playing; restarts after engine reconfig
            }
        } catch {
            // Synthesis failed mid-utterance — keep what's already scheduled.
        }
        session.markStreamEnded()
        if started { await session.awaitCompletion() }
        if streamingSession === session { streamingSession = nil }
        if started { fireSpeakingEnded() }
        return started
    }
}

/// A Sendable box to carry `renderStream`'s Bool out of the `@Sendable` gate
/// closure (which can't capture a mutable local). The gate serialises access and
/// `speak(stream:)` reads it only after `entryGate.run` returns, so the plain
/// `var` is safe — hence `@unchecked Sendable`. Seeded `true` by the caller so a
/// superseded entry (whose render closure never runs) reports "don't fall back";
/// see `speak(stream:)`.
private final class StreamOutcome: @unchecked Sendable {
    var spoke: Bool
    init(spoke: Bool) {
        self.spoke = spoke
    }
}

/// Per-utterance state for one chunked playback: pending-buffer accounting, the
/// growing global timeline, and the word clock. Main-actor-only — every
/// mutation (schedule, buffer completion, cancel, clock tick) hops here, so no
/// locks. Created by speak(stream:); cancelled by stop().
@MainActor
final class StreamingPlaybackSession {
    private let player: AVAudioPlayerNode
    private let sampleRate: Double
    private let onTimeline: (SpokenWordTimeline) -> Void
    private let onWord: (Range<Int>) -> Void

    private var accumulator: UtteranceTimelineAccumulator?
    private var pendingBuffers = 0
    private var streamEnded = false
    private var completion: CheckedContinuation<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var lastWordIndex: Int?
    private(set) var isCancelled = false

    init(
        player: AVAudioPlayerNode,
        sampleRate: Double,
        onTimeline: @escaping (SpokenWordTimeline) -> Void,
        onWord: @escaping (Range<Int>) -> Void
    ) {
        self.player = player
        self.sampleRate = sampleRate
        self.onTimeline = onTimeline
        self.onWord = onWord
    }

    func schedule(samples: [Float], timeline: SpokenWordTimeline?, format: AVAudioFormat) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData {
            samples.withUnsafeBufferPointer { source in
                if let base = source.baseAddress {
                    channel[0].update(from: base, count: samples.count)
                }
            }
        }

        if let timeline {
            // Anchor at schedule time: back-to-back chunks queue at the scheduled
            // boundary; after a dry gap the player's clock has run on, so the
            // accumulator re-anchors at NOW (probe-verified player behavior).
            var anchored = accumulator ?? UtteranceTimelineAccumulator(text: timeline.text, sampleRate: sampleRate)
            anchored.append(chunk: timeline, sampleCount: samples.count, playerSampleNow: playerSampleNow())
            accumulator = anchored
            onTimeline(anchored.global)
        }

        pendingBuffers += 1
        player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.bufferCompleted() }
        }
        startClockIfNeeded()
    }

    func markStreamEnded() {
        streamEnded = true
        finishIfDone()
    }

    /// Suspends until the last buffer plays back (or the session is cancelled).
    func awaitCompletion() async {
        if isCancelled || (streamEnded && pendingBuffers == 0) { return }
        await withCheckedContinuation { completion = $0 }
    }

    /// From stop(): buffers are killed (their .dataPlayedBack never fires after
    /// player.stop()), so resume the wait directly.
    func cancel() {
        isCancelled = true
        complete()
    }

    private func bufferCompleted() {
        pendingBuffers -= 1
        // `== 0` (not `<= 0`) everywhere so an extra completion callback
        // can't be masked — surface the imbalance in debug builds instead.
        assert(pendingBuffers >= 0, "buffer completions exceeded schedules")
        finishIfDone()
    }

    private func finishIfDone() {
        guard streamEnded, pendingBuffers == 0 else { return }
        complete()
    }

    private func complete() {
        // Halt the node: a drained player otherwise keeps "playing" forever
        // (probe-verified), leaving isSpeaking() stuck true — the next speak()
        // would fire a spurious ended event and inherit a stale clock. At
        // natural completion nothing is queued; after stop() this is a no-op.
        // Deferred off this call's priority: complete() can run on a high-QoS
        // caller (a user-triggered stop()), and AVAudioPlayerNode.stop() takes
        // an internal engine lock the audio render thread also touches — a
        // direct call here is a priority-inversion hang risk. Nothing below
        // depends on the stop completing first.
        let node = player
        Task(priority: .utility) { @MainActor in node.stop() }
        clockTask?.cancel()
        clockTask = nil
        // Consume the continuation: a buffer callback already in flight when
        // cancel() resumed us must find nil here, not a second resume (a
        // CheckedContinuation traps on double-resume).
        completion?.resume()
        completion = nil
    }

    // MARK: - Word clock

    private func startClockIfNeeded() {
        guard clockTask == nil else { return }
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func tick() {
        guard let accumulator, let sample = playerSampleNow() else { return }
        // playerTime can read slightly negative right after play() — clamp.
        let seconds = Double(max(sample, 0)) / sampleRate
        guard let index = accumulator.global.wordIndex(at: seconds), index != lastWordIndex else { return }
        lastWordIndex = index
        onWord(accumulator.global.words[index].textRange)
    }

    private func playerSampleNow() -> Int64? {
        guard player.isPlaying,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime)
        else { return nil }
        return playerTime.sampleTime
    }
}
