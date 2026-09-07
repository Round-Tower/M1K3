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
    // `@unchecked Sendable`: the continuation is the only mutable member and
    // every access is under `lock`.
    private let lock = NSLock()
    private var continuation: AsyncStream<TranscriptSegment>.Continuation?
    private var feeder: Task<Void, Never>?

    public init(partial: String?, wordDelay: Duration = .milliseconds(450)) {
        self.partial = partial
        self.wordDelay = wordDelay
    }

    public func startListening() throws -> AsyncStream<TranscriptSegment> {
        stopListening()
        let (stream, continuation) = AsyncStream.makeStream(of: TranscriptSegment.self)
        let words = partial?.split(separator: " ").map(String.init) ?? []
        let delay = wordDelay
        let feeder = Task {
            var text = ""
            for word in words {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                text = text.isEmpty ? word : text + " " + word
                continuation.yield(TranscriptSegment(text: text, isFinal: false))
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
