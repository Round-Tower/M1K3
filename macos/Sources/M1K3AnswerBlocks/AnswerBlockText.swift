//
//  AnswerBlockText.swift
//  M1K3AnswerBlocks
//
//  The words the answer-block cards show and hand VoiceOver (#717). Kept out of
//  the views so the issue's gate, "VoiceOver labels for every block type", is
//  pinned by tests rather than eyeballed. An item may carry inline markdown
//  (**bold**, `code`): the card renders it, and VoiceOver reads the plain text
//  without the markers. A tapped choice sends exactly that plain text.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85 (pure, pinned in
//  AnswerBlockTextTests; the wording is a taste call). Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-27 (code-quality review fold) — `sent`: a tap sent the option's
//  raw markdown, so `[Yes](https://x "…")` showed "Yes" and put the hidden destination and title into the
//  user's own turn. And `inline` drops links: a link run inside a card's button opened the browser
//  instead of ticking or sending. Confidence 0.85.
//

import Foundation

enum AnswerBlockText {
    /// The item with its inline markdown parsed (bold, italic, code); the text
    /// as written when it doesn't parse. Links keep their words and lose their
    /// destination: every card row is a button, and a link run inside one
    /// would open the browser on a tap meant to tick a step or send a choice.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var result = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        for run in result.runs where run.link != nil {
            result[run.range].link = nil
        }
        return result
    }

    /// The item as VoiceOver should read it: no markdown markers.
    static func plain(_ text: String) -> String {
        String(inline(text).characters)
    }

    /// "Step 2 of 5: Lift the cover."
    static func stepLabel(number: Int, of count: Int, step: String) -> String {
        String(localized: "Step \(number) of \(count): \(plain(step))")
    }

    /// The step's tick, session-only.
    static func stepValue(done: Bool) -> String {
        done ? String(localized: "Done") : String(localized: "Not done")
    }

    /// What a tapped choice sends as the user's next message: the words the
    /// button shows and VoiceOver reads, never the option's markdown source (a
    /// link's destination and title would otherwise ride along unseen, as the
    /// user's own turn). Nil when nothing visible is left to send.
    static func sent(_ option: String) -> String? {
        let words = plain(option).trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? nil : words
    }

    static func choiceLabel(_ option: String) -> String {
        String(localized: "Choose: \(plain(option))")
    }

    static var choiceHint: String {
        String(localized: "Sends it as your next message")
    }

    /// What VoiceOver announces while a block is still streaming.
    static func skeletonLabel(_ kind: AnswerBlockKind) -> String {
        switch kind {
        case .steps: String(localized: "Writing steps")
        case .choices: String(localized: "Writing choices")
        }
    }
}
