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
//  Review: claude-opus-5-5, 2026-11-20 — `voice(forLanguage:voices:)`: the voice a non-English answer is spoken in
//  (compact allowed, Eloquence never). `pick` is untouched. Confidence 0.75.
//  Review: claude-opus-5-5, 2026-11-20 (review fold) — region before quality: the person's own region when a voice
//  speaks the language there, else the code's or the language's home (pt → BR, zh-Hans → CN, zh-Hant → TW, fr → FR),
//  so a Brazilian never gets pt-PT and zh-Hans never Cantonese. Confidence 0.8.
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

    /// The best installed voice for a NON-English answer: same language only, the language's own region first
    /// (pt → pt-BR, the wave-one translation; zh-Hans → zh-CN Mandarin, zh-Hant → zh-TW, never Cantonese for either),
    /// then premium > enhanced > compact (a compact voice in the right language beats English phonetics), the
    /// Eloquence novelty set never, identifier breaks ties. Nil when no voice speaks the language.
    public static func voice(
        forLanguage code: String, voices: [SystemVoiceCandidate],
        personRegion: String? = Locale.current.region?.identifier
    ) -> String? {
        let language = code.split(separator: "-").first.map { $0.lowercased() } ?? code.lowercased()
        let speaking = voices.filter {
            languageCode(of: $0.language) == language && !$0.identifier.hasPrefix("com.apple.eloquence.")
        }
        // The person's own region when a voice speaks the language there (a Mexican Spanish speaker hears es-MX),
        // else the code's or the language's home region.
        let own = personRegion?.lowercased()
        let region = own.flatMap { candidate in
            speaking.contains { regionCode(of: $0.language) == candidate } ? candidate : nil
        } ?? preferredRegion(for: code)
        return speaking
            .sorted { a, b in
                let aHome = regionCode(of: a.language) == region, bHome = regionCode(of: b.language) == region
                if aHome != bHome { return aHome }
                if a.quality != b.quality { return a.quality > b.quality }
                return a.identifier < b.identifier
            }
            .first?.identifier
    }

    /// The region whose voice speaks a language code when the person's own region has none: the code's own region
    /// when it names one ("pt-BR"), the script's home for Chinese, the translation's target for pt, else the
    /// language's home country (fr → FR, es → ES, ja → JP).
    private static let homeRegion: [String: String] = [
        "de": "de", "fr": "fr", "es": "es", "it": "it", "nl": "nl", "sv": "se", "da": "dk", "fi": "fi", "pl": "pl",
        "cs": "cz", "ru": "ru", "tr": "tr", "el": "gr", "ja": "jp", "ko": "kr", "th": "th",
    ]

    static func preferredRegion(for code: String) -> String? {
        let parts = code.replacingOccurrences(of: "_", with: "-").split(separator: "-").map { $0.lowercased() }
        if parts.count > 1, parts[1].count == 2 { return parts[1] }
        switch parts.joined(separator: "-") {
        case "zh-hans": return "cn"
        case "zh-hant": return "tw"
        case "pt": return "br"
        default: return homeRegion[parts[0]]
        }
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
