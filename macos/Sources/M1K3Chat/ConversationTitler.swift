//
//  ConversationTitler.swift
//  M1K3Chat
//
//  Auto-titling for the history drawer: after the first completed exchange of
//  an untitled conversation, ChatSession fires the titler in the background
//  (never blocking send) and stores the sanitized result. Small local models
//  return messy strings — quotes, "Title:" prefixes, whole paragraphs — so
//  TitleSanitizer is where the real behaviour lives, and a nil from it means
//  "stay untitled, retry after the next exchange".
//
//  Signed: Kev + claude-fable-5, 2026-06-11, Confidence 0.85 (pure parts
//  test-pinned; title quality on the real lineup is verify-at-⌘R).
//  Prior: Unknown.
//  Review: Kev + claude-fable-5.1, 2026-09-11, Confidence 0.85 — #285: the model's own
//  "FOLLOWUPS: [...]" trailer habit (the same sentinel every chat answer can carry) was
//  leaking into titles. `TitleSanitizer.sanitize` now rejects a candidate that contains the
//  trailer or a long spaceless run (the CamelCase mangle seen live), and
//  `ProviderConversationTitler.title` runs `FollowUpSplit.split` on the assistant text before
//  building the prompt as a belt fix, in case the trailer is ever still attached on some path.
//

import Foundation
import M1K3Inference

public protocol ConversationTitling: Sendable {
    /// RAW model output — the caller sanitizes (keeps the seam dumb and the
    /// sanitizer's behaviour in one tested place).
    func title(forUser user: String, assistant: String) async throws -> String
}

public struct ProviderConversationTitler: ConversationTitling {
    private let provider: any InferenceProvider

    public init(provider: any InferenceProvider) {
        self.provider = provider
    }

    public func title(forUser user: String, assistant: String) async throws -> String {
        // Belt fix (#285): the live titles that leaked the "FOLLOWUPS: [...]"
        // trailer proved the trailer can ride the raw assistant text into
        // this prompt — ChatSession's `messages.last.text` should already be
        // split, but a title-generation call is a SEPARATE completion, and a
        // small model has its own habit of appending the trailer to whatever
        // it's asked to write, title included. Splitting here means the
        // model never even SEES the sentinel in its own few-shot context.
        let cleanedAssistant = FollowUpSplit.split(assistant).answer
        // Nobody is waiting on a title. Marked background so it can never take
        // the persona-prefix slot from the chat turn that just finished — the
        // 2026-08-09 finding, where exactly this call cost the NEXT turn 16-19s.
        return try await InferenceIntent.backgroundUtility {
            try await provider.generate(prompt: TitlePrompt.build(user: user, assistant: cleanedAssistant))
        }
    }
}

public enum TitlePrompt {
    /// Both turns capped at 400 chars (HistoryWindow's per-turn budget) —
    /// titling must stay cheap enough to fire after every send if needed.
    public static func build(user: String, assistant: String) -> String {
        """
        Write a 3-6 word title for this conversation. Reply with ONLY the title — \
        no quotes, no punctuation at the end, no explanation.

        USER: \(String(user.prefix(400)))
        ASSISTANT: \(String(assistant.prefix(400)))
        """
    }
}

public enum TitleSanitizer {
    /// nil = unusable output; the conversation stays untitled.
    public static func sanitize(_ raw: String) -> String? {
        // First non-empty line only — models love to explain themselves.
        guard var line = raw
            .components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty })
        else { return nil }

        if let range = line.range(of: "Title:", options: [.caseInsensitive, .anchored]) {
            line = String(line[range.upperBound...])
        }
        // Quotes and trailing punctuation interleave ("Echo chat". ) — strip
        // to a fixed point, not in one pass.
        let quotes = CharacterSet(charactersIn: "\"'`“”‘’ ")
        var previous: String
        repeat {
            previous = line
            line = line.trimmingCharacters(in: quotes)
            while let last = line.last, ".!?,;:".contains(last) {
                line.removeLast()
            }
        } while line != previous
        line = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")

        // #285: the model's own "FOLLOWUPS: [...]" trailer habit walking into
        // a title — sometimes intact ("… FOLLOWUPS: [\"What's new with"),
        // sometimes with every space stripped first (a CamelCase mangle that
        // reads as one unbroken run). Untitled beats mangled, so both shapes
        // are a hard reject rather than a further scrub.
        guard !containsFollowUpsTrailer(line), !hasOverlongRun(line) else {
            return nil
        }

        if line.count > 60 {
            // Cut on a word boundary under the cap.
            var words: [Substring] = []
            var length = 0
            for word in line.split(separator: " ") {
                let next = length + (words.isEmpty ? 0 : 1) + word.count
                if next > 60 { break }
                words.append(word)
                length = next
            }
            line = words.joined(separator: " ")
        }
        return line.isEmpty ? nil : line
    }

    /// The trailer, whichever case it survived in — the two live titles carried
    /// "FOLLOWUPS:" and a CamelCase-mangled "Followups:" respectively.
    private static func containsFollowUpsTrailer(_ line: String) -> Bool {
        line.range(of: "FOLLOWUPS", options: .caseInsensitive) != nil
            || line.contains("[") || line.contains("]")
            || line.contains("{") || line.contains("}")
    }

    /// A run of 25+ non-whitespace characters: the CamelCase mangle in
    /// isolation, where every space between words was dropped and the words
    /// themselves don't happen to spell "Followups".
    private static func hasOverlongRun(_ line: String) -> Bool {
        line.split(whereSeparator: \.isWhitespace).contains { $0.count > 24 }
    }
}
