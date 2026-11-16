//
//  VoicePolishPolicy.swift
//  M1K3Voice
//
//  The polish pass's pure layer (#852). The live captions stay on SpeechTranscriber's fast mode;
//  at the endpoint the utterance's own audio goes through the same analyzer in accurate mode (no
//  `.fastResults`: 8.9% WER against 10.7% on Kev's corpus, docs/evals/2026-10-15-stt.md) and its
//  text replaces the live final, IF the policy here says so. Apple's analyzer only: Whisper is an
//  optional download, so the pass never routes through it.
//
//  What lives here, all unit-tested:
//  - the argv switch, OFF by default: `M1K3 -voicePolishPass YES` (macOS 27: `defaults write`
//    never reaches the sandboxed app);
//  - `UtteranceRecorder`: the bounded, in-memory capture the mic tap feeds (never on disk);
//  - the decision: empty, failed, timed-out or implausible results keep the live text.
//
//  Signed: Kev + claude-opus-5-5, 2026-11-16, Confidence 0.75 (the policy is pinned by tests;
//  the capture and the endpoint timing on a device are verify-by-launch). Prior: Unknown.

import Foundation

/// One finished utterance's audio: mono float samples at the tap's rate, held in memory only.
public struct UtteranceAudio: Sendable, Equatable {
    public let samples: [Float]
    public let sampleRate: Double
    /// The capture hit its cap or changed rate: the audio is not the whole utterance.
    public let truncated: Bool

    public init(samples: [Float], sampleRate: Double, truncated: Bool) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.truncated = truncated
    }

    public var seconds: Double {
        sampleRate > 0 ? Double(samples.count) / sampleRate : 0
    }

    /// The samples followed by `trailingSilenceSeconds` of zeros. The recogniser drops the last
    /// words of audio that ends on speech; a live mic keeps feeding silence, a buffer must too.
    public func padded(trailingSilenceSeconds: Double) -> [Float] {
        let silent = max(0, Int((trailingSilenceSeconds * sampleRate).rounded()))
        return samples + [Float](repeating: 0, count: silent)
    }
}

/// A listen's audio, captured off the mic tap for the polish pass. Off until a shell opts in
/// (`isEnabled`), so a dictation or MCP listen holds nothing. Bounded: past `maxSeconds` the rest
/// is dropped and the audio reads `truncated`, so the pass is skipped rather than run on a
/// fragment. Its own lock; the tap calls it from the audio thread, outside every other lock.
public final class UtteranceRecorder: @unchecked Sendable {
    private let maxSamples: (Double) -> Int
    private let lock = NSLock()
    private var enabled = false
    private var samples: [Float] = []
    private var rate: Double = 0
    private var truncated = false

    public init(maxSeconds: Double = VoicePolishPolicy.maxCaptureSeconds) {
        maxSamples = { Int(maxSeconds * $0) }
    }

    public var isEnabled: Bool {
        get { lock.withLock { enabled } }
        set {
            lock.withLock {
                enabled = newValue
                if !newValue { clear() }
            }
        }
    }

    /// From the tap: mono float samples at `sampleRate`.
    public func append(_ buffer: UnsafeBufferPointer<Float>, sampleRate: Double) {
        lock.withLock {
            guard enabled, !truncated, !buffer.isEmpty, sampleRate > 0 else { return }
            if samples.isEmpty { rate = sampleRate }
            // Two rates in one listen (a route change): not one utterance's audio any more.
            guard sampleRate == rate else {
                truncated = true
                return
            }
            let room = maxSamples(rate) - samples.count
            if buffer.count > room {
                samples.append(contentsOf: buffer.prefix(max(0, room)))
                truncated = true
            } else {
                samples.append(contentsOf: buffer)
            }
        }
    }

    /// What this listen heard, once: the buffer starts over for the next.
    public func take() -> UtteranceAudio? {
        lock.withLock {
            defer { clear() }
            guard !samples.isEmpty else { return nil }
            return UtteranceAudio(samples: samples, sampleRate: rate, truncated: truncated)
        }
    }

    /// A new listen starts from nothing.
    public func reset() {
        lock.withLock { clear() }
    }

    private func clear() {
        samples = []
        rate = 0
        truncated = false
    }
}

/// A recogniser that also keeps the listen's audio for the polish pass (AppleSpeechTranscriber).
/// WhisperKit can't: its engine is sealed inside the package, and the pass is Apple-only anyway.
public protocol UtteranceAudioProviding: AnyObject {
    /// Whether listens keep their audio (off by default).
    var capturesUtteranceAudio: Bool { get set }
    /// The last listen's audio, once.
    func takeUtteranceAudio() -> UtteranceAudio?
}

public enum VoicePolishPolicy {
    /// The argv key: `M1K3 -voicePolishPass YES`.
    public static let key = "voicePolishPass"

    /// Off unless argv says so. The default stays off until a second real recording session shows
    /// accurate beating fast by 2 points (docs/evals/2026-11-16-polish-pass); that call is Kev's.
    public static func enabled(
        arguments: [String: Any] = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    ) -> Bool {
        guard let raw = arguments[key] as? String else { return false }
        return ["yes", "1", "true", "on"].contains(raw.lowercased())
    }

    /// The pass is given up on after this, and the live text stands. A file pass over an utterance
    /// measured 0.18 s with analyzer setup; five times that still reads as the same breath.
    public static let budgetSeconds = 1.0
    /// Silence appended to the buffer: one second fixed the dropped trailing words (2026-10-15).
    public static let trailingSilenceSeconds = 1.0
    /// A listen's audio is kept to this long: 16 kHz mono is under 4 MB, 48 kHz under 12 MB.
    public static let maxCaptureSeconds = 60.0
    /// Less than this is a cough or a click, not a turn.
    public static let minimumSeconds = 0.3

    /// Why the live text was kept (or the pass never ran).
    public enum Reason: String, Sendable, Equatable {
        case off, noAudio, truncated, tooShort, noLiveText
        case empty, failed, timedOut, implausible
    }

    public enum PassResult: Sendable, Equatable {
        case text(String)
        case failed
        case timedOut
    }

    public enum Decision: Sendable, Equatable {
        case use(String)
        case keep(Reason)
    }

    /// Whether the audio is worth a pass at all, checked before spending one.
    public static func skipReason(audio: UtteranceAudio?) -> Reason? {
        guard let audio else { return .noAudio }
        if audio.truncated { return .truncated }
        if audio.seconds < minimumSeconds { return .tooShort }
        return nil
    }

    /// The polished text replaces the live one only when it is a plausible reading of the same
    /// speech: non-empty after the live path's own hygiene, and not wildly longer or shorter.
    public static func decide(live: String, result: PassResult) -> Decision {
        switch result {
        case .failed: return .keep(.failed)
        case .timedOut: return .keep(.timedOut)
        case let .text(raw):
            let polished = TranscriptSanitizer.clean(raw)
            guard !polished.isEmpty else { return .keep(.empty) }
            return plausible(live: live, polished: polished) ? .use(polished) : .keep(.implausible)
        }
    }

    /// Both are the same speech, so their lengths agree to within a factor of two once there is
    /// enough of it to have a length; one word either way on a short turn is ordinary.
    private static func plausible(live: String, polished: String) -> Bool {
        let before = wordCount(live)
        guard before >= 4 else { return true }
        let after = wordCount(polished)
        return after * 2 >= before && after <= before * 2
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
