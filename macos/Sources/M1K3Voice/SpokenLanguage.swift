//
//  SpokenLanguage.swift
//  M1K3Voice
//
//  The language an answer is SPOKEN in. Brains answer in the person's language (#870) but the default voice,
//  Kokoro, is an en-GB neural voice with an English G2P: German read by it is English phonetics. A non-English
//  answer is therefore routed to the best installed on-device voice for that language (Kev: "fall back to the
//  on-device synth"). This file is the pure half: the decision and the per-answer latch.
//
//  Asymmetric on purpose: with an English seed the answer leaves English only on a long, confident read (40 letters
//  of its first ~200 characters at 0.8), so an English answer quoting "Guten Morgen" stays on Kokoro. The call is
//  made ONCE per answer (`SpokenAnswerLanguage`), never per sentence: at most one switch, from the seed, while the
//  first sentences are read. With an English seed (no person language yet, e.g. a short first turn) a German answer's
//  opening sentence can go out on Kokoro before the latch leaves English; the seed exists to make that rare. The thresholds
//  echo ReplyLanguage's house rules (letter weight, CJK x3, allow-list) which M1K3Voice cannot import.
//
//  Signed: claude-opus-5-5, 2026-11-20, Confidence 0.7 (the recogniser is Apple's; 40 letters / 0.8 is pinned on
//  SpokenLanguageTests' lines and unmeasured on a blind set). Prior: Unknown
//  Review: claude-opus-5-5, 2026-11-20 (review fold) — the latch takes a seed, the person's own language, so a German
//  answer opening "Klar!" is German from its first sentence (it went out in Kokoro's English while the 40-letter
//  read waited). `language(forChunk:)` keeps narration and the refusal English. Confidence 0.75.
//  Review: claude-opus-5-5, 2026-11-20 (pre-PR review) — `interfaceLanguage`: a page-command reply is a catalog string
//  (#873 translates it), so it is spoken in the app's language, not the speaker's; the shells begin the latch with it.
//  Confidence 0.8.
//

import Foundation
import M1K3LogCore
import NaturalLanguage

public enum SpokenLanguage {
    /// The voice's own language today: Kokoro speaks English.
    public static let seed = "en"
    /// The slice of the answer that is read: the first sentence or two.
    static let window = 200
    /// Leaving an English seed: a long, confident read only.
    static let minimumLettersToLeaveEnglish = 40
    static let minimumConfidenceToLeaveEnglish = 0.8
    /// Between two non-English languages (a non-English seed): ReplyLanguage's floors.
    static let minimumLetters = 12
    static let minimumConfidence = 0.6
    static let ideographWeight = 3
    static let allowed: Set<String> = [
        "en", "de", "fr", "es", "pt", "it", "nl", "sv", "da", "nb", "fi", "pl", "cs", "ro", "hu", "tr", "el", "ru",
        "uk", "he", "ar", "fa", "hi", "ja", "zh-Hans", "zh-Hant", "ko", "th", "vi",
    ]

    /// Nil and any "en" / "en-GB" tag count as English: the Kokoro path.
    public static func isEnglish(_ code: String?) -> Bool {
        guard let code else { return true }
        return code.lowercased().hasPrefix("en")
    }

    /// The language to speak `text` in: `seed` unless the opening of the text clearly reads as another.
    public static func decide(seed: String = SpokenLanguage.seed, text: String) -> String {
        let sample = String(text.prefix(window))
        let weight = letterWeight(sample)
        let leavingEnglish = isEnglish(seed)
        guard weight >= (leavingEnglish ? minimumLettersToLeaveEnglish : minimumLetters) else { return seed }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let top = recognizer.languageHypotheses(withMaximum: 1).first else { return seed }
        let floor = leavingEnglish ? minimumConfidenceToLeaveEnglish : minimumConfidence
        let code = top.key.rawValue
        guard top.value >= floor, allowed.contains(code) else { return seed }
        return code
    }

    /// The language a catalog string is spoken in: the app's own localisation (a page-command reply, "Zurück."),
    /// whatever language the person spoke. English, Base or none is the Kokoro seed.
    public static func interfaceLanguage(_ preferred: [String] = Bundle.main.preferredLocalizations) -> String {
        guard let first = preferred.first, first != "Base", !isEnglish(first) else { return seed }
        return first
    }

    /// The language one spoken chunk goes out in: a narration line or a caller's fixed English line (the persona
    /// refusal, which M1K3Voice cannot import) is English; anything else is the answer's latched language.
    public static func language(forChunk chunk: String, answerLanguage: String,
                                fixedEnglish: Set<String> = []) -> String
    {
        if ToolNarration.isNarration(chunk) || fixedEnglish.contains(chunk) { return seed }
        return answerLanguage
    }

    static func letterWeight(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { total, scalar in
            guard scalar.properties.isAlphabetic else { return total }
            return total + (isIdeographic(scalar) ? ideographWeight : 1)
        }
    }

    private static func isIdeographic(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040 ... 0x30FF, 0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF, 0xAC00 ... 0xD7AF: true
        default: false
        }
    }
}

/// One answer's spoken language, decided once. `begin(seed:)` starts an answer from the person's own language (the
/// shells read it off their turn with `ReplyLanguage.personLanguage`, English when unknown), so a German question's
/// answer is German from its first short sentence ("Klar!"). `observe` is fed the ANSWER's sentences (not tool
/// narration); once enough text has arrived (40 letters off an English seed, 12 off another, or the 200-character
/// window) the language is fixed until the next `begin`. `current` is what the speak path reads.
public final class SpokenAnswerLanguage: @unchecked Sendable {
    private let lock = NSLock()
    private var seed = SpokenLanguage.seed
    private var text = ""
    private var decided: String?

    public init() {}

    public var current: String {
        lock.withLock { decided ?? seed }
    }

    public func begin(seed: String = SpokenLanguage.seed) {
        lock.withLock {
            self.seed = seed
            text = ""
            decided = nil
        }
    }

    public func observe(_ sentence: String) {
        lock.withLock {
            guard decided == nil else { return }
            text += (text.isEmpty ? "" : " ") + sentence
            let floor = SpokenLanguage.isEnglish(seed)
                ? SpokenLanguage.minimumLettersToLeaveEnglish : SpokenLanguage.minimumLetters
            guard SpokenLanguage.letterWeight(text) >= floor || text.count >= SpokenLanguage.window else { return }
            decided = SpokenLanguage.decide(seed: seed, text: text)
        }
    }
}

/// Builds the utterance for an answer in `language`.
public enum SpokenVoice {
    private static let log = M1K3Log.logger(.voice)

    /// The voices installed at first use (a voice installed later is used from the next launch, like Built-in's pick).
    static let installedVoices: [SystemVoiceCandidate] = SystemVoices.installed()

    /// English or nil: exactly today's utterance. Another language: the best installed voice for it, carried with the
    /// language so Kokoro hands the line to the Apple render path (captions, word timing, mouth and barge-in intact).
    /// No installed voice: today's utterance, and a `.notice` so the English-phonetics fallback leaves a trace.
    public static func utterance(
        text: String,
        mood: VoiceMood = .neutral,
        language: String?,
        voices: [SystemVoiceCandidate]? = nil
    ) -> SpeechUtterance {
        let plain = SpeechUtterance(text: text, mood: mood)
        guard let language, !SpokenLanguage.isEnglish(language) else { return plain }
        guard let identifier = BestSystemVoice.voice(forLanguage: language, voices: voices ?? installedVoices) else {
            log.notice("no installed voice for \(language, privacy: .public); speaking with the default voice")
            return plain
        }
        return SpeechUtterance(text: text, mood: mood, language: language, voiceIdentifier: identifier)
    }
}
