//
//  AnalyzerRecognitionPolicy.swift
//  M1K3Voice
//
//  The pure half of AppleSpeechTranscriber's SpeechAnalyzer path. SFSpeech gave
//  one cumulative transcription per recognition task and declared `isFinal`
//  when ITS silence window closed. SpeechAnalyzer gives results per time range
//  and finalises a range at pauses as short as 0.3 s (measured 2026-09-26,
//  scratch/speechanalyzer-spike/live_probe.swift: "Marta, can you review" was
//  finalised mid-sentence). Fed to the consumer raw, chat dictation would
//  auto-submit half a sentence. So:
//
//  - `AnalyzerTranscriptFold` keeps each FinalityPolicy's contract. Dictation
//    (`endsListen`) gets cumulative partials and ONE final at the end, exactly
//    what SFSpeech produced. Voice-first (`keepsListening`) gets each finalised
//    range as its own final segment, which is what SFSpeech plus the mid-listen
//    restart produced, and what TranscriptAccumulator commits.
//  - `AnalyzerEndpoint` decides when the transcriber ends a listen itself: in
//    dictation, a final followed by real quiet at the mic (or a long quiet
//    after words, if no final lands); in either mode, a listen with no words
//    after the silent-listen limit, which keeps the consumer's empty-listen
//    parking. Once there are words, voice-first's own endpointer owns the turn.
//
//  Signed: Kev + claude-opus-5-5, 2026-09-26, Confidence 0.75 (pure and pinned;
//  the thresholds are starting points from one synthetic probe, and the level
//  floor after voice processing is verify-by-launch). Prior: Unknown.
//

import Foundation

public struct AnalyzerTranscriptFold: Sendable {
    private let finality: FinalityPolicy
    private var committed = ""
    private var volatile = ""

    public init(finality: FinalityPolicy) {
        self.finality = finality
    }

    public var hasText: Bool {
        !committed.isEmpty || !volatile.isEmpty
    }

    /// One analyzer result in, at most one segment out.
    public mutating func ingest(text raw: String, isFinal: Bool) -> TranscriptSegment? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        switch finality {
        case .keepsListening:
            return TranscriptSegment(text: text, isFinal: isFinal)
        case .endsListen:
            if isFinal {
                committed = Self.join(committed, text)
                volatile = ""
            } else {
                volatile = text
            }
            return TranscriptSegment(text: Self.join(committed, volatile), isFinal: false)
        }
    }

    /// The one final a dictation listen ends on; nil in voice-first, where the
    /// consumer owns the boundary, or when nothing was said.
    public func closingSegment() -> TranscriptSegment? {
        guard finality == .endsListen, hasText else { return nil }
        return TranscriptSegment(text: Self.join(committed, volatile), isFinal: true)
    }

    private static func join(_ head: String, _ tail: String) -> String {
        head.isEmpty ? tail : tail.isEmpty ? head : head + " " + tail
    }
}

public struct AnalyzerEndpoint: Sendable {
    /// Linear RMS below which the mic counts as quiet (about -50 dBFS).
    public static let quietLevel: Float = 0.003
    /// Quiet after a final that ends a dictation listen.
    public static let quietAfterFinal: Double = 1.2
    /// Quiet after words that ends a dictation listen with no final.
    public static let quietWithoutFinal: Double = 3.0
    /// A listen that has heard no words by now ends (empty-listen parking).
    public static let silentListenLimit: Double = 8.0

    private let finality: FinalityPolicy
    private var elapsed: Double = 0
    private var quietRun: Double = 0
    private var hasText = false
    private var lastWasFinal = false

    public init(finality: FinalityPolicy) {
        self.finality = finality
    }

    public mutating func audio(rms: Float, seconds: Double) {
        elapsed += seconds
        quietRun = rms < Self.quietLevel ? quietRun + seconds : 0
    }

    public mutating func result(isFinal: Bool, hasText: Bool) {
        if hasText { self.hasText = true }
        lastWasFinal = isFinal
    }

    public var shouldEnd: Bool {
        guard hasText else { return elapsed >= Self.silentListenLimit }
        switch finality {
        case .keepsListening:
            return false
        case .endsListen:
            return (lastWasFinal && quietRun >= Self.quietAfterFinal) || quietRun >= Self.quietWithoutFinal
        }
    }

    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(samples.count)).squareRoot()
    }
}

/// Whether AppleSpeechTranscriber can listen. The analyzer's locale/asset check
/// is async, so the transcriber caches it; until it lands (nil), only SFSpeech's
/// own synchronous check can say yes (PR #412 review).
public enum AppleSpeechAvailability {
    public static func isAvailable(analyzerServesLocale: Bool?, legacyAvailable: Bool) -> Bool {
        analyzerServesLocale == true || legacyAvailable
    }
}
