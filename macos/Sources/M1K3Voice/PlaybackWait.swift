//
//  PlaybackWait.swift
//  M1K3Voice
//
//  Who ended a plain-path playback wait (`EffectfulSpeechProvider.play`), and
//  what the stall streak hears about it. Pure so `swift test` pins it; the
//  AVAudioPlayerNode glue around it is verify-by-launch.
//
//  Why (#471 review 2, finding 1): only the streaming path told the streak a
//  playback completed. A probe that won on this path left the streak at 2, so
//  the next single stall routed straight back to the plain voice. And the
//  buffer's `.dataPlayedBack` callback hops to the main actor LATER: without a
//  generation, a stopped utterance's late callback could resolve the NEXT
//  utterance's wait.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-05, Confidence 0.85, Prior: Unknown

/// One open wait at a time. `begin()` opens it; the first `end` for the
/// current generation decides it, and every later end (a late callback, the
/// stop's own completion) is ignored.
struct PlaybackWait: Equatable {
    enum Ending: Equatable {
        /// The buffer's `.dataPlayedBack` completion.
        case playedBack
        /// The playback deadline elapsed first.
        case deadline
        /// stop(), a config change or a new utterance cut it off.
        case cancelled
    }

    enum Verdict: Equatable {
        case completed
        case stalled
        case cancelled
    }

    private(set) var generation = 0
    private var isOpen = false

    mutating func begin() -> Int {
        generation += 1
        isOpen = true
        return generation
    }

    /// The verdict for the wait `generation` opened, or nil when that wait is
    /// stale or already decided.
    mutating func end(_ ending: Ending, generation ended: Int) -> Verdict? {
        guard isOpen, ended == generation else { return nil }
        isOpen = false
        switch ending {
        case .playedBack: return .completed
        case .deadline: return .stalled
        case .cancelled: return .cancelled
        }
    }
}
