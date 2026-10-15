//
//  BestSystemVoice.swift
//  M1K3Voice
//
//  The Built-in tier's voice, chosen rather than defaulted (#584, #576 §3). With
//  no voice set, AVSpeechSynthesizer speaks in the system default — on a fresh
//  iPhone the compact, robotic one — while most devices have an enhanced or
//  premium voice installed for the same language. This picks the best installed
//  voice for the user's locale, once at launch (a voice installed later is used
//  from the next launch); Kokoro (M1K3 Voice) is unaffected.
//
//  Pure: the ranking takes plain candidates so it is pinned in tests; the one
//  AVFoundation read (`SystemVoices.installed()`) is a thin bridge below.
//
//  The rule: same language only (never French, however premium); premium >
//  enhanced; within a quality the locale's own region first, then any region;
//  identifier breaks ties so the pick is stable across launches. Only compact
//  voices installed → nil, i.e. leave the system default alone: it already is a
//  compact voice, and the alternatives at that quality include the novelty set
//  (Zarvox, Bells…) that would be a downgrade.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-13, Confidence 0.85 (ranking pure and
//  pinned in BestSystemVoiceTests; which voices a given device lists is
//  verify-by-launch). Prior: none (new file).
//

import AVFoundation
import Foundation

/// One installed system voice, as the ranking sees it.
public struct SystemVoiceCandidate: Equatable, Sendable {
    public enum Quality: Int, Comparable, Sendable {
        case compact = 0
        case enhanced = 1
        case premium = 2

        public static func < (lhs: Quality, rhs: Quality) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public let identifier: String
    /// BCP-47, as AVSpeechSynthesisVoice reports it ("en-IE").
    public let language: String
    public let quality: Quality

    public init(identifier: String, language: String, quality: Quality) {
        self.identifier = identifier
        self.language = language
        self.quality = quality
    }
}

public enum BestSystemVoice {
    /// The identifier to set on Built-in utterances, or nil to leave the system
    /// default (see the header for when that is the right answer).
    public static func pick(voices: [SystemVoiceCandidate], locale: Locale) -> String? {
        guard let language = locale.language.languageCode?.identifier.lowercased() else { return nil }
        let region = locale.language.region?.identifier.lowercased()
        let sameLanguage = voices.filter { languageCode(of: $0.language) == language }
        let best = sameLanguage
            .filter { $0.quality > .compact }
            .sorted { a, b in
                if a.quality != b.quality { return a.quality > b.quality }
                let aHome = regionCode(of: a.language) == region, bHome = regionCode(of: b.language) == region
                if aHome != bHome { return aHome }
                return a.identifier < b.identifier
            }
        return best.first?.identifier
    }

    private static func languageCode(of tag: String) -> String {
        tag.split(separator: "-").first.map { $0.lowercased() } ?? tag.lowercased()
    }

    private static func regionCode(of tag: String) -> String? {
        tag.split(separator: "-").last.map { $0.lowercased() }
    }
}

/// The AVFoundation read, kept apart from the ranking so the ranking stays pure.
public enum SystemVoices {
    public static func installed() -> [SystemVoiceCandidate] {
        AVSpeechSynthesisVoice.speechVoices().map {
            SystemVoiceCandidate(identifier: $0.identifier, language: $0.language, quality: quality($0.quality))
        }
    }

    static func quality(_ quality: AVSpeechSynthesisVoiceQuality) -> SystemVoiceCandidate.Quality {
        switch quality {
        case .premium: .premium
        case .enhanced: .enhanced
        case .default: .compact
        @unknown default: .compact
        }
    }
}
