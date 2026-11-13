//
//  TranscriptSanitizer.swift
//  M1K3Voice
//
//  The final-utterance hygiene pass between the recognizer and the model. Even a
//  perfectly-tuned recognizer feeds the LLM noise on silence/hard audio: stutter
//  loops ("the the the the"), and the notorious silence-hallucinations ("Thank
//  you", "Thanks for watching"). Reasoning over that is the "model can't reason"
//  symptom; this is the cleanup that makes the input legible.
//
//  Provider-agnostic (runs on WhisperKit AND Apple Speech output). Whisper's
//  bracketed non-speech markers ([BLANK_AUDIO] …) are already stripped at the
//  WhisperKit source (WhisperTranscriptText.clean), so this layer doesn't repeat
//  that — it handles the cross-provider concerns. Returns "" for an all-noise
//  utterance, so the caller's existing empty-guard parks the mic / re-listens.
//
//  Confidence gate: a whole-utterance pleasantry is dropped only when the
//  recognizer is NOT confident — WhisperKit reports nil (treated as low, so its
//  ghosts drop), while a genuine, high-confidence Apple Speech "thank you"
//  survives.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-17, Confidence 0.85, Prior: Unknown
//  Review: Kev + claude-fable-5.2, 2026-11-13 — a whole utterance that is only the ghost pronoun
//  REPEATED ("you you") drops under the same low-confidence gate as the pleasantries: two silent MCP
//  listens returned exactly that (WhisperKit, no confidence). A single "you" is still kept, as the
//  06-17 ruling says. Checked before `collapseRepeats`, which would turn three into a surviving one.
//  Confidence 0.85.

import Foundation

public enum TranscriptSanitizer {
    /// Below this recognizer confidence a whole-utterance pleasantry is treated as
    /// a hallucination and dropped. `nil` confidence counts as below it.
    public static let confidenceFloor: Float = 0.5

    /// Clean a FINAL utterance for the model. `confidence` is the recognizer's
    /// self-reported confidence for the utterance (nil when unknown, e.g. WhisperKit).
    /// - Parameter dropPleasantries: drop a whole-utterance silence-hallucination
    ///   ("thank you" on a quiet mic). On for the live assistant turn; OFF for call
    ///   transcripts, where a spoken "thank you" is genuine content.
    public static func clean(
        _ text: String,
        confidence: Float? = nil,
        dropPleasantries: Bool = true
    ) -> String {
        let lowConfidence = (confidence ?? 0) < confidenceFloor
        if dropPleasantries, lowConfidence, isRepeatedGhostWord(text) { return "" }
        let collapsed = collapseRepeats(text)
        let tidied = collapsed
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Strictly BELOW the floor (nil → 0 → below): a confidence of exactly
        // confidenceFloor survives — we'd rather keep a borderline real turn than
        // drop it. WhisperKit reports nil, so its ghosts always clear this gate.
        if dropPleasantries, isHallucination(tidied), lowConfidence {
            return ""
        }
        return tidied
    }

    // MARK: - Rules

    /// Collapse a run of the SAME word repeated 3+ times to a single instance — a
    /// whisper stutter loop. Natural doublings ("no no") are left alone.
    private static func collapseRepeats(_ text: String) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        // Compare on a punctuation-stripped, lowercased key so a heterogeneously
        // punctuated loop ("no, no no") still collapses; the ORIGINAL token (with
        // its punctuation) is what we keep. Self-contained — no caller dependency.
        let keys = words.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        var out: [Substring] = []
        var start = 0
        while start < words.count {
            var end = start
            while end < words.count, keys[end] == keys[start] {
                end += 1
            }
            if end - start >= 3 {
                out.append(words[start]) // pathological loop → one instance
            } else {
                out.append(contentsOf: words[start ..< end]) // natural 1 or 2 → keep
            }
            start = end
        }
        return out.map(String.init).joined(separator: " ")
    }

    /// The whole utterance is one ghost word said twice or more ("you you"). Once
    /// is a plausible turn and is kept (see `hallucinationPhrases`); the repeat,
    /// alone on a quiet mic, is not something anyone says to an assistant.
    private static func isRepeatedGhostWord(_ text: String) -> Bool {
        isGhostWordOnly(text, minimumRepeats: 2)
    }

    /// The whole utterance is one ghost word, said at least `minimumRepeats`
    /// times. Public for the one-shot listen (`ListenEndpoint`), which has no
    /// re-prompt and so also treats a LONE "you" from an unconfident recogniser
    /// as silence; `clean` keeps the lone one (the 06-17 ruling).
    public static func isGhostWordOnly(_ text: String, minimumRepeats: Int) -> Bool {
        let keys = text.split(whereSeparator: \.isWhitespace)
            .map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        guard keys.count >= max(1, minimumRepeats), let first = keys.first, ghostWords.contains(first) else {
            return false
        }
        return keys.allSatisfy { $0 == first }
    }

    /// The whole utterance is a closing pleasantry a recogniser also emits on
    /// silence ("thank you", "bye"). Whether to believe it is the caller's call.
    public static func isPleasantryOnly(_ text: String) -> Bool {
        isHallucination(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Single words whisper emits on silence that are ALSO real one-word turns.
    private static let ghostWords: Set<String> = ["you"]

    /// Whole-utterance (after lowercasing + stripping edge punctuation) equals a
    /// known recognizer silence-hallucination.
    private static func isHallucination(_ text: String) -> Bool {
        let normalized = text
            .lowercased()
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        return hallucinationPhrases.contains(normalized)
    }

    /// The notorious whisper-on-silence ghosts — phrases that, as a WHOLE
    /// utterance to an assistant, are essentially never a real turn. Deliberately
    /// MULTI-WORD / closing-phrase only: a bare pronoun like "you" is a plausible
    /// real turn ("you — look that up"), so it is NOT listed despite being a known
    /// whisper ghost, to avoid silently dropping a genuine short command.
    private static let hallucinationPhrases: Set<String> = [
        "thank you", "thanks", "thank you very much", "thank you for watching",
        "thanks for watching", "bye", "bye bye", "goodbye",
        "please subscribe", "see you next time", "see you in the next video",
    ]
}
