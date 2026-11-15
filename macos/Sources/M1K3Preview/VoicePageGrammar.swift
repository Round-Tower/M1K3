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
//  Review: Kev + claude-opus-5.5, 2026-11-15 — #839 review: `VoicePageRouting` (the grammar must not swallow an
//  ordinary turn: nothing cited falls through, "go back" at the first page closes). Confidence 0.8.

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

/// Whether the last answer has a source to put up: the shells map `CitedSource.Availability` onto it.
public enum VoicePageCitedState: Sendable, Equatable {
    case ready
    /// The answer is still being written; its sources land when it finishes.
    case pending
    case none
}

/// What to do with a spoken turn (#839): a page command, or an ordinary turn for the model.
public enum VoicePageAction: Sendable, Equatable {
    case scroll(VoicePageCommand)
    case goBack
    case close
    case openCited
    /// Say a short "one moment" now and open the page once the sources land.
    case waitThenOpenCited
    /// Not ours: the words go to the model like any turn.
    case passToModel
}

public enum VoicePageRouting {
    /// The grammar plus what it needs to know. The grammar never swallows an ordinary turn:
    /// "show me that" with nothing cited is a question for the model; "go back" at the first page
    /// closes the page (there is no earlier page to go to).
    public static func route(
        _ transcript: String, pageIsOpen: Bool, cited: VoicePageCitedState, canGoBack: Bool
    ) -> VoicePageAction {
        guard let command = VoicePageGrammar.match(transcript, pageIsOpen: pageIsOpen) else { return .passToModel }
        switch command {
        case .scrollDown, .scrollUp:
            return .scroll(command)
        case .goBack:
            return canGoBack ? .goBack : .close
        case .close:
            return .close
        case .showCited:
            switch cited {
            case .ready: return .openCited
            case .pending: return .waitThenOpenCited
            case .none: return .passToModel
            }
        }
    }
}
