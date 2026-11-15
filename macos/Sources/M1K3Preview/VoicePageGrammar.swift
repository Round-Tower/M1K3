//
//  VoicePageGrammar.swift
//  M1K3Preview
//
//  The small, closed grammar for the page beside the avatar in voice mode (#839): "scroll
//  down / up", "go back", "close it" while a page is open, and "show me that" / "put it up"
//  to open the source the last answer cited. A pure matcher, not a model: the WHOLE utterance
//  must be one of the phrases (after a little filler is trimmed), so "go back to the start of
//  the story" is a question for the model and never a page command. Anything unmatched falls
//  through to the normal voice turn.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-15, Confidence 0.8 (the phrase list is a first cut;
//  recogniser variants will earn additions, each with a near-miss test). Prior: none (new file).

import Foundation

public enum VoicePageCommand: Sendable, Equatable {
    case scrollDown
    case scrollUp
    case goBack
    case close
    /// Open the source the last answer cited. Still a request, never an automatic load.
    case showCited
}

public enum VoicePageGrammar {
    /// The command `transcript` says, or nil. Page-state commands need a page open; `showCited`
    /// does not.
    public static func match(_ transcript: String, pageIsOpen: Bool) -> VoicePageCommand? {
        let phrase = normalised(transcript)
        guard !phrase.isEmpty else { return nil }
        if showPhrases.contains(phrase) { return .showCited }
        guard pageIsOpen else { return nil }
        if downPhrases.contains(phrase) { return .scrollDown }
        if upPhrases.contains(phrase) { return .scrollUp }
        if backPhrases.contains(phrase) { return .goBack }
        if closePhrases.contains(phrase) { return .close }
        return nil
    }

    private static let showPhrases: Set<String> = [
        "show me that", "show me the source", "put it up", "put that up", "pull it up", "pull that up",
    ]
    private static let downPhrases: Set<String> = [
        "scroll down", "scroll down a bit", "scroll down a little", "page down",
    ]
    private static let upPhrases: Set<String> = [
        "scroll up", "scroll up a bit", "scroll up a little", "scroll back up", "page up",
    ]
    private static let backPhrases: Set<String> = ["go back", "go back a page"]
    private static let closePhrases: Set<String> = [
        "close it", "close that", "close this", "close the page",
    ]

    private static let leadingFiller = ["okay ", "ok ", "hey ", "please ", "can you ", "could you "]
    private static let trailingFiller = [" please"]

    /// Lowercased, punctuation dropped, whitespace collapsed, one round of filler trimmed each side.
    private static func normalised(_ transcript: String) -> String {
        let kept = transcript.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) ? Character(scalar) : " "
        }
        var phrase = String(kept).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var trimmed = true
        while trimmed {
            trimmed = false
            for filler in leadingFiller where phrase.hasPrefix(filler) {
                phrase.removeFirst(filler.count)
                trimmed = true
            }
            for filler in trailingFiller where phrase.hasSuffix(filler) {
                phrase.removeLast(filler.count)
                trimmed = true
            }
        }
        return phrase
    }
}
