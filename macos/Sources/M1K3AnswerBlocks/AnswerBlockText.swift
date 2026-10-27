//
//  AnswerBlockText.swift
//  M1K3AnswerBlocks
//
//  The words the answer-block cards show and hand VoiceOver (#717). Kept out of
//  the views so the issue's gate, "VoiceOver labels for every block type", is
//  pinned by tests rather than eyeballed. An item may carry inline markdown
//  (**bold**, `code`): the card renders it, and VoiceOver reads the plain text
//  without the markers.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85 (pure, pinned in
//  AnswerBlockTextTests; the wording is a taste call). Prior: none (new file).
//

import Foundation

enum AnswerBlockText {
    /// The item with its inline markdown parsed (bold, italic, code, links);
    /// the text as written when it doesn't parse.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
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
