//
//  LookIntent.swift
//  M1K3Chat
//
//  The spoken trigger for a look (#768): does this utterance ask M1K3 to use
//  the camera on what is in front of the phone, now? Pure, so the voice loop
//  can ask before a turn is sent.
//
//  A match turns the camera on, so this is TIGHT on purpose. The shape is
//  [a few lead-in words] + one known ask + [a few trailing words], and
//  anything outside that shape is not a trigger: "look at this from my point
//  of view" fails on its tail, "I told her to look at this" on its lead-in.
//  A miss costs a tap on the eye button; a false hit opens a camera nobody
//  asked for. While the eyes are already open the loop does not ask this at
//  all (every turn is a look), so bare "what's that?" is left out here: it is
//  as often about the conversation as about the world.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-09, Confidence 0.6, Prior: none (new file)
//  Context: a heuristic, so it was scored on a blind utterance set written by
//  an agent that never saw these phrases (the numbers are in the PR for #768).
//  Open: English only. Another language's voice turn never matches, and the
//  eye button is the way in.
//

import Foundation

public enum LookIntent {
    /// Whether `utterance` asks for a look through the camera right now.
    /// Whether one voice turn takes the look route. While the eyes are open
    /// every turn does: the open camera is the user's standing ask, so the
    /// words are not second-guessed. With the eyes closed only an ask to look
    /// does, and the shell makes that one glance (the camera closes again once
    /// the frame is taken). Never when the answering brain or the device
    /// cannot look.
    public static func voiceTurnLooks(_ utterance: String, eyesOpen: Bool, canLook: Bool) -> Bool {
        guard canLook else { return false }
        return eyesOpen || asksToLook(utterance)
    }

    public static func asksToLook(_ utterance: String) -> Bool {
        let words = normalized(utterance)
        guard !words.isEmpty, words.count <= maxWords else { return false }
        if kindOfThing(words) { return true }
        for ask in asks {
            for start in starts(of: ask.words, in: words) {
                let lead = words[..<start]
                let tail = words[(start + ask.words.count)...]
                guard tail.allSatisfy(tailWords.contains) else { continue }
                if ask.anyLead || lead.allSatisfy(leadWords.contains) { return true }
            }
        }
        return false
    }

    // MARK: - The phrase table

    /// One known ask, in normalized words. `anyLead` asks are unmistakable
    /// enough to follow any opening ("ok so I'm in the shop and ...").
    private struct Ask {
        let words: [String]
        let anyLead: Bool

        init(_ phrase: String, anyLead: Bool = false) {
            words = phrase.split(separator: " ").map(String.init)
            self.anyLead = anyLead
        }
    }

    /// Longer than this is talk, not a command.
    private static let maxWords = 14

    private static let asks: [Ask] = [
        Ask("what am i looking at", anyLead: true),
        Ask("what am i holding", anyLead: true),
        Ask("what am i pointing at", anyLead: true),
        Ask("whats in front of me", anyLead: true),
        Ask("whats this in front of me", anyLead: true),
        Ask("what im looking at"),
        Ask("what im holding"),
        Ask("what do you see"),
        Ask("what can you see"),
        Ask("what you see"),
        Ask("what you can see"),
        Ask("look at this"),
        Ask("look at that"),
        Ask("can you see this"),
        Ask("can you see that"),
        Ask("read this"),
        Ask("read that"),
        Ask("what does this say"),
        Ask("what does that say"),
        Ask("whats this thing"),
        Ask("whats that thing"),
        Ask("whats this im holding"),
        Ask("identify this"),
        Ask("identify that"),
        Ask("use the camera"),
        Ask("use your camera"),
        Ask("open the camera"),
        Ask("turn on the camera"),
        Ask("turn the camera on"),
        Ask("open your eyes"),
        Ask("use your eyes"),
    ]

    /// What may come before an ask: a greeting, a name, a polite request.
    private static let leadWords: Set<String> = [
        "hey", "hi", "ok", "okay", "so", "right", "now", "well", "em", "um", "uh", "and",
        "mike", "mikey", "m1k3", "please", "can", "could", "would", "will", "you", "just",
        "quickly", "tell", "me", "take", "have", "a", "quick", "do", "know",
    ]

    /// What may come after one: where, when, for whom, and "and tell me what it is".
    private static let tailWords: Set<String> = [
        "here", "there", "now", "right", "please", "thanks", "mike", "mikey", "m1k3",
        "for", "to", "me", "out", "loud", "aloud", "then", "exactly", "in", "front", "of",
        "and", "tell", "what", "it", "is", "whats", "you", "see", "this", "that",
        "sign", "label", "menu", "text", "thing", "one",
    ]

    private static let kinds: Set<String> = [
        "kind", "type", "sort", "breed", "species", "make", "model", "brand",
    ]

    /// "what kind of plant is this": a question about the thing in hand. One
    /// or two words name the thing, and the sentence ends on this / that.
    private static func kindOfThing(_ words: [String]) -> Bool {
        guard (6 ... 7).contains(words.count),
              words[0] == "what" || words[0] == "which",
              kinds.contains(words[1]), words[2] == "of",
              words[words.count - 2] == "is",
              words[words.count - 1] == "this" || words[words.count - 1] == "that"
        else { return false }
        return true
    }

    // MARK: - Normalizing

    /// Lowercased words with apostrophes dropped ("what's" and "whats" are one
    /// word, as speech-to-text gives either) and "what is" / "i am" folded to
    /// the contracted form the table is written in.
    static func normalized(_ utterance: String) -> [String] {
        var text = utterance.lowercased()
        for apostrophe in ["'", "’", "‘"] {
            text = text.replacingOccurrences(of: apostrophe, with: "")
        }
        let words = text
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        var folded: [String] = []
        var index = 0
        while index < words.count {
            let word = words[index]
            let next = index + 1 < words.count ? words[index + 1] : nil
            if word == "what", next == "is" {
                folded.append("whats")
                index += 2
            } else if word == "i", next == "am" {
                folded.append("im")
                index += 2
            } else {
                folded.append(word)
                index += 1
            }
        }
        return folded
    }

    private static func starts(of phrase: [String], in words: [String]) -> [Int] {
        guard phrase.count <= words.count else { return [] }
        return (0 ... words.count - phrase.count).filter { start in
            Array(words[start ..< start + phrase.count]) == phrase
        }
    }
}
