//
//  TextReading.swift
//  M1K3Inference
//
//  The seam for "read this and answer me": the text sibling of `ImageLooking`.
//  The caller's instructions (`ReadPrompt.instructions`, a task, never the
//  persona) and one prompt holding the fenced text and the question; no tools,
//  no grounding, no history, thinking off, streamed. On the phone a chat turn
//  pays for ~4,000 tokens of persona and wiring before it reads a word of the
//  paste; a read pays for ~120 (docs/evals/2026-11-10-system-prompt-cost/).
//
//  Like the look, this is an `as?` capability seam, so EVERY façade forwards it
//  (SwappableInferenceProvider here, RuntimeInferenceProvider in the app), and
//  only the on-device brains conform: Brain at Home and Private Cloud Compute
//  do not, so a pasted text handed to this seam cannot leave the device. The
//  conformer set is pinned by name (`ReadEgressScanTests`).
//
//  `readContextTokens` is the window the conformer will read in: the compressor
//  fits the text to it (`ReadBudget`), so the brain never sees an overflow.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-14, Confidence 0.8, Prior: none (new file);
//  the shape is ImageLooking's (#768).
//  Context: Kev, 2026-11-14: "Context ingestion & compression / sanitization, and analysis
//  without system prompt - similar to vision"; "Instructions only pal. Yes to the Keep This workflow."
//

import Foundation

/// A provider whose model can read a text and answer about it as a stream, outside a
/// chat turn: the caller's instructions, no persona, no tools, thinking off.
public protocol TextReading: Sendable {
    /// CUMULATIVE snapshots of the answer (each element is the whole answer so far).
    /// The stream finishes by throwing when the backend cannot read or the model fails;
    /// cancelling the consumer stops the generation.
    func read(instructions: String, prompt: String) -> LookStream

    /// The context window a read gets on this backend, in tokens; 0 when it cannot read.
    var readContextTokens: Int { get }
}

public enum TextReadingError {
    /// What a façade's stream throws when the active backend cannot read on this device.
    public static let cannotRead = InferenceError.generationFailed("active backend cannot read on this device")

    /// The system turn of a read, trimmed. NEVER the persona: blank instructions fail loudly.
    public static func instructions(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw InferenceError.generationFailed("a read needs instructions")
        }
        return trimmed
    }
}

/// How many characters of text a read can carry in a window.
public enum ReadBudget {
    /// The FAST window a read gets (Kev, 2026-11-14: "Fast by default"), in tokens, by brain and
    /// device, from the blind set's window sweep (docs/evals/2026-11-14-read-blind/):
    /// - Mini: 2,560 everywhere. 38/53 answers and 2.6 s to first text on the Mac, against 43/53
    ///   and 4.5 s at its 4,096 floor.
    /// - The MLX brains on the Mac: 4,096. Lil scored 49/53 there in 4.1 s, against 47/53 in a
    ///   12 s first text at 8,192 on the long texts: less text is better as well as faster.
    /// - The MLX brains on the phone: 2,560, because the phone prefills at about 470 tokens a
    ///   second (docs/evals/2026-11-09-vision-ttft-iphone/). Unmeasured on the phone.
    public static let fastMiniWindow = 2560
    public static let fastMacMLXWindow = 4096
    public static let fastPhoneMLXWindow = 2560

    /// The answer's room. A read is usually a sentence or two; a list or a summary needs more.
    public static let answerTokens = 400
    /// Prose's chars-per-token estimate, the one the history budget uses (`HistoryBudgetPolicy.charsPerToken`).
    static let proseCharsPerToken = 3.5
    /// Tokenizers differ: keep a margin.
    static let margin = 0.85

    /// Characters a token for THIS text, estimated from its make-up: letters run about four and a
    /// half to a token, while digits and punctuation cost about one each (tokenizers split numbers,
    /// some digit by digit). Prose comes out at about 3.5; a CSV export near 2. The blind set's CSV
    /// overflowed Mini's window on the prose figure (docs/evals/2026-11-14-read-blind/). Clamped to
    /// 1.2…3.5, read from the first 20,000 characters.
    public static func charsPerToken(of text: String) -> Double {
        var letters = 0.0, wide = 0.0, dense = 0.0, spaces = 0.0, count = 0.0
        for character in text.prefix(20000) {
            count += 1
            if character.isWhitespace {
                spaces += 1
            } else if character.isLetter {
                // A letter outside Latin (CJK, Arabic, Devanagari) is nearer a token a character.
                if character.unicodeScalars.first.map({ $0.value < 0x0250 }) ?? true { letters += 1 } else { wide += 1 }
            } else {
                dense += 1
            }
        }
        guard count > 0 else { return proseCharsPerToken }
        let tokens = letters / 4.5 + wide / 1.2 + dense + spaces / 10
        return min(proseCharsPerToken, max(1.2, count / max(tokens, 1)))
    }

    /// How many characters of `text` (or of prose, when no text is given) fit beside the
    /// instructions, the question and the answer in `windowTokens`.
    public static func characters(windowTokens: Int, question: String, text: String? = nil) -> Int {
        let fixedChars = ReadPrompt.instructions.count + ReadPrompt.prompt(text: "", question: question, cut: true).count
        let fixedTokens = Int((Double(fixedChars) / proseCharsPerToken).rounded(.up)) + 32 // the template's own turns
        let free = windowTokens - answerTokens - fixedTokens
        guard free > 0 else { return 0 }
        let ratio = text.map(charsPerToken(of:)) ?? proseCharsPerToken
        return Int(Double(free) * ratio * margin)
    }
}

/// What M1K3 says when a read fails: never a guess at what the text says.
public enum ReadFailureReply {
    public static let tryAgain = "I couldn't read that just now. Try again in a moment."
    /// A read stopped before its first word: a line, so the text it was about stays reachable.
    public static let stopped = "Stopped before an answer."
    public static let cannotRead =
        "The brain that's answering right now can't read on this device. Switch to Mini or Lil and ask again."

    public static func reply(for error: any Error) -> String {
        if let declined = error as? LookDeclined { return declined.reply }
        if let known = error as? InferenceError, known == TextReadingError.cannotRead { return cannotRead }
        return tryAgain
    }

    /// Mini's failure classes, said plainly. A guardrail on a pasted text is Apple's filter
    /// reading the TEXT, so retrying the same paste loops: name the way out instead.
    public static func reply(for failure: AFMFailure) -> String {
        switch failure {
        case .rateLimited, .daemonUnavailable, .timeout, .unknown:
            return tryAgain
        case .contextOverflow:
            return "That was too long for Mini to read in one go. Try a shorter part, or switch to Lil."
        case .unsupportedLanguage:
            return AFMFailure.unsupportedLanguageReply
        case .guardrailViolation:
            return "Apple's model wouldn't read that one, so I won't guess at what it says. Lil can try it."
        }
    }
}

extension SwappableInferenceProvider: TextReading {
    /// Forwards to whichever backend is active when the read STARTS.
    public func read(instructions: String, prompt: String) -> LookStream {
        guard let reader = active as? TextReading else {
            return AsyncThrowingStream { $0.finish(throwing: TextReadingError.cannotRead) }
        }
        return reader.read(instructions: instructions, prompt: prompt)
    }

    public var readContextTokens: Int {
        (active as? TextReading)?.readContextTokens ?? 0
    }
}
