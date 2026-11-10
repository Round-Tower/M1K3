//
//  LookFollowUp.swift
//  M1K3Chat
//
//  What comes after a look (#768 follow-ups). Four small pure pieces:
//
//  - `LookPassGate`: with the eye open in voice mode every turn used to be a
//    look, so "what's the weather tomorrow?" was answered from the camera. Now
//    the brain that sees may answer with one word, PASS, and the turn goes on
//    as an ordinary one. The gate reads that word off the stream.
//  - `LookAftermath`: the turn straight after a look withholds the web unless
//    its own words ask for a search. The 2026-11-09 spike sent "Is there a
//    person in the picture?" to a search engine word for word.
//  - `LookGrounding`: what a look is told beside the frame. The date and time,
//    and nothing else yet (see Open).
//  - `LookSearch`: the search follow-up. The brain that sees drafts a short
//    query from the frame, on the device; the app puts it in the composer and
//    the user sends it. Nothing drafted from the camera leaves the phone
//    unseen.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-10, Confidence 0.75, Prior: none (new file)
//  Context: Kev, 2026-11-10: "Let's do the followups pal - agree with them
//  all. Also I wonder about an Auto mode, and adding grounding, and a
//  websearch toggle or followup to allow a search for information."
//  Open: memory facts do not ride a look. The phone retrieves with the hashing
//  embedder, whose own notes say its floor has no clean cut, so a look's
//  question would pull stray facts into a prompt that also holds whatever text
//  is in view. That waits for a paired per-question test.
//

import Foundation
import M1K3Inference

/// Reads the one-word "not about the view" answer off a look's stream.
public enum LookPassGate {
    public static let word = "PASS"

    public enum Reading: Sendable, Equatable {
        /// Still could be the word: show nothing yet.
        case undecided
        /// A real answer has started.
        case answering
    }

    /// Mid-stream. The word alone is still undecided ("PASS" may yet grow into
    /// "PASSENGERS"): only the finished answer can pass.
    public static func reading(of snapshot: String) -> Reading {
        let core = core(snapshot).uppercased()
        return word.hasPrefix(core) ? .undecided : .answering
    }

    /// The finished answer passes only when it is the word alone. On the
    /// blind set (90 questions; Mini on three pictures, Lil on two, on the
    /// phone) that rule passed none of 225 questions about the view.
    public static func passed(_ answer: String) -> Bool {
        core(answer).uppercased() == word
    }

    /// An answer that ends "… . PASS" is an answer (Lil does this, to real
    /// questions about the view too): it is shown without the stray word.
    public static func withoutStrayWord(_ answer: String) -> String {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ".!*"))
        guard bare.hasSuffix(word) else { return answer }
        let before = bare.dropLast(word.count)
        guard let last = before.last, last.isWhitespace else { return answer }
        let kept = before.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let end = kept.last, ".!?".contains(end) else { return answer }
        return kept
    }

    /// The answer without the wrapping a small model puts round one word.
    private static func core(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`*.!")))
    }
}

/// The turn straight after a look.
public enum LookAftermath {
    /// True inside an ordinary turn that directly follows a look and whose own
    /// words did not ask for a search. The shell's tool palette reads it and
    /// leaves the web tools out for that turn.
    @TaskLocal public static var withholdsWeb = false

    /// What that turn is told. It cannot see the picture, and left to itself
    /// a brain will describe one anyway (Lil invented a music room on the
    /// phone, 2026-11-10).
    public static let clause = """
    CAMERA: The person just showed you something through the camera, but you cannot see that picture in this \
    message and you do not remember it. If they ask about it, do not describe or guess at it: tell them to tap \
    "Ask about this photo" under your last answer, or to open the eye and ask again. Anything else, answer as usual.
    """

    /// Whether these words ask for a search themselves. Loose on purpose: a
    /// hit only keeps the user's own setting.
    public static func asksToSearch(_ text: String) -> Bool {
        let words = text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        let set = Set(words)
        if !set.isDisjoint(with: ["search", "google", "online", "web", "internet", "wikipedia"]) { return true }
        // "look it up", "look up the M6", "look that up online": look … up within three words.
        for (index, word) in words.enumerated() where word == "look" {
            let next = words[(index + 1)...].prefix(3)
            if let up = next.firstIndex(of: "up"), !next[..<up].contains("at") { return true }
        }
        return false
    }
}

/// What a look is told beside the frame.
public enum LookGrounding {
    /// The date and time, in plain English for the prompt. The person's own
    /// calendar and zone by default.
    public static func now(_ date: Date = .now, calendar: Calendar = .current) -> String {
        let format = Date.VerbatimFormatStyle(
            format: """
            \(weekday: .wide) \(day: .defaultDigits) \(month: .wide) \(year: .defaultDigits), \
            \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)
            """,
            locale: Locale(identifier: "en_GB"), timeZone: calendar.timeZone, calendar: calendar
        )
        return "For reference only: it is \(date.formatted(format)) for the person. "
            + "Mention the date or time only if their question needs it."
    }
}

/// The search follow-up to a look.
public enum LookSearch {
    /// The system turn of a draft. The answer is a search query and nothing else.
    public static let instructions = """
    You are looking through a phone camera for the person holding it. \
    They want to look up what is in view on the web. \
    Reply with a web search query of at most eight words that names the main thing in view: \
    a name, a brand, a place or the words on a sign. \
    Reply with the query only, never a sentence. If you can't name anything in view, reply NONE.
    """

    /// What the draft is asked with. Never the look's own question: asked
    /// that, Lil answered it ("yes") instead of drafting.
    public static let prompt = "What should I search the web for to learn more about this? Reply with the query only."

    static let maxWords = 10

    /// One short clean line, or nil. A draft is model output about untrusted
    /// pixels: first line only, no links, no wrapping, a hard word cap.
    public static func clean(_ raw: String) -> String? {
        guard var line = raw.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty })
        else { return nil }
        for label in ["query:", "search query:", "search:"] where line.lowercased().hasPrefix(label) {
            line = String(line.dropFirst(label.count))
        }
        let wrapping = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'`*.“”"))
        let words = line.split(whereSeparator: \.isWhitespace)
            .filter { !$0.contains("://") && !$0.lowercased().hasPrefix("www.") }
            .prefix(maxWords)
        let query = words.joined(separator: " ").trimmingCharacters(in: wrapping)
        guard !query.isEmpty, !["NONE", "YES", "NO"].contains(query.uppercased()) else { return nil }
        return query
    }

    /// What goes in the composer for the user to read, edit and send.
    public static func composerText(_ query: String) -> String {
        "Search the web for \(query)"
    }

    /// Ask the eyes for a query about `frame`. Nil when they have none.
    public static func draft(frame: ImageAttachment, looker: any ImageLooking) async -> String? {
        var latest = ""
        do {
            for try await snapshot in looker.look(image: frame, instructions: instructions, prompt: prompt) {
                latest = snapshot
            }
        } catch {
            return nil
        }
        return clean(latest)
    }
}
