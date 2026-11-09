//
//  LookPrompt.swift
//  M1K3Chat
//
//  The words a look (#768) is asked with. The instructions are the `reading`
//  arm of the iPhone spike (docs/evals/2026-11-09-vision-ttft-iphone/): short,
//  persona-free, sign-first, and held to what is in view. On the one photo it
//  was scored on, that arm gave short answers with no wrong claim about what
//  the place was; feeding OCR text in beside the frame helped neither brain.
//
//  `toolName` is the tag a look's answer carries in `toolsUsed`. It is not a
//  tool the agent can call: it is the provenance the transcript shows ("Used
//  the camera") and the key `DistillationTaint` reads to keep what the camera
//  saw out of distilled memory.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-09, Confidence 0.75, Prior: none (new file)
//  Open: one photo of one street is thin evidence for a prompt. Re-score when
//  the look has a fixture set of its own.
//

import Foundation

public enum LookPrompt {
    /// The whole system prompt of a look. No persona: a look's first words are
    /// the product, and the prefill is most of the wait.
    public static let instructions = """
    You are looking through a phone camera for the person holding it. \
    Answer their question about what is in view in one or two short sentences. \
    Read any sign or text you can see when it helps. \
    Say only what you can see, and say so when you can't tell.
    """

    /// Asked when the user points the camera and says nothing.
    public static let defaultQuestion = "What am I looking at?"

    /// The provenance tag on a look's answer (`ChatMessage.toolsUsed`).
    public static let toolName = "look"

    /// The question as asked: trimmed, or the default when there are no words.
    public static func question(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultQuestion : trimmed
    }
}
