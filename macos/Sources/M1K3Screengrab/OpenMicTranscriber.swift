//
//  OpenMicTranscriber.swift
//  M1K3Screengrab
//
//  A recogniser for the plates: the mic "opens" without AVAudioEngine, TCC, or
//  a speech model, and stays open until stopped — so the voice loop sits in
//  `.listening` for as long as the shot needs. The listening plate gets the hero
//  question as a growing partial (never final: a final would submit the turn
//  and the frame would move on to thinking/speaking).
//
//  Signed: Kev + claude-fable-5.1, 2026-09-08, Confidence 0.85 (pure; pinned
//  by OpenMicTranscriberTests), Prior: Unknown
//

import Foundation
import M1K3Voice

public final class OpenMicTranscriber: TranscriptionProvider, @unchecked Sendable {
    public let name = "screengrab-open-mic"
    public var isAvailable: Bool {
        true
    }

    private let partial: String?
    private let wordDelay: Duration
    private let submits: Bool
    // `@unchecked Sendable`: the continuation is the only mutable member and
    // every access is under `lock`.
    private let lock = NSLock()
    private var continuation: AsyncStream<TranscriptSegment>.Continuation?
    private var feeder: Task<Void, Never>?

    /// One word per 0.8 s — inside the endpointer's 2.5 s silence window; a
    /// non-submitting mic keeps dictating, the partial only ever growing.
    /// `submits`: after the words, the whole sentence lands as ONE final
    /// segment and the mic goes quiet — the loop's endpointer then takes the
    /// turn (the speaking plate).
    public init(partial: String?, wordDelay: Duration = .milliseconds(800), submits: Bool = false) {
        self.partial = partial
        self.wordDelay = wordDelay
        self.submits = submits
    }

    public func startListening() throws -> AsyncStream<TranscriptSegment> {
        stopListening()
        let (stream, continuation) = AsyncStream.makeStream(of: TranscriptSegment.self)
        let words = partial?.split(separator: " ").map(String.init) ?? []
        let delay = wordDelay, submits = submits
        let feeder = Task {
            var text = ""
            // A non-submitting mic dictates the sentence over and over: the
            // endpointer's silence window never opens, so the loop stays in
            // `.listening` for as long as the shot needs.
            // A non-submitting mic never stops: the words cycle and the partial
            // only ever GROWS. A partial re-sent unchanged reads as silence to
            // the endpointer (it submitted the turn); a restart lands the shot
            // on a one-word bubble. The bubble shows its first lines, so the
            // opening stays sensible however long the dictation runs.
            var index = 0
            while !Task.isCancelled, !words.isEmpty {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                let word = words[index % words.count]
                text = text.isEmpty ? word : text + " " + word
                continuation.yield(TranscriptSegment(text: text, isFinal: false))
                index += 1
                if submits, index == words.count { break }
            }
            if submits, !text.isEmpty {
                continuation.yield(TranscriptSegment(text: text, isFinal: true, confidence: 1))
            }
        }
        lock.withLock {
            self.continuation = continuation
            self.feeder = feeder
        }
        return stream
    }

    public func stopListening() {
        lock.withLock {
            feeder?.cancel()
            feeder = nil
            continuation?.finish()
            continuation = nil
        }
    }
}
