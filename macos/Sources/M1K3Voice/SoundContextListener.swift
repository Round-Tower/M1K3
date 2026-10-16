//
//  SoundContextListener.swift
//  M1K3Voice
//
//  SoundAnalysis glue for SoundContext: the built-in classifier (`.version1`,
//  1.5 s windows) over the same buffers a listen already feeds the transcriber,
//  each window's labels folded into a SoundContext. No new microphone use: it
//  hears only what a listen hears, and keeps only labels, never audio.
//
//  `analyze(file:)` runs a file through the same request for the eval
//  (SoundContextEvalTests). The live path is verify-by-launch, like the rest of
//  the recogniser glue; AppleSpeechTranscriber feeds it when `hearsRoom` is on.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-15, Confidence 0.7 (file path measured;
//  the stream path matches it but is unlaunched). Prior: Unknown.
//  Guards from the pre-push review: windows don't overlap, a stream compares by rate,
//  channels and sample format (not layout), pending buffers are capped, a reset drops
//  windows that began before it, and the caller marks the app's own playback.
//  Review: Kev + claude-opus-5-5, 2026-10-16 — wired: `SoundContextProviding` and `accepts(_:)` for
//  AppleSpeechTranscriber's tap. `noteOwnPlayback` has no caller yet: the verdict runs in shadow, and the
//  dial-up (the one long sound M1K3 plays) only plays during a brain download.

import AVFoundation
import Foundation
import os
import SoundAnalysis

/// A recogniser that also hears the room (AppleSpeechTranscriber with `hearsRoom` on).
/// WhisperKit can't: its engine is sealed inside the package.
public protocol SoundContextProviding: AnyObject {
    /// What the current (or last) listen heard; nil when nothing is listening for it.
    var soundContext: SoundContext? { get }
}

public final class SoundContextListener: @unchecked Sendable {
    private static let log = Logger(subsystem: "app.m1k3", category: "sound-context")
    static let windowSeconds = 1.5

    private let format: AVAudioFormat
    private let analyzer: SNAudioStreamAnalyzer
    private let observer = Observer()
    /// Serialises the analyzer: SNAudioStreamAnalyzer is not thread-safe.
    private let queue = DispatchQueue(label: "app.m1k3.sound-context")
    private var framePosition: AVAudioFramePosition = 0
    /// Buffers waiting on the queue (guarded by `pendingLock`): past `maxPending` the newest is
    /// dropped, so a stalled analyzer can't hoard a listen's audio in memory.
    private let pendingLock = NSLock()
    private var pending = 0
    private var warnedFormat = false
    private let maxPending: Int

    /// nil when the built-in classifier can't be built on this OS. `maxPending` (32, about 3 s
    /// of a tap's buffers) only rises for a feed faster than real time, like the eval's.
    public init?(format: AVAudioFormat, maxPending: Int = 32) {
        guard let request = try? Self.request() else { return nil }
        self.format = format
        self.maxPending = maxPending
        analyzer = SNAudioStreamAnalyzer(format: format)
        do {
            try analyzer.add(request, withObserver: observer)
        } catch {
            Self.log.error("sound context unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Feed one buffer from the listen's tap. Copied, because a tap reuses its buffers.
    public func append(_ buffer: AVAudioPCMBuffer) {
        guard Self.sameStream(buffer.format, format) else {
            // `==` also compares channel layouts, which a tap can differ on: compare the stream.
            let warn = pendingLock.withLock { defer { warnedFormat = true }; return !warnedFormat }
            if warn { Self.log.notice("sound context: buffer format differs from the analyzer's, skipping") }
            return
        }
        let admitted = pendingLock.withLock {
            guard pending < maxPending else { return false }
            pending += 1
            return true
        }
        guard admitted, let copy = Self.copy(buffer) else {
            if admitted { pendingLock.withLock { pending -= 1 } }
            return
        }
        // The copy is this call's alone and the queue is its only reader after this line.
        nonisolated(unsafe) let owned = copy
        queue.async { [self] in
            analyzer.analyze(owned, atAudioFramePosition: framePosition)
            framePosition += AVAudioFramePosition(owned.frameLength)
            pendingLock.withLock { pending -= 1 }
        }
    }

    /// What this listen has heard so far (the observer's lock; never waits on the analyzer).
    public var context: SoundContext {
        observer.context
    }

    /// A new listen: forget the last one's sounds. The stream keeps running (completing it
    /// would end the analyzer), so windows that began before the reset are ignored when they land.
    public func reset() {
        queue.sync { observer.reset(at: CMTime(value: framePosition, timescale: CMTimeScale(format.sampleRate))) }
    }

    /// Ends the stream and waits for its last windows: the eval's stream-path check. The
    /// listener takes no audio after this.
    func finish() {
        queue.sync { analyzer.completeAnalysis() }
    }

    /// M1K3 played audio during this listen: its music must not veto the user's turn.
    public func noteOwnPlayback() {
        observer.noteOwnPlayback()
    }

    /// Whether buffers in `other` can feed this listener (a route change can switch formats).
    func accepts(_ other: AVAudioFormat) -> Bool {
        Self.sameStream(other, format)
    }

    static func sameStream(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        a.sampleRate == b.sampleRate && a.channelCount == b.channelCount
            && a.commonFormat == b.commonFormat && a.isInterleaved == b.isInterleaved
    }

    /// A whole file through the same request, for the eval.
    public static func analyze(file url: URL) throws -> SoundContext {
        let analyzer = try SNAudioFileAnalyzer(url: url)
        let observer = Observer()
        try analyzer.add(request(), withObserver: observer)
        analyzer.analyze()
        return observer.context
    }

    private static func request() throws -> SNClassifySoundRequest {
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: windowSeconds, preferredTimescale: 48000)
        // No overlap: with the default 0.5 one short bark lands in two windows and passes
        // SoundContext's "two windows" persistence rule on its own.
        request.overlapFactor = 0
        return request
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, target) {
            guard let data = from.mData, let into = to.mData else { continue }
            memcpy(into, data, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }

    /// Each classification window becomes one SoundContext observation.
    private final class Observer: NSObject, SNResultsObserving, @unchecked Sendable {
        private let lock = NSLock()
        private var stored = SoundContext()
        private var resetAt = CMTime.zero

        var context: SoundContext {
            lock.withLock { stored }
        }

        func reset(at time: CMTime) {
            lock.withLock {
                stored.reset()
                resetAt = time
            }
        }

        func noteOwnPlayback() {
            lock.withLock { stored.noteOwnPlayback() }
        }

        func request(_: SNRequest, didProduce result: SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            // A window that began before the reset belongs to the last listen.
            if lock.withLock({ CMTimeCompare(result.timeRange.start, resetAt) < 0 }) { return }
            var window: [String: Double] = [:]
            // Speech is kept at any confidence: the verdict's floor is 0.1, well under the 0.3
            // that trims the rest of the 303 labels.
            for classification in result.classifications
                where classification.confidence >= 0.3 || classification.identifier == "speech"
            {
                window[classification.identifier] = classification.confidence
            }
            lock.withLock { stored.observe(window) }
        }

        func request(_: SNRequest, didFailWithError error: Error) {
            SoundContextListener.log.error("sound context failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
