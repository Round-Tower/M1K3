//
//  SoundContext.swift
//  M1K3Voice
//
//  What the room sounded like during a listen, from SoundAnalysis's built-in
//  classifier (303 labels, ~1.4% of real time, 63 MB; measured 2026-10-15): one
//  short line for the turn ("music (guitar), a dog barking") and a verdict on
//  whether the listen had a speaker at all. Music or singing with no speech is
//  the old "wrote down the lyrics" turn: the transcript of a song, not of you.
//
//  Pure: windows of label confidences in, a line and a verdict out. A sound must
//  persist (≥ 0.6 in two windows) or be certain (≥ 0.9 once) to be mentioned, so
//  one stray window doesn't put a dog in the room. Only labels in the map reach
//  the line: a fixed vocabulary, never free text, so nothing heard can inject
//  words into a prompt. The grounding eval: docs/evals/2026-10-15-sound-context.md
//  (speech 30/30 and talking over music 30/30 taken; no turn vetoed while M1K3 itself
//  plays, or on one burst of music: a majority of windows must be music).
//
//  Wired 2026-10-16 (Kev: "let's wire what we've built"): AppleSpeechTranscriber
//  feeds the listener, VoiceTurnPreparer logs the verdict in SHADOW (every turn is
//  still taken) and SoundContextGate hands the line to the brain. Only labels are
//  ever kept, never audio.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-15, Confidence 0.75 (one speaker, Apple's
//  loops for music; the thresholds are starting points). Prior: Unknown.
//  Review: Kev + claude-opus-5-5, 2026-10-16 — `hasAlert` for SoundContextGate; the header
//  now says where it's wired. The verdict vetoes nothing yet: shadow until live logs agree.

import Foundation

public struct SoundContext: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        /// A speaker was heard, or nothing decisive was: the transcript decides.
        case take
        /// Music or singing and no speech: the words are a song's, not the user's.
        case musicWithoutSpeech
    }

    /// Any window with speech at or above this keeps the turn. Low on purpose: a dropped turn
    /// is the worse mistake. At 0.1 every turn was kept with music up to 10 dB louder than the
    /// voice (9/10 at 15 dB); 0.5 kept 8/10 at 10 dB and 2/10 at 15 (eval doc).
    public static let speechFloor = 0.1
    /// Music or singing at or above this marks a window musical; a listen needs a majority of
    /// musical windows, and at least two windows, so one ringtone or earcon can't decide it.
    public static let musicFloor = 0.5
    public static let mentionFloor = 0.6
    public static let certain = 0.9
    public static let maxMentions = 3

    private var windows = 0
    private var speechWindows = 0
    private var musicWindows = 0
    /// M1K3 made a sound during this listen (an earcon, the dial-up, speech). The Mac has no
    /// echo cancellation, so that sound reaches the mic: the music may be ours, never veto.
    private var ownPlayback = false
    /// Per label: windows at or over the mention floor, and the best confidence.
    private var seen: [String: Seen] = [:]

    struct Seen: Equatable {
        var count = 0
        var best = 0.0
    }

    public init() {}

    public mutating func observe(_ window: [String: Double]) {
        windows += 1
        if (window["speech"] ?? 0) >= Self.speechFloor { speechWindows += 1 }
        if Self.musicLabels.contains(where: { (window[$0] ?? 0) >= Self.musicFloor }) { musicWindows += 1 }
        for (label, confidence) in window where confidence >= Self.mentionFloor
            && (Self.vocabulary[label] != nil || Self.instruments[label] != nil)
        {
            seen[label, default: Seen()].count += 1
            seen[label, default: Seen()].best = max(seen[label, default: Seen()].best, confidence)
        }
    }

    public mutating func reset() {
        self = SoundContext()
    }

    /// The app played audio during this listen: the verdict is `.take` until the next reset.
    public mutating func noteOwnPlayback() {
        ownPlayback = true
    }

    public var verdict: Verdict {
        let song = windows >= 2 && speechWindows == 0 && musicWindows * 2 > windows
        return song && !ownPlayback ? .musicWithoutSpeech : .take
    }

    /// A sound heard well enough to mention that needs attention (an alarm, a siren, the door,
    /// a phone, a baby crying): SoundContextGate says these every turn.
    public var hasAlert: Bool {
        seen.contains { label, stats in
            (stats.count >= 2 || stats.best >= Self.certain) && (Self.vocabulary[label]?.rank ?? .max) <= 1
        }
    }

    /// Up to three sounds, most pressing first; nil when the room was only a voice.
    public var contextLine: String? {
        let heard = seen.filter { $0.value.count >= 2 || $0.value.best >= Self.certain }
        var byGroup: [String: (sound: Sound, best: Double)] = [:]
        for (label, stats) in heard {
            guard let sound = Self.vocabulary[label] else { continue }
            if let current = byGroup[sound.group],
               (current.sound.specific ? 1 : 0, current.best) >= (sound.specific ? 1 : 0, stats.best) { continue }
            byGroup[sound.group] = (sound, stats.best)
        }
        // The group name breaks ties: dictionary order is per-process random.
        let phrases = byGroup.values
            .sorted { ($0.sound.rank, -$0.best, $0.sound.group) < ($1.sound.rank, -$1.best, $1.sound.group) }
            .prefix(Self.maxMentions)
            .map { $0.sound.group == "music" ? musicPhrase(heard: heard) : $0.sound.phrase }
        return phrases.isEmpty ? nil : phrases.joined(separator: ", ")
    }

    /// "music", or "music (guitar)" when an instrument was heard as clearly.
    private func musicPhrase(heard: [String: Seen]) -> String {
        let instrument = heard
            .compactMap { label, stats in Self.instruments[label].map { (name: $0, best: stats.best) } }
            .min { ($0.best, $1.name) > ($1.best, $0.name) } // the clearest, then by name
        return instrument.map { "music (\($0.name))" } ?? "music"
    }

    // MARK: - Vocabulary

    struct Sound: Equatable {
        let phrase: String
        let group: String
        /// Lower is more pressing: what needs attention leads the line.
        let rank: Int
        /// A specific label ("dog_bark") beats its general one ("dog") in the same group.
        let specific: Bool
    }

    private static let musicLabels = ["music", "singing", "choir_singing", "rapping", "humming"]

    private static let instruments: [String: String] = [
        "guitar": "guitar", "acoustic_guitar": "guitar", "electric_guitar": "guitar", "bass_guitar": "bass",
        "piano": "piano", "organ": "organ", "synthesizer": "synth", "drum_kit": "drums", "drum": "drums",
        "violin_fiddle": "fiddle", "cello": "cello", "flute": "flute", "saxophone": "saxophone",
        "trumpet": "trumpet", "harp": "harp", "banjo": "banjo", "ukulele": "ukulele", "accordion": "accordion",
        "harmonica": "harmonica", "orchestra": "an orchestra", "singing": "singing", "choir_singing": "a choir",
    ]

    private static let vocabulary: [String: Sound] = {
        var map: [String: Sound] = [:]
        func add(_ labels: [String], _ phrase: String, group: String, rank: Int, specific: Bool = false) {
            for label in labels {
                map[label] = Sound(phrase: phrase, group: group, rank: rank, specific: specific)
            }
        }
        add(["smoke_detector"], "a smoke alarm", group: "smoke", rank: 0)
        add(["alarm_clock"], "an alarm", group: "alarm", rank: 0)
        add(["siren", "police_siren", "ambulance_siren", "fire_engine_siren", "civil_defense_siren"],
            "a siren", group: "siren", rank: 0)
        add(["door_bell"], "the doorbell", group: "door", rank: 0, specific: true)
        add(["knock"], "knocking", group: "door", rank: 0)
        add(["telephone_bell_ringing", "ringtone"], "a phone ringing", group: "phone", rank: 0)
        // Only the baby label: crying_sobbing is often an adult, maybe the user, and not ours to announce.
        add(["baby_crying"], "a baby crying", group: "crying", rank: 1)
        add(["music", "singing", "choir_singing", "rapping", "humming"], "music", group: "music", rank: 2)
        add(["crowd", "chatter"], "people talking nearby", group: "people", rank: 3)
        add(["laughter", "belly_laugh", "baby_laughter"], "laughter", group: "laughter", rank: 3)
        add(["applause"], "applause", group: "applause", rank: 3)
        add(["cough"], "coughing", group: "cough", rank: 3)
        add(["dog", "dog_howl", "dog_growl", "dog_whimper"], "a dog", group: "dog", rank: 4)
        add(["dog_bark", "dog_bow_wow"], "a dog barking", group: "dog", rank: 4, specific: true)
        add(["cat", "cat_meow", "cat_purr"], "a cat", group: "cat", rank: 4)
        add(["vacuum_cleaner"], "a vacuum", group: "vacuum", rank: 5)
        add(["microwave_oven"], "the microwave", group: "microwave", rank: 5)
        add(["water_tap_faucet"], "running water", group: "tap", rank: 5)
        add(["typing", "typing_computer_keyboard"], "typing", group: "typing", rank: 5)
        add(["rain", "raindrop"], "rain", group: "rain", rank: 6)
        add(["wind", "wind_rustling_leaves"], "wind", group: "wind", rank: 6)
        add(["traffic_noise", "car_passing_by", "car_horn"], "traffic", group: "traffic", rank: 6)
        add(["train", "train_horn", "train_whistle"], "a train", group: "train", rank: 6)
        return map
    }()
}
