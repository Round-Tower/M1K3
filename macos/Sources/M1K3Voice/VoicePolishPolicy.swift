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
//  Review: claude-opus-5-5, 2026-11-16 (code-quality review fold, #852) — the plausibility check is
//  lexical at every length (a short live text no longer accepts any text); utterances past
//  `maxPolishSeconds` skip the pass and capture stops at `maxCaptureSeconds` (20 s, not 60: the audio
//  beyond the polish limit is never used and costs memory beside the brain); the recorder averages
//  channels, marks a buffer it can't read as a hole (truncated), reserves its capacity up front,
//  applies the switch only at a listen's start and skips barge-in watches. Confidence 0.75.

import AVFoundation
import Foundation

/// One finished utterance's audio: mono float samples at the tap's rate, held in memory only.
public struct UtteranceAudio: Sendable, Equatable {
    public let samples: [Float]
    public let sampleRate: Double
    /// The capture hit its cap, changed rate or missed a buffer: the audio is not the whole utterance.
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
/// (`isEnabled`), and the switch takes hold only when the next listen begins (`beginListen`), so a
/// listen already under way is never recorded from the middle. Bounded: past `maxSeconds` the rest
/// is dropped and the audio reads `truncated`, so the pass is skipped rather than run on a
/// fragment. The whole cap is reserved when a listen begins, so the realtime tap never allocates.
/// Its own lock; the tap calls it from the audio thread, outside every other lock.
public final class UtteranceRecorder: @unchecked Sendable {
    /// The highest tap rate the reservation is sized for; a faster mic grows the buffer once.
    static let reserveRate = 48000.0

    private let maxSeconds: Double
    private let lock = NSLock()
    /// What the shell asked for; applied by `beginListen`.
    private var wanted = false
    /// Whether THIS listen records.
    private var recording = false
    private var samples: [Float] = []
    private var rate: Double = 0
    private var truncated = false

    public init(maxSeconds: Double = VoicePolishPolicy.maxCaptureSeconds) {
        self.maxSeconds = maxSeconds
    }

    public var isEnabled: Bool {
        get { lock.withLock { wanted } }
        set {
            lock.withLock {
                wanted = newValue
                // Turning it off lets go at once; turning it on waits for the next listen.
                if !newValue {
                    recording = false
                    clear()
                }
            }
        }
    }

    /// Capacity held for the next listen (for tests).
    var reservedCapacity: Int {
        lock.withLock { samples.capacity }
    }

    /// A new listen starts from nothing. `recording: false` is for a listen whose audio is not a
    /// turn's (the barge-in watch hears M1K3 itself).
    public func beginListen(recording shouldRecord: Bool = true) {
        lock.withLock {
            recording = wanted && shouldRecord
            clear()
            reserveIfRecording()
        }
    }

    /// Forget the current listen's audio.
    public func reset() {
        beginListen()
    }

    /// From the tap: mono float samples at `sampleRate`.
    public func append(_ buffer: UnsafeBufferPointer<Float>, sampleRate: Double) {
        lock.withLock {
            guard recording, !truncated, !buffer.isEmpty, sampleRate > 0 else { return }
            if samples.isEmpty { rate = sampleRate }
            // Two rates in one listen (a route change): not one utterance's audio any more.
            guard sampleRate == rate else {
                truncated = true
                return
            }
            let room = Int(maxSeconds * rate) - samples.count
            if buffer.count > room {
                samples.append(contentsOf: buffer.prefix(max(0, room)))
                truncated = true
            } else {
                samples.append(contentsOf: buffer)
            }
        }
    }

    /// From the tap: any PCM buffer. Multi-channel float audio is averaged to mono; a buffer this
    /// can't read (interleaved, not float32) is a hole in the audio, so the capture reads truncated
    /// rather than splice around it.
    public func append(_ buffer: AVAudioPCMBuffer) {
        guard lock.withLock({ recording }), buffer.frameLength > 0 else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard !buffer.format.isInterleaved, buffer.format.commonFormat == .pcmFormatFloat32,
              channels > 0, let data = buffer.floatChannelData
        else {
            markHole()
            return
        }
        if channels == 1 {
            append(UnsafeBufferPointer(start: data[0], count: frames), sampleRate: buffer.format.sampleRate)
            return
        }
        var mono = [Float](repeating: 0, count: frames)
        let scale = 1 / Float(channels)
        for channel in 0 ..< channels {
            let source = data[channel]
            for frame in 0 ..< frames {
                mono[frame] += source[frame] * scale
            }
        }
        mono.withUnsafeBufferPointer { append($0, sampleRate: buffer.format.sampleRate) }
    }

    /// A buffer went unrecorded: the audio is no longer the whole utterance.
    public func markHole() {
        lock.withLock { if recording { truncated = true } }
    }

    /// What this listen heard, once: the buffer starts over for the next.
    public func take() -> UtteranceAudio? {
        lock.withLock {
            let taken = samples.isEmpty ? nil : UtteranceAudio(samples: samples, sampleRate: rate, truncated: truncated)
            clear()
            reserveIfRecording()
            return taken
        }
    }

    private func clear() {
        samples = []
        rate = 0
        truncated = false
    }

    private func reserveIfRecording() {
        if recording { samples.reserveCapacity(Int(maxSeconds * Self.reserveRate)) }
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
    /// The longest utterance the pass is attempted on. The budget is fixed but the pass grows with
    /// the audio (corpus 1: median 0.23 s for ~4 s clips plus the padding), so a long utterance on a
    /// slow device would spend the whole budget and fall back anyway: skip it up front. 15 s is
    /// several times a normal spoken question.
    public static let maxPolishSeconds = 15.0
    /// A listen's audio is kept to this long: past `maxPolishSeconds` plus the leading wait for the
    /// user to start, the audio is never used, and it sits in memory beside the brain (20 s at
    /// 48 kHz is under 4 MB). A listen that outlasts it reads truncated and is skipped.
    public static let maxCaptureSeconds = 20.0
    /// Less than this is a cough or a click, not a turn.
    public static let minimumSeconds = 0.3
    /// The share of the live text's words that must survive in the polished text. Fast and accurate
    /// are two modes of one recogniser over the same audio and agree on 89-91% of words on corpus 1,
    /// so a real correction keeps most words; Kev's own example ("You're my curry keeping, are you
    /// well?" to "How're you keeping, are you well?") keeps 4 of 7 (57%). Below 40% the two texts
    /// are reading different speech: the pass heard something else (TV, a second voice, noise).
    public static let minimumWordOverlap = 0.4

    /// Why the live text was kept (or the pass never ran).
    public enum Reason: String, Sendable, Equatable {
        case off, noAudio, truncated, tooShort, tooLong, noLiveText
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
        if audio.seconds > maxPolishSeconds { return .tooLong }
        return nil
    }

    /// The polished text replaces the live one only when it is a plausible reading of the same
    /// speech: non-empty after the live path's own hygiene, of a length that fits, and sharing
    /// enough of its words.
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

    /// Both are the same speech, so: a short live text (under 4 words) takes one word up to three
    /// more; a longer one keeps its length within a factor of two; and at every length at least
    /// `minimumWordOverlap` of the live words survive (a repeated word needs its repeat).
    private static func plausible(live: String, polished: String) -> Bool {
        let before = words(live)
        let after = words(polished)
        guard !after.isEmpty else { return false }
        if before.count < 4 {
            guard after.count <= before.count + 3 else { return false }
        } else {
            guard after.count * 2 >= before.count, after.count <= before.count * 2 else { return false }
        }
        guard !before.isEmpty else { return true }
        var pool: [String: Int] = [:]
        for word in after {
            pool[word, default: 0] += 1
        }
        var shared = 0
        for word in before where pool[word, default: 0] > 0 {
            pool[word, default: 0] -= 1
            shared += 1
        }
        return Double(shared) / Double(before.count) >= minimumWordOverlap
    }

    /// Lowercased, accent-folded words with punctuation (apostrophes included) dropped.
    static func words(_ text: String) -> [String] {
        let apostrophes: Set<Character> = ["'", "\u{2019}"]
        return text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && !apostrophes.contains($0) })
            .map { String($0.filter { !apostrophes.contains($0) }) }
            .filter { !$0.isEmpty }
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
